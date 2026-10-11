import Foundation
import Observation

public enum LLMProviderType: String, CaseIterable, Identifiable, Codable, Sendable {
    case ollama = "ollama"
    case anthropic = "anthropic"
    case openAI = "openai"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .ollama: return "Ollama"
        case .anthropic: return "Anthropic 协议"
        case .openAI: return "OpenAI 协议"
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
    /// The selected entry in `ProviderCatalog` (a vendor, a generic endpoint, or Ollama).
    public private(set) var activeProviderID: String {
        didSet { defaults.set(activeProviderID, forKey: "activeProviderID") }
    }
    /// The wire protocol of the active entry; change it with `selectProtocol`.
    public private(set) var providerType: LLMProviderType {
        didSet {
            defaults.set(providerType.rawValue, forKey: "providerType")
            defaults.set(providerType.rawValue, forKey: "vendor.\(activeProviderID).protocol")
        }
    }
    /// Base URL of the active entry for its current protocol.
    public var baseURL: String {
        didSet { defaults.set(baseURL, forKey: baseURLKey(activeProviderID, providerType)) }
    }
    public var model: String {
        didSet { defaults.set(model, forKey: "vendor.\(activeProviderID).model") }
    }
    /// The entry whose key was saved before per-provider keys existed; it keeps the old account.
    @ObservationIgnored private let legacyKeyProviderID: String

    public var systemPrompt: String {
        didSet { defaults.set(systemPrompt, forKey: "systemPrompt") }
    }

    public var thinkingEnabled: Bool {
        didSet { defaults.set(thinkingEnabled, forKey: "openAIThinkingEnabled") }
    }

    /// Off by default: each search is billed by the platform to the user's account.
    public var isWebSearchEnabled: Bool {
        didSet { defaults.set(isWebSearchEnabled, forKey: "isWebSearchEnabled") }
    }

    public var activeProvider: ProviderPreset {
        ProviderCatalog.preset(id: activeProviderID) ?? ProviderCatalog.preset(id: "custom")!
    }

    /// Switches entry while remembering each entry's own protocol, address and model.
    public func selectProvider(_ id: String) {
        guard id != activeProviderID, let preset = ProviderCatalog.preset(id: id) else { return }
        activeProviderID = id
        let saved = defaults.string(forKey: "vendor.\(id).protocol").flatMap(LLMProviderType.init(rawValue:))
        providerType = saved.flatMap { preset.protocols.contains($0) ? $0 : nil } ?? preset.defaultProtocol
        baseURL = storedBaseURL(id, providerType) ?? preset.defaultBaseURL(for: providerType)
        model = defaults.string(forKey: "vendor.\(id).model") ?? preset.defaultModel
    }

    /// For entries that speak both protocols (e.g. DeepSeek's Anthropic-compatible endpoint).
    public func selectProtocol(_ protocolType: LLMProviderType) {
        guard protocolType != providerType, activeProvider.protocols.contains(protocolType) else { return }
        providerType = protocolType
        baseURL = storedBaseURL(activeProviderID, protocolType) ?? activeProvider.defaultBaseURL(for: protocolType)
    }

    /// The default protocol keeps the pre-1.1 key, so existing per-platform addresses carry over.
    private func baseURLKey(_ id: String, _ protocolType: LLMProviderType) -> String {
        let preset = ProviderCatalog.preset(id: id)
        return protocolType == (preset?.defaultProtocol ?? .openAI)
            ? "vendor.\(id).baseURL" : "vendor.\(id).\(protocolType.rawValue).baseURL"
    }

    private func storedBaseURL(_ id: String, _ protocolType: LLMProviderType) -> String? {
        defaults.string(forKey: baseURLKey(id, protocolType))
    }

    /// Extensions follow the actual host, not the picker, so a generic entry for a known platform still works.
    public var requestOptions: OpenAIVendorOptions {
        guard providerType == .openAI else { return OpenAIVendorOptions() }
        return LLMVendor.infer(fromBaseURL: baseURL).requestOptions(
            model: model, thinkingEnabled: thinkingEnabled, webSearch: isWebSearchEnabled)
    }

    public var supportsThinkingControl: Bool { requestOptions.supportsThinkingToggle }

    public var thinkingOption: Bool? {
        let options = requestOptions
        if let flag = options.enableThinking { return flag }
        return options.thinkingType.map { $0 != "disabled" }
    }

    public var supportsWebSearch: Bool {
        providerType == .openAI && LLMVendor.infer(fromBaseURL: baseURL).supportsWebSearch
    }

    public var usesWebSearch: Bool { supportsWebSearch && isWebSearchEnabled }

