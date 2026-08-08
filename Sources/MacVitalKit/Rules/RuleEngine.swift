import Foundation

/// The admission gate. Deterministic, allowlist-driven, default-deny.
///
/// No model output reaches this type. It takes a `ScanItem` and the current
/// state of the filesystem and returns `allow` / `allowWithPrivilege` / `deny`.
/// Every guard below can only *lower* the verdict — there is no path that
/// upgrades a deny.
///
/// The engine is run twice per item: once at scan time to render the UI, and
/// again immediately before the move to quarantine. The second pass exists
/// because the first one is a snapshot: between the scan and the user pressing
/// the button, a build can start, an app can launch, or a symlink can appear.
public struct RuleEngine: Sendable {
    public let rules: RuleIndex
    public let protectedPaths: ProtectedPaths
    public let processIndex: RunningProcessIndex
    /// Our own quarantine directory and app bundle — never removable by us.
    public let selfProtectedPrefixes: [String]

    public init(
        rules: RuleIndex,
        protectedPaths: ProtectedPaths = ProtectedPaths(),
        processIndex: RunningProcessIndex,
        selfProtectedPrefixes: [String] = []
    ) {
        self.rules = rules
        self.protectedPaths = protectedPaths
        self.processIndex = processIndex
        // Normalised on the way in: the prefixes are compared against
        // realpath-resolved candidates, so an unnormalised /var/... prefix
        // would silently never match its own /private/var/... contents.
        self.selfProtectedPrefixes = selfProtectedPrefixes.map(ProtectedPaths.normalize)
    }

    public func evaluate(_ item: ScanItem) -> RuleDecision {
        // 1. The rule must exist. An item referencing an unknown rule is a bug
        //    in a scanner, and the safe response to a bug is to refuse.
        guard let rule = rules.rule(for: item.ruleID) else {
            return .deny(item.ruleID, .unknownRule, "没有匹配的清理规则，出于安全默认拒绝。")
        }

        // 2. Structural deny list, on the path as claimed. This runs before we
        //    touch the filesystem so the answer for a protected path is always
        //    "protected" — not "missing" or "unreadable" depending on the state
        //    of the disk. The same check runs again on the resolved path below;
        //    a symlink must not launder a claim past this.
        let declared = ProtectedPaths.normalize(item.path)
        if let reason = protectedPaths.isHardDenied(declared) {
            return .deny(rule.id, reason, Self.explain(reason, path: declared))
        }

        // 3. Resolve symlinks before every remaining check. A rule that matches
        //    ~/Library/Caches/foo must not authorise deleting whatever foo
        //    points at.
        guard SIPGuard.exists(declared) else {
            return .deny(rule.id, .missing, "文件已不存在，可能已被其他程序清理。")
        }
        guard let resolved = SIPGuard.realPath(declared).map(ProtectedPaths.normalize) else {
            return .deny(rule.id, .symlinkEscape, "无法解析真实路径，拒绝操作。")
        }
        if resolved != declared, SIPGuard.isSymlink(declared) {
            // We only ever remove the link itself, never its target, and only
            // when the target is also admissible. Simpler and safer: refuse.
            return .deny(rule.id, .symlinkEscape,
                         "这是一个符号链接，指向 \(PathRedaction.abbreviate(resolved))。为避免误删目标，不做处理。")
        }

        // 4. Same deny list, now against what the path actually resolves to:
        //    SIP prefixes, keychains, Photos, volume roots, and anything
        //    shallower than three path components.
        if let reason = protectedPaths.isHardDenied(resolved) {
            return .deny(rule.id, reason, Self.explain(reason, path: resolved))
        }

        // 5. Ask the filesystem, not our list. SIP coverage shifts between OS
        //    releases and installers set their own immutable flags.
        if let flag = SIPGuard.blockingFlag(at: resolved) {
            switch flag {
            case .restricted:
                return .deny(rule.id, .systemIntegrityProtected, "受系统完整性保护（SIP）保护，任何程序都无法删除。")
            case .dataVault:
                return .deny(rule.id, .systemIntegrityProtected, "位于系统数据保险库中，无法访问。")
            case .immutable:
                return .deny(rule.id, .immutableFlag, "文件被标记为不可变（immutable flag），需要先手动解除锁定。")
            }
        }

        // 6. Never touch ourselves — the quarantine store above all.
        for prefix in selfProtectedPrefixes where protectedPaths.isUnder(resolved, prefix) {
            return .deny(rule.id, .selfProtection, "属于 MacVital 自身的数据（如隔离区），不参与清理。")
        }

        // 7. Documents / Desktop / Downloads / Pictures are off limits unless
        //    the rule explicitly opted in. Only unambiguous build output does.
        if protectedPaths.isInSensitiveUserData(resolved) && !rule.allowedInUserData {
            return .deny(rule.id, .protectedUserData,
                         "位于个人文档目录中，此类规则不允许在该位置执行。")
        }

        // 8. The path must still match the rule that claimed it. This catches
        //    a scanner producing an item with the wrong rule ID, and it is the
        //    check that makes rule review meaningful: reading the pattern tells
        //    you the complete set of paths the rule can ever authorise.
        guard rule.pattern.matches(resolved) else {
            return .deny(rule.id, .patternMismatch,
                         "路径与规则 \(rule.id) 的模式 \(rule.pattern.raw) 不匹配。")
        }

        // 9. In use? Deleting a directory a compiler is writing into corrupts
        //    the build; deleting a running app's container loses its state.
        if let process = processIndex.executingProcess(under: resolved) {
            return .deny(rule.id, .inUse,
                         "正在被「\(processIndex.describe(process))」（PID \(process.pid)）使用，请先退出该程序。")
        }
        if let bundleID = item.ownerHint?.bundleIdentifier, processIndex.isRunning(bundleIdentifier: bundleID) {
            return .deny(rule.id, .inUse,
                         "归属的 App「\(item.ownerHint?.label ?? bundleID)」正在运行，请先退出。")
        }

        // 10. Everything below this line is an allow. The only remaining
        //    question is whether it needs root.
        if rule.requiresPrivilege || !SIPGuard.currentUserCanRemove(resolved) {
            return .privileged(rule.id, rule.rationale + "（需要管理员授权）")
        }
        return .allow(rule.id, rule.rationale)
    }

    /// Convenience for the execution path: evaluate a batch and split it.
    public func partition(_ items: [ScanItem]) -> (allowed: [ScanItem], denied: [(ScanItem, RuleDecision)]) {
        var allowed: [ScanItem] = []
        var denied: [(ScanItem, RuleDecision)] = []
        for item in items {
            let decision = evaluate(item)
            if decision.isDenied {
                denied.append((item, decision))
            } else {
                allowed.append(item)
            }
        }
        return (allowed, denied)
    }

    private static func explain(_ reason: DenyReason, path: String) -> String {
        switch reason {
        case .criticalPath:
            return "位于系统关键目录，不可删除。"
        case .pathTooShallow:
            return "路径层级过浅，删除风险过高。"
        case .protectedUserData:
            return "属于受保护的个人数据（钥匙串、照片图库、邮件、密钥等）。"
        default:
            return "被安全规则拒绝。"
        }
    }
}
