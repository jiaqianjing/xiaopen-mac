import Foundation

/// One entry in the brain picker. Adding a provider is one entry here (plus, when
/// it has request quirks, a case in `LLMVendor`).
public struct ProviderPreset: Identifiable, Hashable, Sendable {
    public enum Group: Int, CaseIterable, Sendable {
        case vendor, generic, local

        public var title: String {
            switch self {
            case .vendor: return "服务商"
            case .generic: return "通用接口"
            case .local: return "本机"
            }
        }
    }

    public let id: String
    public let name: String
    public let group: Group
    /// Default base URL for each protocol the provider speaks; the first is the default protocol.
    public let endpoints: [(protocolType: LLMProviderType, baseURL: String)]
    public let suggestedModels: [String]
    public let consoleURL: URL?
    public let requiresKey: Bool
    public let note: String?

    public var protocols: [LLMProviderType] { endpoints.map(\.protocolType) }
    public var defaultProtocol: LLMProviderType { endpoints[0].protocolType }
    public var defaultModel: String { suggestedModels.first ?? "" }

    public func defaultBaseURL(for protocolType: LLMProviderType) -> String {
        endpoints.first { $0.protocolType == protocolType }?.baseURL ?? ""
    }

    public static func == (lhs: ProviderPreset, rhs: ProviderPreset) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public enum ProviderCatalog {
    public static let all: [ProviderPreset] = [
        ProviderPreset(
            id: "qianwen", name: "千问 AI 平台", group: .vendor,
            endpoints: [(.openAI, "https://maas.qianwenaiapi.com/compatible-mode/v1")],
            suggestedModels: ["deepseek-v4.1-flash", "qwen3.8-flash", "qwen-flash", "qwen3.7-plus", "kimi-k2.6"],
            consoleURL: URL(string: "https://platform.qianwenai.com/home"), requiresKey: true,
            note: "支持联网搜索。"),
        ProviderPreset(
            id: "deepseek", name: "DeepSeek", group: .vendor,
            endpoints: [(.openAI, "https://api.deepseek.com/v1"), (.anthropic, "https://api.deepseek.com/anthropic")],
            suggestedModels: ["deepseek-v4-flash", "deepseek-v4-pro"],
            consoleURL: URL(string: "https://platform.deepseek.com/api_keys"), requiresKey: true, note: nil),
        ProviderPreset(
            id: "kimi", name: "Kimi（月之暗面）", group: .vendor,
            endpoints: [(.openAI, "https://api.moonshot.cn/v1")],
            suggestedModels: ["kimi-k2.6", "kimi-k3"],
            consoleURL: URL(string: "https://platform.moonshot.cn/console/api-keys"), requiresKey: true, note: nil),
        ProviderPreset(
            id: "minimax", name: "MiniMax", group: .vendor,
            endpoints: [(.openAI, "https://api.minimaxi.com/v1")],
            suggestedModels: ["MiniMax-M2.7-highspeed", "MiniMax-M3", "MiniMax-M2.7"],
            consoleURL: URL(string: "https://platform.minimaxi.com"), requiresKey: true, note: nil),
        ProviderPreset(
            id: "zhipu", name: "智谱 GLM", group: .vendor,
            endpoints: [(.openAI, "https://open.bigmodel.cn/api/paas/v4")],
            suggestedModels: ["glm-4.7-flash", "glm-5.2"],
            consoleURL: URL(string: "https://open.bigmodel.cn/usercenter/apikeys"), requiresKey: true,
            note: "glm-4.7-flash 可免费调用。"),
        ProviderPreset(
            id: "volcengine", name: "火山方舟（豆包）", group: .vendor,
            endpoints: [(.openAI, "https://ark.cn-beijing.volces.com/api/v3")],
            suggestedModels: ["doubao-seed-2-0-mini-260215", "doubao-seed-2-0-lite-260215", "doubao-seed-1-6-flash-250828"],
            consoleURL: URL(string: "https://console.volcengine.com/ark/region:ark+cn-beijing/apiKey"), requiresKey: true,
            note: "模型名称以方舟控制台“模型列表”为准。"),
        ProviderPreset(
            id: "openrouter", name: "OpenRouter", group: .vendor,
            endpoints: [(.openAI, "https://openrouter.ai/api/v1")],
            suggestedModels: ["google/gemini-2.5-flash", "openai/gpt-4o-mini"],
            consoleURL: URL(string: "https://openrouter.ai/settings/keys"), requiresKey: true,
            note: "一个密钥可用多家海外模型，模型名写成“厂商/模型”。国内网络可能需要代理。"),
        ProviderPreset(
            id: "chatgpt", name: "ChatGPT 订阅", group: .vendor,
            endpoints: [(.chatGPT, "https://api.openai.com/v1")],
            suggestedModels: [], consoleURL: URL(string: "https://chatgpt.com/#settings"), requiresKey: false,
            note: "用 ChatGPT 账号登录后，回答消耗你的 ChatGPT 订阅额度，不需要 API Key。国内网络需要代理。"),
        ProviderPreset(
            id: "anthropic", name: "Anthropic Claude", group: .vendor,
            endpoints: [(.anthropic, "https://api.anthropic.com")],
            suggestedModels: ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"],
            consoleURL: URL(string: "https://console.anthropic.com/settings/keys"), requiresKey: true,
            note: "语音对话要更快，可以在“常用”里选 Sonnet 或 Haiku。"),
        ProviderPreset(
            id: "custom", name: "OpenAI 兼容（自定义）", group: .generic,
            endpoints: [(.openAI, "https://api.openai.com/v1")],
            suggestedModels: ["gpt-4o-mini"], consoleURL: nil, requiresKey: false,
            note: "填写任意兼容 OpenAI Chat Completions 的服务。自建服务无需鉴权时可以不填密钥。"),
        ProviderPreset(
            id: "anthropic-compatible", name: "Anthropic 兼容（自定义）", group: .generic,
            endpoints: [(.anthropic, "")],
            suggestedModels: [], consoleURL: nil, requiresKey: true,
            note: "填写兼容 Anthropic Messages 接口的服务地址（不含 /v1/messages），例如各平台提供给 Claude Code 使用的地址。"),
        ProviderPreset(
            id: "ollama", name: "Ollama", group: .local,
            endpoints: [(.ollama, "http://127.0.0.1:11434")],
            suggestedModels: ["qwen2.5:latest"], consoleURL: nil, requiresKey: false,
            note: "填写本机已安装、支持文本对话的模型。"),
    ]

    public static let defaultID = "qianwen"

    public static func preset(id: String) -> ProviderPreset? {
        all.first { $0.id == id }
    }

    public static func preset(forLegacyVendor vendor: LLMVendor) -> ProviderPreset {
        preset(id: vendor.rawValue) ?? preset(id: "custom")!
    }
}
