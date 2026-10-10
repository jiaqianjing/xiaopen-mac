import Foundation
import Observation

public enum LLMProviderType: String, CaseIterable, Identifiable, Codable, Sendable {
    case ollama = "ollama"
    case anthropic = "anthropic"
    case openAI = "openai"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .ollama: return "本地 Ollama"
        case .anthropic: return "Anthropic (Claude)"
        case .openAI: return "OpenAI 兼容接口"
        }
    }
}

public enum TTSEngineType: String, CaseIterable, Identifiable, Codable, Sendable {
    case system = "system"
    case localQwen = "local_qwen"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "系统语音"
        case .localQwen: return "本机 Qwen3-TTS"
        }
    }
}

public enum QwenVoice: String, CaseIterable, Identifiable, Codable, Sendable {
    case serena = "Serena"
    case vivian = "Vivian"
    case uncleFu = "Uncle_Fu"
    case dylan = "Dylan"
    case eric = "Eric"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .serena: return "Serena · 温柔女声"
        case .vivian: return "Vivian · 明亮女声"
        case .uncleFu: return "福叔 · 醇厚男声"
        case .dylan: return "Dylan · 北京男声"
        case .eric: return "Eric · 四川男声"
        }
    }
}

@Observable
public final class AppPreferences: @unchecked Sendable {
    public static let shared = AppPreferences()
    private let defaults: UserDefaults
    private let apiKeyCacheLock = NSLock()
    // Keyed by keychain account so each OpenAI-compatible platform keeps its own key.
    @ObservationIgnored private var cachedAPIKeys: [String: String] = [:]
    
    // MARK: - LLM Settings
    public var providerType: LLMProviderType {
        didSet { defaults.set(providerType.rawValue, forKey: "providerType") }
    }
    
    public var systemPrompt: String {
        didSet { defaults.set(systemPrompt, forKey: "systemPrompt") }
    }
    
    // Ollama
    public var ollamaBaseURL: String {
        didSet { defaults.set(ollamaBaseURL, forKey: "ollamaBaseURL") }
    }
    public var ollamaModel: String {
        didSet { defaults.set(ollamaModel, forKey: "ollamaModel") }
    }
    
    // Anthropic
    public var anthropicModel: String {
        didSet { defaults.set(anthropicModel, forKey: "anthropicModel") }
    }
    
    // OpenAI Compatible
    public private(set) var openAIVendor: LLMVendor {
        didSet { defaults.set(openAIVendor.rawValue, forKey: "openAIVendor") }
    }
    /// The vendor whose key was saved before per-platform keys existed; it keeps the old account.
    @ObservationIgnored private let legacyKeyVendor: LLMVendor
    public var openAIBaseURL: String {
        didSet {
            defaults.set(openAIBaseURL, forKey: "openAIBaseURL")
            defaults.set(openAIBaseURL, forKey: "vendor.\(openAIVendor.rawValue).baseURL")
        }
    }
    public var openAIModel: String {
        didSet {
            defaults.set(openAIModel, forKey: "openAIModel")
            defaults.set(openAIModel, forKey: "vendor.\(openAIVendor.rawValue).model")
        }
    }

    public var openAIThinkingEnabled: Bool {
        didSet { defaults.set(openAIThinkingEnabled, forKey: "openAIThinkingEnabled") }
    }

    /// Switches platform while remembering each platform's own address and model.
    public func selectVendor(_ vendor: LLMVendor) {
        guard vendor != openAIVendor else { return }
        openAIVendor = vendor
        openAIBaseURL = defaults.string(forKey: "vendor.\(vendor.rawValue).baseURL") ?? vendor.defaultBaseURL
        openAIModel = defaults.string(forKey: "vendor.\(vendor.rawValue).model") ?? vendor.defaultModel
    }

    /// Extensions follow the actual host, not the picker, so a custom entry for a known platform still works.
    public var openAIRequestOptions: OpenAIVendorOptions {
        LLMVendor.infer(fromBaseURL: openAIBaseURL).requestOptions(model: openAIModel, thinkingEnabled: openAIThinkingEnabled)
    }

    public var supportsThinkingControl: Bool { openAIRequestOptions.supportsThinkingToggle }

    public var openAIThinkingOption: Bool? {
        let options = openAIRequestOptions
        if let flag = options.enableThinking { return flag }
        return options.thinkingType.map { $0 != "disabled" }
    }

