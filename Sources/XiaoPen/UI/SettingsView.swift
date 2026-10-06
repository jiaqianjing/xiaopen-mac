import SwiftUI

public struct SettingsView: View {
    @Bindable var prefs = AppPreferences.shared
    @State private var anthropicKeyInput: String = ""
    @State private var openAIKeyInput: String = ""
    @State private var isTestingConnection = false
    @State private var testResult: String?
    
    public init() {
        _anthropicKeyInput = State(initialValue: AppPreferences.shared.anthropicAPIKey)
        _openAIKeyInput = State(initialValue: AppPreferences.shared.openAIAPIKey)
    }
    
    public var body: some View {
        TabView {
            // MARK: - 模型与大脑设置
            Form {
                Section(header: Text("模型提供商")) {
                    Picker("当前大脑", selection: $prefs.providerType) {
                        ForEach(LLMProviderType.allCases) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                
                switch prefs.providerType {
                case .ollama:
                    Section(header: Text("Ollama 本地配置")) {
                        TextField("Base URL", text: $prefs.ollamaBaseURL)
                        TextField("模型名称 (如 qwen2.5, deepseek-r1:8b)", text: $prefs.ollamaModel)
                    }
                case .anthropic:
                    Section(header: Text("Anthropic Claude 配置")) {
                        TextField("模型名称", text: $prefs.anthropicModel)
                        SecureField("Claude API Key", text: $anthropicKeyInput)
                            .onChange(of: anthropicKeyInput) { _, newValue in
                                prefs.anthropicAPIKey = newValue
                            }
                    }
                case .openAI:
                    Section(header: Text("OpenAI 兼容接口配置 (DeepSeek/SiliconFlow/OpenAI)")) {
                        TextField("Base URL", text: $prefs.openAIBaseURL)
                        TextField("模型名称", text: $prefs.openAIModel)
                        SecureField("API Key", text: $openAIKeyInput)
                            .onChange(of: openAIKeyInput) { _, newValue in
                                prefs.openAIAPIKey = newValue
                            }
                    }
                }
                
                Section {
                    Button(action: testConnection) {
                        if isTestingConnection {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("测试模型连通性")
                        }
                    }
                    if let result = testResult {
                        Text(result)
                            .font(.footnote)
                            .foregroundColor(result.contains("成功") ? .green : .red)
                    }
                }
            }
            .padding()
            .tabItem {
                Label("大模型大脑", systemImage: "brain")
            }
            
            // MARK: - 语音与唤醒
            Form {
                Section(header: Text("离线免提唤醒")) {
                    Toggle("启用语音唤醒", isOn: $prefs.isWakeWordEnabled)
                    TextField("唤醒词 (默认: 小喷小喷)", text: $prefs.wakeWord)
                        .disabled(!prefs.isWakeWordEnabled)
                }
                
                Section(header: Text("语音合成 (TTS)")) {
                    Slider(value: $prefs.ttsVoiceRate, in: 0.3...0.8, step: 0.02) {
                        Text("语速: \(String(format: "%.2f", prefs.ttsVoiceRate))")
                    }
                }
                
                Section(header: Text("悬浮窗展示")) {
                    Slider(value: $prefs.autoDismissSeconds, in: 2.0...10.0, step: 0.5) {
                        Text("回答后保留秒数: \(String(format: "%.1f", prefs.autoDismissSeconds)) 秒")
                    }
                }
            }
            .padding()
            .tabItem {
                Label("语音与声学", systemImage: "waveform")
            }
            
            // MARK: - 角色与提示词
            Form {
                Section(header: Text("小喷的人设与系统提示词 (Prompt)")) {
                    TextEditor(text: $prefs.systemPrompt)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(minHeight: 140)
                        .padding(4)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                }
            }
            .padding()
            .tabItem {
                Label("角色人设", systemImage: "person.text.rectangle")
            }
        }
        .frame(width: 520, height: 380)
    }
    
    private func testConnection() {
        isTestingConnection = true
        testResult = nil
        
        Task {
            let provider: LLMProviderProtocol
            switch prefs.providerType {
            case .ollama:
                provider = OllamaProvider(baseURL: prefs.ollamaBaseURL, model: prefs.ollamaModel)
            case .anthropic:
                provider = AnthropicProvider(apiKey: prefs.anthropicAPIKey, model: prefs.anthropicModel)
            case .openAI:
                provider = OpenAIProvider(baseURL: prefs.openAIBaseURL, apiKey: prefs.openAIAPIKey, model: prefs.openAIModel)
            }
            
            do {
                let ok = try await provider.testConnection()
                testResult = ok ? "✅ 服务连通成功！" : "❌ 连接失败，请检查配置"
            } catch {
                testResult = "❌ 报错: \(error.localizedDescription)"
            }
            isTestingConnection = false
        }
    }
}
