import Foundation

/// Opt-in cloud path for attribution cases a 3B model gets wrong.
///
/// There is no official Anthropic SDK for Swift, so this is a hand-rolled
/// URLSession client against the Messages API. Non-streaming: the batch is
/// small and bounded, and the response is a single structured JSON object.
///
/// Privacy posture, since this is the one code path that leaves the machine:
///   * only `AIEvidence` is sent, which is already redacted (`~`, `<user>`),
///   * file *contents* are never sent beyond a printable-ASCII head snippet,
///   * the whole advisor is off unless the user turns it on and supplies a key.
public struct CloudAdvisor: AIAdvisor {
    public let source: AISource = .cloud

    public struct Configuration: Sendable, Equatable {
        public var apiKey: String
        public var model: String
        public var batchSize: Int
        public var baseURL: URL

        public init(
            apiKey: String,
            model: String = "claude-opus-5",
            batchSize: Int = 24,
            baseURL: URL = URL(string: "https://api.anthropic.com/v1/messages")!
        ) {
            self.apiKey = apiKey
            self.model = model
            self.batchSize = batchSize
            self.baseURL = baseURL
        }
    }

    private let configuration: Configuration
    private let session: URLSession

    public init(configuration: Configuration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    public func assess(_ batch: [AIEvidence]) async throws -> [UUID: AIAssessment] {
        guard !configuration.apiKey.isEmpty else {
            throw AdvisorError.notConfigured("未设置 Anthropic API Key")
        }

        var merged: [UUID: AIAssessment] = [:]
        for chunk in batch.chunked(into: configuration.batchSize) {
            if Task.isCancelled { throw CancellationError() }
            merged.merge(try await request(chunk)) { _, new in new }
        }
        return merged
    }

    // MARK: - Transport

    private func request(_ batch: [AIEvidence]) async throws -> [UUID: AIAssessment] {
        let body: [String: Any] = [
            "model": configuration.model,
            "max_tokens": 16000,
            "system": PromptBuilder.systemPrompt,
            // Effort keeps the cost of a file-labelling task down; the schema
            // guarantees the reply parses.
            "output_config": [
                "effort": "low",
                "format": [
                    "type": "json_schema",
                    "schema": PromptBuilder.responseSchema,
                ],
            ],
            // Safety classifiers can decline a request. Server-side fallback
            // re-serves it on the recommended model inside the same call
            // rather than handing us a refusal to deal with.
            "fallbacks": "default",
            "messages": [
                ["role": "user", "content": PromptBuilder.userMessage(for: batch)]
            ],
        ]

        var request = URLRequest(url: configuration.baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 90

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AdvisorError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AdvisorError.transport("无响应")
        }
        guard http.statusCode == 200 else {
            throw AdvisorError.transport(Self.describeError(status: http.statusCode, data: data))
        }

        let envelope = try decodeEnvelope(data)

        // Check the stop reason before touching content: on a refusal the
        // content array is empty or partial.
        if envelope.stopReason == "refusal" {
            throw AdvisorError.refused(envelope.stopDetails?.explanation ?? "内容策略拒绝")
        }
        guard let text = envelope.content.first(where: { $0.type == "text" })?.text,
              let inner = text.data(using: .utf8),
              let payload = try? JSONDecoder().decode(PromptBuilder.ResponsePayload.self, from: inner)
        else {
            throw AdvisorError.malformedResponse("响应中没有可解析的 JSON")
        }

        return PromptBuilder.assessments(
            from: payload,
            expecting: Set(batch.map(\.itemID)),
            source: .cloud
        )
    }

    // MARK: - Wire types

    private struct Envelope: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        struct StopDetails: Decodable {
            let category: String?
            let explanation: String?
        }
        let content: [Block]
        let stopReason: String?
        let stopDetails: StopDetails?
        let model: String?

        enum CodingKeys: String, CodingKey {
            case content
            case stopReason = "stop_reason"
            case stopDetails = "stop_details"
            case model
        }
    }

    private func decodeEnvelope(_ data: Data) throws -> Envelope {
        do {
            return try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw AdvisorError.malformedResponse(error.localizedDescription)
        }
    }

    private static func describeError(status: Int, data: Data) -> String {
        struct APIError: Decodable {
            struct Detail: Decodable { let type: String; let message: String }
            let error: Detail
        }
        if let decoded = try? JSONDecoder().decode(APIError.self, from: data) {
            return "HTTP \(status)：\(decoded.error.message)"
        }
        return "HTTP \(status)"
    }
}
