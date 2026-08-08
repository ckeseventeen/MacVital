import Foundation

/// The AI layer's whole contract. Note what is absent: there is no method that
/// returns permission, and no way for an implementation to signal "delete
/// this". An advisor explains, attributes and ranks. The rule engine admits.
public protocol AIAdvisor: Sendable {
    var source: AISource { get }
    /// Assess a batch. Implementations must return at most one assessment per
    /// input `itemID`, and must not invent IDs.
    func assess(_ batch: [AIEvidence]) async throws -> [UUID: AIAssessment]
}

public enum AdvisorMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Deterministic pattern table only. No model, no network, no daemon.
    case offline
    /// Local small model over HTTP on 127.0.0.1. Nothing leaves the machine.
    case local
    /// Anthropic API. Redacted metadata only, and only when the user opts in.
    case cloud

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .offline: return "仅内置规则"
        case .local: return "本地模型"
        case .cloud: return "云端模型"
        }
    }

    public var detail: String {
        switch self {
        case .offline: return "完全离线。解释来自内置规则表，不做语义归因。"
        case .local: return "调用 127.0.0.1 上的本地小模型。文件路径不出本机。"
        case .cloud: return "复杂归因场景调用 Anthropic API，仅发送脱敏后的元数据。"
        }
    }
}

/// Runs the preferred advisor, falls back to the heuristic table on any
/// failure, and normalises whatever comes back.
///
/// Two properties this type guarantees regardless of the backing model:
///   * every input item gets an assessment (the fallback fills gaps),
///   * no assessment can reference an item that was not in the batch.
public struct CompositeAdvisor: AIAdvisor {
    public let source: AISource
    private let primary: AIAdvisor?
    private let fallback: HeuristicAdvisor
    private let timeout: Duration

    public init(primary: AIAdvisor?, timeout: Duration = .seconds(25)) {
        self.primary = primary
        self.fallback = HeuristicAdvisor()
        self.source = primary?.source ?? .heuristic
        self.timeout = timeout
    }

    public func assess(_ batch: [AIEvidence]) async throws -> [UUID: AIAssessment] {
        let baseline = try await fallback.assess(batch)
        guard let primary else { return baseline }

        let ids = Set(batch.map(\.itemID))
        var merged = baseline

        do {
            let produced = try await withTimeout(timeout) {
                try await primary.assess(batch)
            }
            for (id, assessment) in produced where ids.contains(id) {
                merged[id] = assessment
            }
        } catch {
            Log.ai.error("advisor \(primary.source.rawValue, privacy: .public) failed, using heuristics: \(error.localizedDescription, privacy: .public)")
        }
        return merged
    }

    private func withTimeout<T: Sendable>(
        _ duration: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw AdvisorError.timedOut
            }
            guard let result = try await group.next() else { throw AdvisorError.timedOut }
            group.cancelAll()
            return result
        }
    }
}

public enum AdvisorError: LocalizedError {
    case timedOut
    case notConfigured(String)
    case transport(String)
    case malformedResponse(String)
    case refused(String)

    public var errorDescription: String? {
        switch self {
        case .timedOut: return "模型响应超时。"
        case .notConfigured(let detail): return "模型未配置：\(detail)"
        case .transport(let detail): return "网络错误：\(detail)"
        case .malformedResponse(let detail): return "模型返回格式不正确：\(detail)"
        case .refused(let detail): return "模型拒绝了该请求：\(detail)"
        }
    }
}
