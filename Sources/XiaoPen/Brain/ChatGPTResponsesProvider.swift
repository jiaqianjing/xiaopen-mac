import Foundation

/// OpenAI Responses API billed to the user's ChatGPT plan through Sign in with ChatGPT.
/// The plan route requires `store: false` and `stream: true`, history in `input`,
/// and the system prompt as `instructions`; sampling fields are not accepted.
public final class ChatGPTResponsesProvider: LLMProviderProtocol {
    private let model: String
    private let lowReasoning: Bool
    private let session: URLSession
    private let token: @Sendable () async throws -> String

    public init(model: String, lowReasoning: Bool, session: URLSession = .shared,
                token: @escaping @Sendable () async throws -> String) {
        self.model = model
        self.lowReasoning = lowReasoning
        self.session = session
        self.token = token
    }

    private func request(_ path: String, payload: [String: Any]?) async throws -> URLRequest {
        let model = try LLMHTTPClient.model(model)
        var payload = payload
        payload?["model"] = model
        let accessToken = try await token()
        return try LLMHTTPClient.request(
            url: URL(string: "\(ChatGPTAuth.resource)/\(path)")!, method: payload == nil ? "GET" : "POST",
            payload: payload,
            headers: ["Authorization": "Bearer \(accessToken)", "Accept": payload == nil ? "application/json" : "text/event-stream"],
            timeout: payload == nil ? 15 : 60)
    }

    public func streamChat(messages: [ChatMessage], systemPrompt: String) async throws -> AsyncThrowingStream<String, Error> {
        let input: [[String: Any]] = messages.filter { $0.role != "system" }.map { message in
            let type = message.role == "assistant" ? "output_text" : "input_text"
            return ["role": message.role, "content": [["type": type, "text": message.content]]]
        }
        var payload: [String: Any] = ["instructions": systemPrompt, "input": input, "stream": true, "store": false]
        if lowReasoning { payload["reasoning"] = ["effort": "low"] }
        do {
            return try await LLMHTTPClient.stream(for: try await request("responses", payload: payload),
                                                  session: session, format: .openAIResponses)
        } catch LLMProviderError.httpError(400, let message) where lowReasoning && (message ?? "").contains("reasoning") {
            // Models without reasoning reject the effort setting; retry once without it.
            payload["reasoning"] = nil
            return try await LLMHTTPClient.stream(for: try await request("responses", payload: payload),
                                                  session: session, format: .openAIResponses)
        }
    }

    public func testConnection() async throws -> Bool {
        let json = try await LLMHTTPClient.jsonResponse(for: try await request("models", payload: nil), session: session)
        guard let models = ChatGPTAuth.modelIDs(in: json) else {
            throw LLMProviderError.invalidResponse("模型列表格式无效。")
        }
        guard models.contains(model) else {
            throw LLMProviderError.modelUnavailable(model)
        }
        return true
    }
}
