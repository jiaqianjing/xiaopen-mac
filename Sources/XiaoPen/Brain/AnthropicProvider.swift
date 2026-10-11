import Foundation

/// Anthropic Messages API over raw HTTP (there is no official Swift SDK). Works with
/// api.anthropic.com and with Anthropic-compatible endpoints such as DeepSeek's.
public final class AnthropicProvider: LLMProviderProtocol {
    public static let officialBaseURL = "https://api.anthropic.com"

    private let baseURL: String
    private let apiKey: String
    private let model: String
    private let session: URLSession

    public init(baseURL: String = AnthropicProvider.officialBaseURL, apiKey: String, model: String,
                session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    private struct Configuration {
        let root: URL
        let model: String
        let headers: [String: String]
        let isOfficial: Bool
    }

    private func configuration() throws -> Configuration {
        var root = try LLMHTTPClient.baseURL(baseURL)
        // Accept both ".../anthropic" and ".../anthropic/v1".
        if root.lastPathComponent == "v1" { root.deleteLastPathComponent() }
        let model = try LLMHTTPClient.model(model)
        let key = try LLMHTTPClient.apiKey(apiKey, required: true)
        let isOfficial = root.host?.lowercased() == "api.anthropic.com"
        var headers = ["x-api-key": key, "anthropic-version": "2023-06-01"]
        // Compatible services differ in which header they read (Claude Code's
        // ANTHROPIC_AUTH_TOKEN is a bearer token), so send both there.
        if !isOfficial { headers["Authorization"] = "Bearer \(key)" }
        return Configuration(root: root, model: model, headers: headers, isOfficial: isOfficial)
    }

    public func streamChat(messages: [ChatMessage], systemPrompt: String) async throws -> AsyncThrowingStream<String, Error> {
        let config = try configuration()
        var payload: [String: Any] = [
            "model": config.model, "max_tokens": 4096, "system": systemPrompt, "stream": true,
            "messages": messages.filter { $0.role != "system" }.map { ["role": $0.role, "content": $0.content] }
        ]
        // Current Claude models always think; low effort keeps spoken replies quick.
        if config.isOfficial, Self.supportsEffort(config.model) {
            payload["output_config"] = ["effort": "low"]
        }
        let request = try LLMHTTPClient.request(
            url: config.root.appendingPathComponent("v1/messages"), method: "POST", payload: payload,
            headers: config.headers.merging(["Accept": "text/event-stream"]) { _, new in new }
        )
        return try await LLMHTTPClient.stream(for: request, session: session, format: .anthropic)
    }

    public func testConnection() async throws -> Bool {
        let config = try configuration()
        if config.isOfficial {
            let url = config.root.appendingPathComponent("v1/models").appendingPathComponent(config.model)
            let request = try LLMHTTPClient.request(url: url, headers: config.headers, timeout: 10)
            let json = try await LLMHTTPClient.jsonResponse(for: request, session: session)
            guard json["type"] as? String == "model", let id = json["id"] as? String, !id.isEmpty else {
                throw LLMProviderError.invalidResponse("模型信息格式无效，请检查 Claude 模型名称。")
            }
            return true
        }
        // Compatible services rarely implement the Models API; a one-token message is the reliable check.
        let request = try LLMHTTPClient.request(
            url: config.root.appendingPathComponent("v1/messages"), method: "POST",
            payload: ["model": config.model, "max_tokens": 1,
                      "messages": [["role": "user", "content": "ping"]]],
            headers: config.headers, timeout: 15)
        let json = try await LLMHTTPClient.jsonResponse(for: request, session: session)
        guard json["type"] as? String == "message" || json["content"] != nil else {
            throw LLMProviderError.invalidResponse("服务没有返回 Anthropic 格式的消息，请检查地址是否为 Anthropic 兼容接口。")
        }
        return true
    }

    /// `output_config.effort` exists on the Claude 4.6+ generations; older models reject it.
    static func supportsEffort(_ model: String) -> Bool {
        let model = model.lowercased()
        let prefixes = ["claude-opus-5", "claude-sonnet-5", "claude-haiku-5", "claude-fable-5", "claude-mythos-5",
                        "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8", "claude-sonnet-4-6"]
        return prefixes.contains(where: model.hasPrefix)
    }
}

/// Builds the request client for a protocol; the single place that maps settings to a provider.
enum LLMProviderFactory {
    static func make(protocolType: LLMProviderType, baseURL: String, model: String, apiKey: String,
                     options: OpenAIVendorOptions, thinkingEnabled: Bool = false,
                     session: URLSession = .shared) -> any LLMProviderProtocol {
        switch protocolType {
        case .chatGPT:
            return ChatGPTResponsesProvider(model: model, lowReasoning: !thinkingEnabled, session: session) {
                try await ChatGPTAuth.shared.accessToken()
            }
        case .ollama:
            return OllamaProvider(baseURL: baseURL, model: model, session: session)
        case .anthropic:
            return AnthropicProvider(baseURL: baseURL, apiKey: apiKey, model: model, session: session)
        case .openAI:
            return OpenAIProvider(baseURL: baseURL, apiKey: apiKey, model: model, session: session, options: options)
        }
    }
}
