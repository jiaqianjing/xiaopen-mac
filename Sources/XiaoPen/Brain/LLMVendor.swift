import Foundation

/// OpenAI-compatible platforms with known defaults and request extensions.
/// The base URL stays editable; request options follow the URL's host so a
/// "custom" entry pointing at a known platform still gets the right extensions.
public enum LLMVendor: String, CaseIterable, Identifiable, Codable, Sendable {
    case qianwen
    case deepseek
    case kimi
    case minimax
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .qianwen: return "千问 AI 平台"
        case .deepseek: return "DeepSeek"
        case .kimi: return "Kimi（月之暗面）"
        case .minimax: return "MiniMax"
        case .custom: return "自定义 OpenAI 兼容"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .qianwen: return "https://maas.qianwenaiapi.com/compatible-mode/v1"
        case .deepseek: return "https://api.deepseek.com/v1"
        case .kimi: return "https://api.moonshot.cn/v1"
        case .minimax: return "https://api.minimaxi.com/v1"
        case .custom: return "https://api.openai.com/v1"
        }
    }

    /// Fast, voice-friendly models first. Model catalogs change, so the field stays free text.
    public var suggestedModels: [String] {
        switch self {
        case .qianwen: return ["deepseek-v4.1-flash", "qwen3.8-flash", "qwen-flash", "qwen3.7-plus", "kimi-k2.6"]
        case .deepseek: return ["deepseek-v4-flash", "deepseek-v4-pro"]
        case .kimi: return ["kimi-k2.6", "kimi-k3"]
        case .minimax: return ["MiniMax-M2.7-highspeed", "MiniMax-M3", "MiniMax-M2.7"]
        case .custom: return ["gpt-4o-mini"]
        }
    }

    public var defaultModel: String { suggestedModels[0] }

    public var consoleURL: URL? {
        switch self {
        case .qianwen: return URL(string: "https://platform.qianwenai.com/home")
        case .deepseek: return URL(string: "https://platform.deepseek.com/api_keys")
        case .kimi: return URL(string: "https://platform.moonshot.cn/console/api-keys")
        case .minimax: return URL(string: "https://platform.minimaxi.com")
        case .custom: return nil
        }
    }

    public static func infer(fromBaseURL value: String) -> LLMVendor {
        guard let host = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() else {
            return .custom
        }
        if host.contains("qianwenai") || host.contains("dashscope") { return .qianwen }
        if host.hasSuffix("deepseek.com") { return .deepseek }
        if host.contains("moonshot") || host.contains("kimi.com") { return .kimi }
        if host.contains("minimax") { return .minimax }
        return .custom
    }

    /// How the platform toggles reasoning for this model, or nil when it cannot be
    /// switched off (or the platform/model is unknown). Sending an unsupported
    /// switch makes some models reject the whole request, so this is an allowlist.
    func thinkingControl(model: String) -> ThinkingControl? {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch self {
        case .qianwen:
            let hybrid = ["deepseek-v4", "deepseek-v3.1", "deepseek-v3.2", "qwen3", "qwen-plus", "qwen-flash",
                          "qwen-turbo", "kimi-k2.5", "kimi-k2.6", "kimi-k3"]
            return hybrid.contains(where: model.hasPrefix) ? .enableThinkingFlag : nil
        case .deepseek:
            return model.hasPrefix("deepseek-v4") ? .thinkingType(enabled: "enabled") : nil
        case .kimi:
            return model.hasPrefix("kimi-k2.5") || model.hasPrefix("kimi-k2.6") ? .thinkingType(enabled: "enabled") : nil
        case .minimax:
            return model == "minimax-m3" ? .thinkingType(enabled: "adaptive") : nil
        case .custom:
            return nil
        }
    }

    func requestOptions(model: String, thinkingEnabled: Bool) -> OpenAIVendorOptions {
        var options = OpenAIVendorOptions()
        switch thinkingControl(model: model) {
        case .enableThinkingFlag: options.enableThinking = thinkingEnabled
        case .thinkingType(let enabled): options.thinkingType = thinkingEnabled ? enabled : "disabled"
        case nil: break
        }
        // Keeps MiniMax reasoning out of `content`, so it is never read aloud.
        if self == .minimax { options.reasoningSplit = true }
        return options
    }

    enum ThinkingControl: Equatable {
        case enableThinkingFlag
        case thinkingType(enabled: String)
    }
}

/// Vendor extensions outside the OpenAI schema; absent fields are not sent.
public struct OpenAIVendorOptions: Sendable, Equatable {
    public var enableThinking: Bool?
    public var thinkingType: String?
    public var reasoningSplit = false

    public init(enableThinking: Bool? = nil, thinkingType: String? = nil, reasoningSplit: Bool = false) {
        self.enableThinking = enableThinking
        self.thinkingType = thinkingType
        self.reasoningSplit = reasoningSplit
    }

    var supportsThinkingToggle: Bool { enableThinking != nil || thinkingType != nil }

    func apply(to payload: inout [String: Any]) {
        if let enableThinking { payload["enable_thinking"] = enableThinking }
        if let thinkingType { payload["thinking"] = ["type": thinkingType] }
        if reasoningSplit { payload["reasoning_split"] = true }
    }
}
