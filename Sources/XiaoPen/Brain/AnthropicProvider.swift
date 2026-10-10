import Foundation

public final class AnthropicProvider: LLMProviderProtocol {
    private let apiKey: String
    private let model: String
    private let session: URLSession

    public init(apiKey: String, model: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    private func configuration() throws -> (model: String, headers: [String: String]) {
        let model = try LLMHTTPClient.model(model)
        let key = try LLMHTTPClient.apiKey(apiKey, required: true)
        return (model, ["x-api-key": key, "anthropic-version": "2023-06-01"])
    }

    public func streamChat(messages: [ChatMessage], systemPrompt: String) async throws -> AsyncThrowingStream<String, Error> {
        let config = try configuration()
        let request = try LLMHTTPClient.request(
            url: URL(string: "https://api.anthropic.com/v1/messages")!, method: "POST",
            payload: ["model": config.model, "max_tokens": 600, "system": systemPrompt,
                      "messages": messages.filter { $0.role != "system" }.map { ["role": $0.role, "content": $0.content] }, "stream": true],
            headers: config.headers.merging(["Accept": "text/event-stream"]) { _, new in new }
        )
        return try await LLMHTTPClient.stream(for: request, session: session, format: .anthropic)
    }

    public func testConnection() async throws -> Bool {
        let config = try configuration()
        let url = URL(string: "https://api.anthropic.com/v1/models")!.appendingPathComponent(config.model)
        let request = try LLMHTTPClient.request(url: url, headers: config.headers, timeout: 10)
        let json = try await LLMHTTPClient.jsonResponse(for: request, session: session)
        guard json["type"] as? String == "model", let id = json["id"] as? String, !id.isEmpty else {
            throw LLMProviderError.invalidResponse("模型信息格式无效，请检查 Claude 模型名称。")
        }
        return true
    }
}
