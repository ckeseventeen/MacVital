import Foundation

/// What the model thinks should happen. Advisory only — the rule engine decides
/// what *may* happen and the user decides what *does* happen.
public enum AIRecommendation: String, Codable, Sendable {
    case safeToRemove
    case reviewFirst
    case keep
}

public enum AISource: String, Codable, Sendable {
    /// Deterministic pattern table. Always available, works offline, no model.
    case heuristic
    /// Local small model over HTTP on 127.0.0.1. Nothing leaves the machine.
    case localModel
    /// Anthropic API. Opt-in, sends redacted metadata only.
    case cloud
}

/// The AI layer's product: explanation, attribution, ranking, confidence.
/// Never an admission.
public struct AIAssessment: Hashable, Codable, Sendable {
    public var itemID: UUID
    /// 0...1. Clamped on ingest; a malformed model response degrades to 0.
    public var confidence: Double
    /// Which app/project this belongs to, in the model's words.
    public var attribution: String?
    /// "这是 iOS 模拟器的动态库缓存" — translate the path into a sentence.
    public var whatItIs: String
    /// "清理后首次启动模拟器会慢 10-20 秒，之后恢复正常。"
    public var consequence: String
    public var recommendation: AIRecommendation
    public var source: AISource

    public init(
        itemID: UUID,
        confidence: Double,
        attribution: String? = nil,
        whatItIs: String,
        consequence: String,
        recommendation: AIRecommendation,
        source: AISource
    ) {
        self.itemID = itemID
        self.confidence = min(max(confidence, 0), 1)
        self.attribution = attribution
        self.whatItIs = whatItIs
        self.consequence = consequence
        self.recommendation = recommendation
        self.source = source
    }

    /// A confidence floor for auto-selection. Below this we surface the item
    /// but leave it unchecked regardless of the recommendation.
    public static let autoSelectConfidenceFloor = 0.75
}
