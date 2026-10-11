import Foundation

/// Request quirks of known OpenAI-compatible platforms, detected from the base
/// URL's host so a generic entry pointing at a known platform still works.
/// Names, default addresses and models live in `ProviderCatalog`.
public enum LLMVendor: String, CaseIterable, Identifiable, Codable, Sendable {
    case qianwen
    case deepseek
    case kimi
    case minimax
    case zhipu
    case volcengine
    case openrouter
    case custom

    public var id: String { rawValue }

    public static func infer(fromBaseURL value: String) -> LLMVendor {
        guard let host = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() else {
            return .custom
        }
        if host.contains("qianwenai") || host.contains("dashscope") { return .qianwen }
        if host.hasSuffix("deepseek.com") { return .deepseek }
        if host.contains("moonshot") || host.contains("kimi.com") { return .kimi }
        if host.contains("minimax") { return .minimax }
        if host.hasSuffix("bigmodel.cn") || host.hasSuffix("z.ai") { return .zhipu }
        if host.hasSuffix("volces.com") || host.hasSuffix("volcengineapi.com") { return .volcengine }
        if host.hasSuffix("openrouter.ai") { return .openrouter }
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
        case .zhipu:
            // GLM-5.3 always reasons and rejects "disabled".
            let hybrid = ["glm-4.5", "glm-4.6", "glm-4.7", "glm-5.2"]
            return hybrid.contains(where: model.hasPrefix) ? .thinkingType(enabled: "enabled") : nil
        case .volcengine:
            return model.hasPrefix("doubao-seed") ? .thinkingType(enabled: "enabled") : nil
        case .openrouter, .custom:
            // OpenRouter's reasoning switch differs per upstream model and can 400.
            return nil
        }
    }

    /// Platforms whose OpenAI-compatible chat endpoint can search the web by itself.
    public var supportsWebSearch: Bool { self == .qianwen }

    func requestOptions(model: String, thinkingEnabled: Bool, webSearch: Bool = false) -> OpenAIVendorOptions {
        var options = OpenAIVendorOptions()
        // The model decides when to search; "turbo" is the platform's fastest strategy.
        if webSearch, supportsWebSearch { options.enableSearch = true }
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
    public var enableSearch = false

    public init(enableThinking: Bool? = nil, thinkingType: String? = nil, reasoningSplit: Bool = false,
                enableSearch: Bool = false) {
        self.enableThinking = enableThinking
        self.thinkingType = thinkingType
        self.reasoningSplit = reasoningSplit
        self.enableSearch = enableSearch
    }

    var supportsThinkingToggle: Bool { enableThinking != nil || thinkingType != nil }

    func apply(to payload: inout [String: Any]) {
        if let enableThinking { payload["enable_thinking"] = enableThinking }
        if let thinkingType { payload["thinking"] = ["type": thinkingType] }
        if reasoningSplit { payload["reasoning_split"] = true }
        if enableSearch {
            payload["enable_search"] = true
            payload["search_options"] = ["search_strategy": "turbo"]
        }
    }
}
