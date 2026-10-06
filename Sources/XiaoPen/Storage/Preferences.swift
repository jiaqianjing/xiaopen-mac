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

@Observable
public final class AppPreferences: @unchecked Sendable {
    public static let shared = AppPreferences()
    
    // MARK: - LLM Settings
    public var providerType: LLMProviderType {
        didSet { UserDefaults.standard.set(providerType.rawValue, forKey: "providerType") }
    }
    
    public var systemPrompt: String {
        didSet { UserDefaults.standard.set(systemPrompt, forKey: "systemPrompt") }
    }
    
    // Ollama
    public var ollamaBaseURL: String {
        didSet { UserDefaults.standard.set(ollamaBaseURL, forKey: "ollamaBaseURL") }
    }
    public var ollamaModel: String {
        didSet { UserDefaults.standard.set(ollamaModel, forKey: "ollamaModel") }
    }
    
    // Anthropic
    public var anthropicModel: String {
        didSet { UserDefaults.standard.set(anthropicModel, forKey: "anthropicModel") }
    }
    
    // OpenAI Compatible
    public var openAIBaseURL: String {
        didSet { UserDefaults.standard.set(openAIBaseURL, forKey: "openAIBaseURL") }
    }
    public var openAIModel: String {
        didSet { UserDefaults.standard.set(openAIModel, forKey: "openAIModel") }
    }
    
    // MARK: - Wake Word & Voice Settings
    public var wakeWord: String {
        didSet { UserDefaults.standard.set(wakeWord, forKey: "wakeWord") }
    }
    public var isWakeWordEnabled: Bool {
        didSet { UserDefaults.standard.set(isWakeWordEnabled, forKey: "isWakeWordEnabled") }
    }
    public var ttsVoiceRate: Float {
        didSet { UserDefaults.standard.set(ttsVoiceRate, forKey: "ttsVoiceRate") }
    }
    public var autoDismissSeconds: Double {
        didSet { UserDefaults.standard.set(autoDismissSeconds, forKey: "autoDismissSeconds") }
    }
    
    private init() {
        let defaults = UserDefaults.standard
        
        self.providerType = LLMProviderType(rawValue: defaults.string(forKey: "providerType") ?? "") ?? .ollama
        self.systemPrompt = defaults.string(forKey: "systemPrompt") ?? "你是小喷，住在家里的智能桌面伙伴。说话简短、自然、温暖、幽默，回答通常在一两句话以内，不长篇大论。"
        
        self.ollamaBaseURL = defaults.string(forKey: "ollamaBaseURL") ?? "http://127.0.0.1:11434"
        self.ollamaModel = defaults.string(forKey: "ollamaModel") ?? "qwen2.5:latest"
        
        self.anthropicModel = defaults.string(forKey: "anthropicModel") ?? "claude-3-5-sonnet-latest"
        
        self.openAIBaseURL = defaults.string(forKey: "openAIBaseURL") ?? "https://api.openai.com/v1"
        self.openAIModel = defaults.string(forKey: "openAIModel") ?? "gpt-4o-mini"
        
        self.wakeWord = defaults.string(forKey: "wakeWord") ?? "小喷小喷"
        self.isWakeWordEnabled = defaults.object(forKey: "isWakeWordEnabled") as? Bool ?? true
        self.ttsVoiceRate = defaults.float(forKey: "ttsVoiceRate") == 0 ? 0.52 : defaults.float(forKey: "ttsVoiceRate")
        self.autoDismissSeconds = defaults.double(forKey: "autoDismissSeconds") == 0 ? 4.0 : defaults.double(forKey: "autoDismissSeconds")
    }
    
    // MARK: - Keychain Accessors
    public var anthropicAPIKey: String {
        get { KeychainHelper.load(key: "anthropic_api_key") ?? "" }
        set { KeychainHelper.save(key: "anthropic_api_key", data: newValue) }
    }
    
    public var openAIAPIKey: String {
        get { KeychainHelper.load(key: "openai_api_key") ?? "" }
        set { KeychainHelper.save(key: "openai_api_key", data: newValue) }
    }
}
