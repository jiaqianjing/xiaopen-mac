import Foundation

public final class OpenAIProvider: LLMProviderProtocol {
    private let baseURL: String
    private let apiKey: String
    private let model: String
    private let session: URLSession
    private let options: OpenAIVendorOptions

    public convenience init(baseURL: String, apiKey: String, model: String, session: URLSession = .shared,
                            enableThinking: Bool? = nil) {
        self.init(baseURL: baseURL, apiKey: apiKey, model: model, session: session,
                  options: OpenAIVendorOptions(enableThinking: enableThinking))
    }

    public init(baseURL: String, apiKey: String, model: String, session: URLSession = .shared,
                options: OpenAIVendorOptions) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.session = session
        self.options = options
    }

    private func configuration() throws -> (url: URL, model: String, headers: [String: String]) {
        var url = try LLMHTTPClient.baseURL(baseURL)
        // An explicit path is already the API prefix (for example /v1beta/openai).
        if url.path.isEmpty || url.path == "/" { url.appendPathComponent("v1") }
        let model = try LLMHTTPClient.model(model)
        // Self-hosted OpenAI-compatible endpoints may intentionally omit authentication.
        let key = try LLMHTTPClient.apiKey(apiKey, required: url.host?.lowercased() == "api.openai.com")
        return (url, model, key.isEmpty ? [:] : ["Authorization": "Bearer \(key)"])
    }

    public func streamChat(messages: [ChatMessage], systemPrompt: String) async throws -> AsyncThrowingStream<String, Error> {
        let config = try configuration()
        var allMessages = messages
        if !systemPrompt.isEmpty { allMessages.insert(ChatMessage(role: "system", content: systemPrompt), at: 0) }
        var payload: [String: Any] = ["model": config.model,
            "messages": allMessages.map { ["role": $0.role, "content": $0.content] }, "stream": true]
        // Leave optional vendor parameters absent for other OpenAI-compatible endpoints.
        options.apply(to: &payload)
        let request = try LLMHTTPClient.request(
            url: config.url.appendingPathComponent("chat/completions"), method: "POST",
            payload: payload,
            headers: config.headers.merging(["Accept": "text/event-stream"]) { _, new in new }
        )
        return try await LLMHTTPClient.stream(for: request, session: session, format: .openAI)
    }

    public func testConnection() async throws -> Bool {
        let config = try configuration()
        let request = try LLMHTTPClient.request(url: config.url.appendingPathComponent("models"), headers: config.headers, timeout: 10)
        let json = try await LLMHTTPClient.jsonResponse(for: request, session: session)
        guard let models = json["data"] as? [[String: Any]] else {
            throw LLMProviderError.invalidResponse("模型列表格式无效，请确认 Base URL 是 OpenAI 兼容接口。")
        }
        guard models.contains(where: { $0["id"] as? String == config.model }) else {
            throw LLMProviderError.modelUnavailable(config.model)
        }
        return true
    }
}
