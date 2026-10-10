import Foundation

public final class OllamaProvider: LLMProviderProtocol {
    private let baseURL: String
    private let model: String
    private let session: URLSession

    public init(baseURL: String, model: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.model = model
        self.session = session
    }

    public func streamChat(messages: [ChatMessage], systemPrompt: String) async throws -> AsyncThrowingStream<String, Error> {
        let url = try LLMHTTPClient.baseURL(baseURL)
        let model = try LLMHTTPClient.model(model)
        var allMessages = messages
        if !systemPrompt.isEmpty { allMessages.insert(ChatMessage(role: "system", content: systemPrompt), at: 0) }
        let request = try LLMHTTPClient.request(
            url: url.appendingPathComponent("api/chat"), method: "POST",
            payload: ["model": model, "messages": allMessages.map { ["role": $0.role, "content": $0.content] }, "stream": true]
        )
        return try await LLMHTTPClient.stream(for: request, session: session, format: .ollama)
    }

    public func testConnection() async throws -> Bool {
        let url = try LLMHTTPClient.baseURL(baseURL)
        let model = try LLMHTTPClient.model(model)
        let request = try LLMHTTPClient.request(url: url.appendingPathComponent("api/show"), method: "POST", payload: ["model": model], timeout: 10)
        let json = try await LLMHTTPClient.jsonResponse(for: request, session: session)
        guard json["details"] is [String: Any] || json["model_info"] is [String: Any] else {
            throw LLMProviderError.invalidResponse("Ollama 没有返回有效模型信息，请检查服务地址。")
        }
        if let capabilities = json["capabilities"] as? [String], !capabilities.contains("completion") {
            throw LLMProviderError.invalidConfiguration("所选 Ollama 模型不支持文本对话，请选择对话模型。")
        }
        return true
    }
}
