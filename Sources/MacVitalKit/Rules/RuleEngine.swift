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
    /// Whether the privileged helper can be reached at all.
    ///
    /// Defaults to asking the build. A self-signed build cannot derive the team
    /// identifier the XPC connection is pinned to, so every privileged removal
    /// fails — and the honest verdict for those paths is `deny`, not
    /// `allowWithPrivilege`. Injectable so tests can exercise both worlds.
    public let privilegedRemovalPossible: Bool

    public init(
        rules: RuleIndex,
        protectedPaths: ProtectedPaths = ProtectedPaths(),
        processIndex: RunningProcessIndex,
        selfProtectedPrefixes: [String] = [],
        privilegedRemovalPossible: Bool = HelperClient.isSupportedByThisBuild
    ) {
        self.rules = rules
        self.protectedPaths = protectedPaths
        self.processIndex = processIndex
        self.privilegedRemovalPossible = privilegedRemovalPossible
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

        // 5b. Can the whole tree actually be removed?
        //
        //     Everything above looks at the target itself. These do not:
        //
        //       * macOS puts `group:everyone deny delete` on several ~/Library
        //         directories, and `access(W_OK)` does not evaluate an ACL's
        //         delete permission at all;
        //       * a wallet app ships `Data/Documents/000RefuseWalletDBDelete/`
        //         at mode r-x specifically so its database cannot be removed,
        //         and Apple's ~/Library/Trial ships read-only model assets for
        //         ordinary reasons.
        //
        //     All three passed every check, were moved into quarantine, and
        //     then could be neither purged nor restored — restoring has to move
        //     the tree back out. The user had to find the offending directory
        //     by hand. Refusing up front is the only version of this that does
        //     not strand data.
        if let blocker = SIPGuard.removalBlocker(at: resolved) {
            // Root-owned content is the one blocker root gets past, so a rule
            // that already routes through the helper is not blocked by it.
            //
            // `.pkg` installers leave `root:wheel` trees behind — the app
            // bundle in `/Applications` most visibly — and treating those the
            // same as a `chmod`-able self-protection meant the headline
            // feature could not remove them at all, on any build, while
            // telling the user to run a `chmod` that would not have helped.
            let rootHandlesIt = blocker.rootCouldRemoveIt
                && rule.requiresPrivilege
                && privilegedRemovalPossible
            if !rootHandlesIt {
                return .deny(rule.id, .contentsNotRemovable, Self.explain(blocker, privileged: rule.requiresPrivilege))
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
            return .inUse(
                rule.id,
                "正在被「\(processIndex.describe(process))」（PID \(process.pid)）使用，请先退出该程序。",
                blockedBy: BlockingProcess(
                    pid: process.pid,
                    bundleIdentifier: process.bundleIdentifier,
                    executablePath: process.executablePath,
                    name: processIndex.describe(process)
                )
            )
        }
        if let bundleID = item.ownerHint?.bundleIdentifier, processIndex.isRunning(bundleIdentifier: bundleID) {
            return .inUse(
                rule.id,
                "归属的 App「\(item.ownerHint?.label ?? bundleID)」正在运行，请先退出。",
                blockedBy: BlockingProcess(
                    bundleIdentifier: bundleID,
                    name: item.ownerHint?.label ?? bundleID
                )
            )
        }

        // 10. Everything below this line is an allow. The only remaining
        //    question is whether it needs root — and whether root is reachable.
        //
        //    Only `requiresPrivilege` rules may route here, and that is not a
        //    stylistic choice: `HelperService.validatedRemovalDestination`
        //    accepts a path only when a `requiresPrivilege` rule in the shared
        //    catalog matches it. Sending anything else to the helper produces a
        //    guaranteed "没有匹配的特权清理规则" — a button that fails every
        //    time, which is the exact failure the guard below was written to
        //    stop for the ad-hoc case.
        if rule.requiresPrivilege {
            // A build that cannot verify the helper can never remove these, so
            // offering them is offering a button that fails every time. It used
            // to: a sweep would tick a dozen /Library/LaunchDaemons entries,
            // the user pressed 移入隔离区, and every one came back in the
            // skipped list with a code-signing complaint. The reported
            // "可回收" total counted them too.
            guard privilegedRemovalPossible else {
                return .deny(rule.id, .privilegedHelperUnavailable,
                             "位于系统目录，需要特权助手。当前构建是自签名的，无法使用助手"
                             + "（需要 Developer ID 证书签名的构建）。请在访达中手动处理。")
            }
            return .privileged(rule.id, rule.rationale + "（需要管理员授权）")
        }

        // A non-privileged rule whose path this user cannot unlink. Root is not
        // the answer — see above — so say what is actually true instead of
        // promising a helper that would refuse it.
        guard SIPGuard.currentUserCanRemove(resolved) else {
            return .deny(rule.id, .notRemovableByUser,
                         "当前用户没有权限移动 \(PathRedaction.abbreviate(resolved))"
                         + "（需要其所在目录的写权限）。请在访达中检查该目录的权限，或手动处理。")
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

    /// Names the exact path that blocks removal. "无法删除" without saying which
    /// piece is useless — the user's only recourse is to find it themselves,
    /// which is what happened before this check existed.
    private static func explain(_ blocker: SIPGuard.RemovalBlocker, privileged: Bool) -> String {
        let path = PathRedaction.abbreviate(blocker.path)
        switch blocker {
        case .deleteDenyACL:
            return "\(path) 上有「禁止删除」的访问控制列表（ACL），整棵目录会因此既删不掉也还原不了。"
                 + "如确需处理，请先执行 chmod -a# 0 移除该 ACL。"
        case .unwritableDirectory:
            return "\(path) 没有写权限，里面的内容无法移除，整棵目录会卡在半路。"
                 + "这通常是应用有意的自我保护（例如名为 000RefuseWalletDBDelete 的目录），"
                 + "也可能是系统自带的只读资源。如确需处理，请先执行 chmod u+w。"
        case .foreignOwner(_, let uid):
            // Says who owns it and what actually works. The old text sent the
            // user to `chmod u+w` here, which on a root-owned bundle needs
            // `sudo` and is not the fix anyway.
            let owner = uid == 0 ? "root（管理员）" : "另一个用户（uid \(uid)）"
            let base = "\(path) 属于 \(owner)，是安装器以管理员身份装上去的，当前用户动不了它。"
            return privileged
                ? base + "移除它需要特权助手，而当前构建是自签名的，用不了助手"
                       + "（需要 Developer ID 证书签名的构建）。也可以在访达里把它拖进废纸篓，"
                       + "系统会向你要一次密码。"
                : base + "在访达里把它拖进废纸篓即可，系统会向你要一次密码。"
        }
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