    /// The chat endpoint for connection warm-up; local Ollama needs none.
    public var activeEndpointURL: URL? {
        switch providerType {
        case .ollama: return nil
        case .anthropic: return URL(string: "https://api.anthropic.com")
        case .openAI: return URL(string: openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: - Assistant Skills
    /// Default city for weather questions that do not name a place.
    public var weatherCity: String {
        didSet { defaults.set(weatherCity, forKey: "weatherCity") }
    }
    /// Use Location Services when no default city is set.
    public var usesAutomaticLocation: Bool {
        didSet { defaults.set(usesAutomaticLocation, forKey: "usesAutomaticLocation") }
    }
    /// After a spoken reply, keep listening briefly so a follow-up needs no wake word.
    public var isFollowUpEnabled: Bool {
        didSet { defaults.set(isFollowUpEnabled, forKey: "isFollowUpEnabled") }
    }
    public var followUpSeconds: Double {
        didSet { defaults.set(followUpSeconds, forKey: "followUpSeconds") }
    }
    /// Standby transcripts include everything said near the Mac, so they are hidden by default.
    public var showsStandbyTranscript: Bool {
        didSet { defaults.set(showsStandbyTranscript, forKey: "showsStandbyTranscript") }
    }
    public var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") }
    }
    public var isGlobalHotKeyEnabled: Bool {
        didSet { defaults.set(isGlobalHotKeyEnabled, forKey: "isGlobalHotKeyEnabled") }
    }
    
    // MARK: - Wake Word & Voice Settings
    public var wakeWord: String {
        didSet { defaults.set(wakeWord, forKey: "wakeWord") }
    }
    public var isWakeWordEnabled: Bool {
        didSet { defaults.set(isWakeWordEnabled, forKey: "isWakeWordEnabled") }
    }
    public var ttsEngine: TTSEngineType {
        didSet { defaults.set(ttsEngine.rawValue, forKey: "ttsEngine") }
    }
    public var qwenVoice: QwenVoice {
        didSet { defaults.set(qwenVoice.rawValue, forKey: "qwenVoice") }
    }
    public var qwenVoiceStyle: String {
        didSet { defaults.set(qwenVoiceStyle, forKey: "qwenVoiceStyle") }
    }
    public var ttsVoiceRate: Float {
        didSet { defaults.set(ttsVoiceRate, forKey: "ttsVoiceRate") }
    }
    public var autoDismissSeconds: Double {
        didSet { defaults.set(autoDismissSeconds, forKey: "autoDismissSeconds") }
    }
    
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        
        self.providerType = LLMProviderType(rawValue: defaults.string(forKey: "providerType") ?? "") ?? .ollama
        self.systemPrompt = defaults.string(forKey: "systemPrompt") ?? "你是小喷，住在家里的智能桌面伙伴。说话简短、自然、温暖、幽默，回答通常在一两句话以内，不长篇大论。"
        
        self.ollamaBaseURL = defaults.string(forKey: "ollamaBaseURL") ?? "http://127.0.0.1:11434"
        self.ollamaModel = defaults.string(forKey: "ollamaModel") ?? "qwen2.5:latest"
        
        let savedClaudeModel = defaults.string(forKey: "anthropicModel")
        if savedClaudeModel == nil || savedClaudeModel == "claude-3-5-sonnet-latest" {
            self.anthropicModel = "claude-sonnet-4-6"
            defaults.set("claude-sonnet-4-6", forKey: "anthropicModel")
        } else {
            self.anthropicModel = savedClaudeModel!
        }
        
        let baseURL = defaults.string(forKey: "openAIBaseURL") ?? LLMVendor.custom.defaultBaseURL
        let model = defaults.string(forKey: "openAIModel") ?? LLMVendor.custom.defaultModel
        let vendor: LLMVendor
        if let saved = defaults.string(forKey: "openAIVendor").flatMap(LLMVendor.init(rawValue:)) {
            vendor = saved
        } else {
            // First launch with platform presets: adopt the platform already configured.
            vendor = LLMVendor.infer(fromBaseURL: baseURL)
            defaults.set(vendor.rawValue, forKey: "openAIVendor")
            defaults.set(baseURL, forKey: "vendor.\(vendor.rawValue).baseURL")
            defaults.set(model, forKey: "vendor.\(vendor.rawValue).model")
        }
        self.openAIVendor = vendor
        if let saved = defaults.string(forKey: "legacyKeyVendor").flatMap(LLMVendor.init(rawValue:)) {
            self.legacyKeyVendor = saved
        } else {
            self.legacyKeyVendor = vendor
            defaults.set(vendor.rawValue, forKey: "legacyKeyVendor")
        }
        self.openAIBaseURL = baseURL
        self.openAIModel = model
        self.openAIThinkingEnabled = defaults.object(forKey: "openAIThinkingEnabled") as? Bool ?? false
        self.weatherCity = defaults.string(forKey: "weatherCity") ?? ""
        self.usesAutomaticLocation = defaults.object(forKey: "usesAutomaticLocation") as? Bool ?? true
        self.isFollowUpEnabled = defaults.object(forKey: "isFollowUpEnabled") as? Bool ?? true
        self.followUpSeconds = defaults.double(forKey: "followUpSeconds") == 0 ? 6 : defaults.double(forKey: "followUpSeconds")
        self.showsStandbyTranscript = defaults.object(forKey: "showsStandbyTranscript") as? Bool ?? false
        self.isGlobalHotKeyEnabled = defaults.object(forKey: "isGlobalHotKeyEnabled") as? Bool ?? true
        // People who already configured a model skip the first-run guide.
        self.hasCompletedOnboarding = defaults.object(forKey: "hasCompletedOnboarding") as? Bool
            ?? (defaults.string(forKey: "providerType") != nil)
        
        self.wakeWord = defaults.string(forKey: "wakeWord") ?? "小喷小喷"
        self.isWakeWordEnabled = defaults.object(forKey: "isWakeWordEnabled") as? Bool ?? true
        self.ttsEngine = TTSEngineType(rawValue: defaults.string(forKey: "ttsEngine") ?? "") ?? .system
        self.qwenVoice = QwenVoice(rawValue: defaults.string(forKey: "qwenVoice") ?? "") ?? .serena
        self.qwenVoiceStyle = defaults.string(forKey: "qwenVoiceStyle") ?? "用自然、轻松、温暖的语气说话，像和朋友聊天，避免播音腔。"
        self.ttsVoiceRate = defaults.float(forKey: "ttsVoiceRate") == 0 ? 0.52 : defaults.float(forKey: "ttsVoiceRate")
        self.autoDismissSeconds = defaults.double(forKey: "autoDismissSeconds") == 0 ? 4.0 : defaults.double(forKey: "autoDismissSeconds")
    }
    
    // MARK: - Keychain Accessors
    /// Keychain account for a provider; OpenAI-compatible platforms each have their own.
    public func apiKeyAccount(for provider: LLMProviderType, vendor: LLMVendor? = nil) -> String? {
        switch provider {
        case .ollama: return nil
        case .anthropic: return "anthropic_api_key"
        case .openAI:
            let vendor = vendor ?? openAIVendor
            return vendor == legacyKeyVendor ? "openai_api_key" : "\(vendor.rawValue)_api_key"
        }
    }

    public var anthropicAPIKey: String { cachedOrStoredKey(account: "anthropic_api_key") }

    public var openAIAPIKey: String {
        apiKeyAccount(for: .openAI).map(cachedOrStoredKey(account:)) ?? ""
    }

    private func cachedOrStoredKey(account: String) -> String {
        if let cached = apiKeyCacheLock.withLock({ cachedAPIKeys[account] }) { return cached }
        return KeychainHelper.load(key: account) ?? ""
    }

    public func cacheAPIKey(_ value: String, for provider: LLMProviderType) {
        guard let account = apiKeyAccount(for: provider) else { return }
        cacheAPIKey(value, account: account)
    }

    public func cacheAPIKey(_ value: String, account: String) {
        apiKeyCacheLock.withLock { cachedAPIKeys[account] = value }
    }

    public func readAPIKey(for provider: LLMProviderType) async throws -> String {
        guard let account = apiKeyAccount(for: provider) else { return "" }
        return try await readAPIKey(account: account)
    }

    public func readAPIKey(account: String) async throws -> String {
        if let cached = apiKeyCacheLock.withLock({ cachedAPIKeys[account] }) { return cached }
        let value = try await KeychainHelper.readKeyAsync(key: account) ?? ""
        try Task.checkCancellation()
        cacheAPIKey(value, account: account)
        return value
    }

    public func saveAPIKey(_ value: String, account: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try KeychainHelper.delete(key: account)
        } else {
            try KeychainHelper.save(key: account, data: trimmed)
        }
        cacheAPIKey(trimmed, account: account)
    }
}
