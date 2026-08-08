import Foundation

/// Shared prompt and response schema for both the local and the cloud advisor,
/// so switching backends does not change what the model is asked to do.
public enum PromptBuilder {
    public static let systemPrompt = """
    你是 macOS 清理工具 MacVital 的文件解释器。

    你的职责有且仅有三项：
    1. 解释：把文件路径翻译成一句普通用户能看懂的话（这是什么）。
    2. 归因：判断它属于哪个 App 或哪个项目。文件名往往被改过，要结合 \
    目录内容、plist 键名、文件头内容综合判断，不要只看文件名。
    3. 后果：说明删除后会发生什么，用具体的话（"首次启动慢十几秒"），\
    不要用"可能有影响"这种废话。

    你不决定是否删除。是否允许删除由确定性规则引擎判定，是否执行删除由用户授权。
    你的 recommendation 字段只是排序和高亮的依据。

    判断准则：
    - 有锁文件/清单文件可完整重建的构建产物 → safeToRemove，置信度可以高。
    - App 缓存目录 → safeToRemove。
    - 沙盒容器、Application Support、可能含用户数据的目录 → reviewFirst，\
    除非你能明确指出归属的 App 已经不在本机。
    - 你不确定这是什么 → reviewFirst，并把 confidence 压到 0.5 以下。\
    宁可让用户多看一眼，也不要给出自信的错误答案。
    - 任何时候都不要输出 keep 以外的建议来掩盖你的不确定；不确定就压低 confidence。

    confidence 是你对"我说的这段解释和归因是正确的"的把握，不是对"删除是安全的"的把握。
    用中文回答。每条 whatItIs 和 consequence 控制在 60 字以内。
    """

    /// JSON Schema for the structured response. Used verbatim as
    /// `output_config.format.schema` on the Anthropic API and as the shape
    /// description for local models that only support `format: json`.
    public static let responseSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "assessments": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "输入项的 id，原样返回"],
                        "whatItIs": ["type": "string"],
                        "consequence": ["type": "string"],
                        "attribution": ["type": "string", "description": "归属的 App 或项目名，未知则空字符串"],
                        "recommendation": ["type": "string", "enum": ["safeToRemove", "reviewFirst", "keep"]],
                        "confidence": ["type": "number", "description": "0 到 1"],
                    ],
                    "required": ["id", "whatItIs", "consequence", "attribution", "recommendation", "confidence"],
                    "additionalProperties": false,
                ],
            ]
        ],
        "required": ["assessments"],
        "additionalProperties": false,
    ]

    /// The batch, rendered compactly. Only redacted fields are included —
    /// `AIEvidence` is already scrubbed, this just keeps it terse.
    public static func userMessage(for batch: [AIEvidence]) -> String {
        var lines: [String] = ["请为下列条目各生成一条解释。原样返回每条的 id。", ""]
        for evidence in batch {
            lines.append("---")
            lines.append("id: \(evidence.itemID.uuidString)")
            lines.append("path: \(evidence.redactedPath)")
            lines.append("kind: \(evidence.kindHint)")
            lines.append("size: \(ByteFormat.string(evidence.sizeBytes))")
            if evidence.isDirectory { lines.append("files: \(evidence.fileCount)") }
            if let age = evidence.ageInDays { lines.append("last_modified_days_ago: \(age)") }
            if let owner = evidence.deterministicOwner { lines.append("rule_guessed_owner: \(owner)") }
            if let rebuild = evidence.rebuildEvidence { lines.append("rebuildable: \(rebuild)") }
            if !evidence.childNames.isEmpty {
                lines.append("children: \(evidence.childNames.joined(separator: ", "))")
            }
            if !evidence.plistKeys.isEmpty {
                lines.append("plist_keys: \(evidence.plistKeys.joined(separator: ", "))")
            }
            for (key, value) in evidence.plistIdentityValues.sorted(by: { $0.key < $1.key }) {
                lines.append("plist.\(key): \(value)")
            }
            if let snippet = evidence.headSnippet {
                lines.append("head: \(snippet.prefix(200))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Wire format of the model's reply. Deliberately permissive on parse and
    /// strict on use — anything malformed degrades to the heuristic result.
    struct ResponsePayload: Decodable {
        struct Item: Decodable {
            let id: String
            let whatItIs: String
            let consequence: String
            let attribution: String?
            let recommendation: String
            let confidence: Double
        }
        let assessments: [Item]
    }

    /// Convert a decoded payload into assessments, dropping anything that does
    /// not correspond to an item we actually asked about.
    static func assessments(
        from payload: ResponsePayload,
        expecting ids: Set<UUID>,
        source: AISource
    ) -> [UUID: AIAssessment] {
        var result: [UUID: AIAssessment] = [:]
        for item in payload.assessments {
            guard let id = UUID(uuidString: item.id), ids.contains(id) else { continue }
            let recommendation = AIRecommendation(rawValue: item.recommendation) ?? .reviewFirst
            let attribution = (item.attribution?.isEmpty == false) ? item.attribution : nil
            result[id] = AIAssessment(
                itemID: id,
                confidence: item.confidence,
                attribution: attribution,
                whatItIs: item.whatItIs,
                consequence: item.consequence,
                recommendation: recommendation,
                source: source
            )
        }
        return result
    }

    static func schemaJSONData() throws -> Data {
        try JSONSerialization.data(withJSONObject: responseSchema, options: [.sortedKeys])
    }
}
