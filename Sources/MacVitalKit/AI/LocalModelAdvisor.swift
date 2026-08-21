import Foundation

/// Talks to a small model running on this machine over loopback HTTP.
///
/// Shipping a 3B model this way rather than embedding one keeps the app binary
/// small and lets the user pick the model, at the cost of requiring a local
/// runtime. The privacy property that matters is preserved either way: the
/// request never leaves 127.0.0.1.
///
/// Speaks the Ollama `/api/chat` shape, which llama.cpp's server and LM Studio
/// both emulate.
public struct LocalModelAdvisor: AIAdvisor {
    public let source: AISource = .localModel

    public struct Configuration: Sendable, Codable, Equatable {
        public var endpoint: URL
        public var model: String
        /// Small batches keep the context inside a 3B model's comfort zone.
        public var batchSize: Int

        public init(
            endpoint: URL = URL(string: "http://127.0.0.1:11434/api/chat")!,
            model: String = "qwen2.5:3b",
            batchSize: Int = 8
        ) {
            self.endpoint = endpoint
            self.model = model
            self.batchSize = batchSize
        }

        public static let `default` = Configuration()
    }

    private let configuration: Configuration
    private let session: URLSession

    public init(configuration: Configuration = .default, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    public func assess(_ batch: [AIEvidence]) async throws -> [UUID: AIAssessment] {
        // Numeric loopback only. `localhost` was accepted here, and it is a
        // name — `/etc/hosts` or a resolver can point it anywhere, which is
        // precisely the "silently becomes a network upload" case this guard
        // exists to stop.
        guard ["127.0.0.1", "::1"].contains(configuration.endpoint.host ?? "") else {
            throw AdvisorError.notConfigured("本地模型地址必须指向 127.0.0.1（不接受主机名）")
        }

        var merged: [UUID: AIAssessment] = [:]
        for chunk in batch.chunked(into: configuration.batchSize) {
            if Task.isCancelled { throw CancellationError() }
            let produced = try await request(chunk)
            merged.merge(produced) { _, new in new }
        }
        return merged
    }

    /// Reachability probe for the settings screen.
    public func ping() async -> Bool {
        var components = URLComponents(url: configuration.endpoint, resolvingAgainstBaseURL: false)
        components?.path = "/api/tags"
        guard let url = components?.url else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else { return false }
        return http.statusCode == 200
    }

    // MARK: - Transport

    private func request(_ batch: [AIEvidence]) async throws -> [UUID: AIAssessment] {
        let body: [String: Any] = [
            "model": configuration.model,
            "stream": false,
            "format": "json",
            "options": ["temperature": 0.2],
            "messages": [
                ["role": "system", "content": PromptBuilder.systemPrompt + "\n\n" + schemaInstruction()],
                ["role": "user", "content": PromptBuilder.userMessage(for: batch)],
            ],
        ]

        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AdvisorError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw AdvisorError.transport("HTTP \(code)")
        }

        // Ollama wraps the model's reply: { message: { content: "<json>" } }
        struct Envelope: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw AdvisorError.malformedResponse("无法解析本地模型响应外层结构")
        }
        guard let inner = envelope.message.content.data(using: .utf8),
              let payload = try? JSONDecoder().decode(PromptBuilder.ResponsePayload.self, from: inner)
        else {
            throw AdvisorError.malformedResponse("模型未按 JSON schema 输出")
        }

        return PromptBuilder.assessments(
            from: payload,
            expecting: Set(batch.map(\.itemID)),
            source: .localModel
        )
    }

    private func schemaInstruction() -> String {
        let schema = (try? PromptBuilder.schemaJSONData()).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
        只输出符合下面 JSON Schema 的 JSON，不要有任何其他文字：
        \(schema)
        """
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
