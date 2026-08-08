import Foundation

/// The floor. Deterministic, offline, instant, and always present — every
/// other advisor layers on top of this one rather than replacing it.
///
/// Its job is to guarantee that the UI never shows an unexplained item, even
/// with no model configured and no network.
public struct HeuristicAdvisor: AIAdvisor {
    public let source: AISource = .heuristic

    public init() {}

    public func assess(_ batch: [AIEvidence]) async throws -> [UUID: AIAssessment] {
        var result: [UUID: AIAssessment] = [:]
        for evidence in batch {
            result[evidence.itemID] = assess(evidence)
        }
        return result
    }

    private func assess(_ evidence: AIEvidence) -> AIAssessment {
        let path = evidence.redactedPath
        let (what, consequence, recommendation, confidence) = classify(evidence, path: path)

        return AIAssessment(
            itemID: evidence.itemID,
            confidence: confidence,
            attribution: evidence.deterministicOwner,
            whatItIs: what,
            consequence: consequence,
            recommendation: recommendation,
            source: .heuristic
        )
    }

    private func classify(
        _ evidence: AIEvidence,
        path: String
    ) -> (String, String, AIRecommendation, Double) {
        // Developer artifacts with proven rebuildability are the confident case.
        if evidence.rebuildEvidence != nil {
            return (
                "\(evidence.kindHint)：可从项目中的锁文件完整重建。",
                "下次构建时自动重新生成，只会多花一次安装/编译的时间。",
                .safeToRemove,
                0.9
            )
        }

        if path.contains("/DerivedData/") {
            return (
                "Xcode 的中间编译产物与索引数据。",
                "下次打开该工程会全量重新编译，大型项目可能需要几分钟。",
                .safeToRemove,
                0.88
            )
        }
        if path.contains("/CoreSimulator/Caches") {
            return (
                "iOS 模拟器的动态库共享缓存。",
                "首次启动模拟器会慢十几秒，之后恢复正常。",
                .safeToRemove,
                0.9
            )
        }
        if path.contains("DeviceSupport") {
            return (
                "已连接过的设备的符号缓存，每台设备一份。",
                "再次连接该设备时 Xcode 会重新拷贝，需要几分钟。",
                .safeToRemove,
                0.85
            )
        }
        if path.hasPrefix("~/Library/Caches/") {
            let idle = evidence.ageInDays ?? 0
            return (
                "App 的缓存目录，由 App 自行管理和重建。",
                idle > 90
                    ? "已有 \(idle) 天未更新，删除几乎无感知。"
                    : "App 下次运行时会重新生成需要的部分。",
                .safeToRemove,
                idle > 30 ? 0.85 : 0.78
            )
        }
        if path.contains("/Saved Application State/") {
            return (
                "App 的窗口恢复状态。",
                "该 App 下次启动时会以默认窗口布局打开。",
                .safeToRemove,
                0.86
            )
        }
        if path.contains("/Containers/") || path.contains("/Group Containers/") {
            return (
                "沙盒 App 的私有容器，里面可能存放着该 App 的全部文档和设置。",
                "如果这个 App 以后重新安装，其历史数据将无法找回。",
                .reviewFirst,
                0.55
            )
        }
        if path.contains("/LaunchAgents/") || path.contains("/LaunchDaemons/") {
            return (
                "后台启动项配置。若目标程序已不存在，系统每次登录都会尝试并失败一次。",
                "移除后该后台任务不再启动。若程序仍在使用，其后台功能会失效。",
                .reviewFirst,
                0.6
            )
        }
        if evidence.kindHint.contains("同厂商仍在使用") {
            return (
                "文件名与某个仍安装在本机的厂商匹配，但具体标识符对不上——可能是被改名的组件，也可能是旧版残留。",
                "如果它其实属于在用的 App，删除后该 App 可能丢失部分设置。建议先确认。",
                .reviewFirst,
                0.45
            )
        }
        if evidence.redactedPath.contains("/Application Support/") {
            return (
                "App 的支持文件目录，归属的 App 未在本机找到。",
                "如果只是把 App 挪到了别处（而非卸载），删除会丢失其设置和本地数据。",
                .reviewFirst,
                0.5
            )
        }
        // Large / duplicate files: never advise, always defer to the user.
        if evidence.kindHint.hasPrefix("副本") {
            return (
                "与同组另一个文件内容完全一致（SHA-256 校验通过）。",
                "删除后仍保留一份完整副本。",
                .reviewFirst,
                0.7
            )
        }

        return (
            evidence.ruleRationale.isEmpty ? "未识别的项目。" : evidence.ruleRationale,
            "无法判断删除后的影响，请自行确认。",
            .reviewFirst,
            0.3
        )
    }
}