    /// The chat endpoint for connection warm-up; local Ollama needs none.
    public var activeEndpointURL: URL? {
        guard providerType != .ollama else { return nil }
        return URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))
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
    /// Until this time, recognized text is written to the log to diagnose wake and
    /// recognition problems. Off by default and always time-limited.
    public var transcriptDiagnosticsUntil: Date? {
        didSet { defaults.set(transcriptDiagnosticsUntil, forKey: "transcriptDiagnosticsUntil") }
    }
    public var isTranscriptDiagnosticsActive: Bool { (transcriptDiagnosticsUntil ?? .distantPast) > Date() }

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
        
        // Pre-1.1 settings: one global protocol, OpenAI-compatible platform slots, and
        // separate Anthropic/Ollama fields. Copy them into per-entry slots once.
        let legacyBaseURL = defaults.string(forKey: "openAIBaseURL") ?? "https://api.openai.com/v1"
        let legacyVendor = defaults.string(forKey: "openAIVendor") ?? LLMVendor.infer(fromBaseURL: legacyBaseURL).rawValue
        if defaults.string(forKey: "openAIVendor") == nil, defaults.string(forKey: "openAIBaseURL") != nil {
            defaults.set(legacyBaseURL, forKey: "vendor.\(legacyVendor).baseURL")
            if let model = defaults.string(forKey: "openAIModel") { defaults.set(model, forKey: "vendor.\(legacyVendor).model") }
        }
        if defaults.string(forKey: "vendor.ollama.baseURL") == nil, let value = defaults.string(forKey: "ollamaBaseURL") {
            defaults.set(value, forKey: "vendor.ollama.baseURL")
        }
        if defaults.string(forKey: "vendor.ollama.model") == nil, let value = defaults.string(forKey: "ollamaModel") {
            defaults.set(value, forKey: "vendor.ollama.model")
        }
        if defaults.string(forKey: "vendor.anthropic.model") == nil, let value = defaults.string(forKey: "anthropicModel"),
           value != "claude-3-5-sonnet-latest" {
            defaults.set(value, forKey: "vendor.anthropic.model")
        }
        let activeID: String
        if let saved = defaults.string(forKey: "activeProviderID"), ProviderCatalog.preset(id: saved) != nil {
            activeID = saved
        } else {
            switch defaults.string(forKey: "providerType") {
            case "ollama": activeID = "ollama"
            case "anthropic": activeID = "anthropic"
            case "openai": activeID = ProviderCatalog.preset(id: legacyVendor) != nil ? legacyVendor : "custom"
            default: activeID = ProviderCatalog.defaultID
            }
            defaults.set(activeID, forKey: "activeProviderID")
        }
        if let saved = defaults.string(forKey: "legacyKeyVendor") {
            self.legacyKeyProviderID = saved
        } else {
            self.legacyKeyProviderID = legacyVendor
            defaults.set(legacyVendor, forKey: "legacyKeyVendor")
        }
        let preset = ProviderCatalog.preset(id: activeID)!
        let savedProtocol = defaults.string(forKey: "vendor.\(activeID).protocol").flatMap(LLMProviderType.init(rawValue:))
        let protocolType = savedProtocol.flatMap { preset.protocols.contains($0) ? $0 : nil } ?? preset.defaultProtocol
        let urlKey = protocolType == preset.defaultProtocol
            ? "vendor.\(activeID).baseURL" : "vendor.\(activeID).\(protocolType.rawValue).baseURL"
        self.activeProviderID = activeID
        self.providerType = protocolType
        self.baseURL = defaults.string(forKey: urlKey) ?? preset.defaultBaseURL(for: protocolType)
        self.model = defaults.string(forKey: "vendor.\(activeID).model") ?? preset.defaultModel
        self.systemPrompt = defaults.string(forKey: "systemPrompt") ?? "你是小喷，住在家里的智能桌面伙伴。说话简短、自然、温暖、幽默，回答通常在一两句话以内，不长篇大论。"
        self.thinkingEnabled = defaults.object(forKey: "openAIThinkingEnabled") as? Bool ?? false
        self.isWebSearchEnabled = defaults.object(forKey: "isWebSearchEnabled") as? Bool ?? false
        self.weatherCity = defaults.string(forKey: "weatherCity") ?? ""
        self.usesAutomaticLocation = defaults.object(forKey: "usesAutomaticLocation") as? Bool ?? true
        self.isFollowUpEnabled = defaults.object(forKey: "isFollowUpEnabled") as? Bool ?? true
        self.followUpSeconds = defaults.double(forKey: "followUpSeconds") == 0 ? 6 : defaults.double(forKey: "followUpSeconds")
        self.showsStandbyTranscript = defaults.object(forKey: "showsStandbyTranscript") as? Bool ?? false
        self.isGlobalHotKeyEnabled = defaults.object(forKey: "isGlobalHotKeyEnabled") as? Bool ?? true
        self.transcriptDiagnosticsUntil = defaults.object(forKey: "transcriptDiagnosticsUntil") as? Date
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
    /// Keychain account for an entry; every provider keeps its own key.
    public func apiKeyAccount(forProviderID id: String) -> String? {
        guard let preset = ProviderCatalog.preset(id: id), preset.group != .local else { return nil }
        if id == "anthropic" { return "anthropic_api_key" }
        return id == legacyKeyProviderID ? "openai_api_key" : "\(id)_api_key"
    }

    public var currentKeyAccount: String? { apiKeyAccount(forProviderID: activeProviderID) }

    func cachedOrStoredKey(account: String) -> String {
        if let cached = apiKeyCacheLock.withLock({ cachedAPIKeys[account] }) { return cached }
        return KeychainHelper.load(key: account) ?? ""
    }

    public func cacheAPIKey(_ value: String, account: String) {
        apiKeyCacheLock.withLock { cachedAPIKeys[account] = value }
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
