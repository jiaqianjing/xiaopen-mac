import SwiftUI
import AppKit

@MainActor
public struct SettingsView: View {
    @Bindable private var prefs = AppPreferences.shared
    @Bindable private var appState = AppState.shared
    private let reminderStore = ReminderStore.shared
    private let location = LocationService.shared
    private let synthesizer = SpeechSynthesizer.shared
    @State private var isPreparingLocalVoice = false
    /// Keyed by keychain account: each platform has its own key.
    @State private var keyInputs: [String: String] = [:]
    @State private var editedKeys: Set<String> = []
    @State private var loadedKeys: Set<String> = []
    @State private var savedKeys: [String: String] = [:]
    @State private var keyReadError: String?
    @State private var isLoadingKey = false
    @State private var keyReadRequestID = UUID()
    @State private var keySaveError: String?
    @State private var isTestingConnection = false
    @State private var testResult: String?
    @State private var testSucceeded = false
    @State private var connectionTask: Task<Void, Never>?

    public init() {}

    private enum BrainChoice: Hashable {
        case vendor(LLMVendor), anthropic, ollama

        var title: String {
            switch self {
            case .vendor(let vendor): return vendor.displayName
            case .anthropic: return "Anthropic Claude"
            case .ollama: return "本地 Ollama"
            }
        }
    }

    private var brainChoices: [BrainChoice] { LLMVendor.allCases.map(BrainChoice.vendor) + [.anthropic, .ollama] }

    private var brainChoice: Binding<BrainChoice> {
        Binding(get: {
            switch prefs.providerType {
            case .openAI: return .vendor(prefs.openAIVendor)
            case .anthropic: return .anthropic
            case .ollama: return .ollama
            }
        }, set: { choice in
            switch choice {
            case .vendor(let vendor):
                prefs.selectVendor(vendor)
                prefs.providerType = .openAI
            case .anthropic: prefs.providerType = .anthropic
            case .ollama: prefs.providerType = .ollama
            }
        })
    }

    private var currentAccount: String? { prefs.apiKeyAccount(for: prefs.providerType) }

    public var body: some View {
        TabView {
            ScrollView {
                Form {
                    Section("模型平台") {
                        Picker("当前大脑", selection: brainChoice) {
                            ForEach(brainChoices, id: \.self) { choice in Text(choice.title).tag(choice) }
                        }
                        Text("各平台的地址、模型和密钥分别保存，切换后不会丢失。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    switch prefs.providerType {
                    case .ollama:
                        Section("Ollama 本地配置") {
                            TextField("Base URL", text: $prefs.ollamaBaseURL)
                            TextField("模型名称", text: $prefs.ollamaModel)
                            Text("填写本机已安装、支持文本对话的模型。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    case .anthropic:
                        Section("Anthropic Claude 配置") {
                            TextField("模型名称", text: $prefs.anthropicModel)
                            SecureField("Claude API Key", text: keyBinding())
                                .onSubmit { Task { await saveCurrentKey() } }
                            keyStorageNote
                        }
                    case .openAI:
                        Section("\(prefs.openAIVendor.displayName) 配置") {
                            TextField("Base URL", text: $prefs.openAIBaseURL)
                            HStack {
                                TextField("模型名称", text: $prefs.openAIModel)
                                Menu("常用") {
                                    ForEach(prefs.openAIVendor.suggestedModels, id: \.self) { model in
                                        Button(model) { prefs.openAIModel = model }
                                    }
                                }
                                .fixedSize()
                            }
                            SecureField("API Key", text: keyBinding())
                                .onSubmit { Task { await saveCurrentKey() } }
                            if let url = prefs.openAIVendor.consoleURL {
                                Link("在\(prefs.openAIVendor.displayName)控制台获取 API Key", destination: url)
                                    .font(.footnote)
                            }
                            Text("语音对话建议选 flash / highspeed 等快速模型。模型列表常有变化，以平台控制台为准。")
                                .font(.footnote).foregroundStyle(.secondary)
                            keyStorageNote
                        }
                    }
                    if prefs.providerType == .openAI, prefs.supportsThinkingControl {
                        Section("回复速度") {
                            Toggle("深度思考", isOn: $prefs.openAIThinkingEnabled)
                            Text("日常语音聊天建议关闭：思考会让第一句回答晚好几秒。复杂问题可临时开启。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        HStack {
                            Button("测试模型连通性", action: testConnection)
                                .disabled(isTestingConnection || isLoadingKey)
                            if isTestingConnection { ProgressView().controlSize(.small) }
                        }
                        Text("检查服务、鉴权和所选模型，不生成对话。")
                            .font(.footnote).foregroundStyle(.secondary)
                        if let result = testResult {
                            Text(result).font(.footnote)
                                .foregroundStyle(testSucceeded ? Color.green : Color.red)
                                .textSelection(.enabled)
                        }
                    }
                }
                .formStyle(.grouped)
            }
            .tabItem { Label("模型", systemImage: "brain") }

            ScrollView {
                Form {
                    Section("自定义语音唤醒") {
                        Toggle("启用语音唤醒", isOn: $prefs.isWakeWordEnabled)
                        TextField("唤醒词", text: $prefs.wakeWord, prompt: Text("例如：嘿搭子、你好伙伴"))
                            .disabled(!prefs.isWakeWordEnabled)
                        if prefs.isWakeWordEnabled && !WakeWordDetector.isValid(prefs.wakeWord) {
                            Label("请输入包含文字或数字的唤醒词。", systemImage: "exclamationmark.triangle")
                                .font(.footnote).foregroundStyle(.orange)
                        } else {
                            Text("自动保存并立即生效。建议使用 3–6 个中文音节，减少误触发。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Text("关闭后待命时停止麦克风采集，仍可从菜单手动唤醒。处理和朗读回复时也会暂停采音；打断回复请使用菜单按钮。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("设备与权限") {
                        Text(appState.deviceStatus).font(.footnote)
                        if !appState.recognitionStatus.isEmpty {
                            Text(appState.recognitionStatus).font(.footnote).foregroundStyle(.secondary)
                        }
                        Text("语音唤醒依赖系统中文听写服务。仅授予麦克风权限还不够；听写关闭或语言资源未准备好时，请在系统键盘设置里开启并重新检测。")
                            .font(.footnote).foregroundStyle(.secondary)
                        HStack {
                            Button("重新检测") { Task { await appState.startEngine() } }
                                .disabled(appState.isPreparingAudio)
                            Button("麦克风权限") { openPrivacy("Microphone") }
                            Button("语音识别权限") { openPrivacy("SpeechRecognition") }
                        }
                        Button("打开系统听写设置") { appState.openDictationSettings() }
                    }
                    voiceSection
                    Section("系统音量") {
                        Text("可以说或输入：音量调到40%、音量调大一点、音量调小10%、静音、取消静音、当前音量是多少。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text("调大/调小一点默认改变10个百分点。静音或音量为零时只显示文字确认。HDMI等输出不支持系统调节时会显示原因。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("查询当前音量") { appState.sendText("当前音量是多少") }
                    }
                    Section("悬浮窗") {
                        Slider(value: $prefs.autoDismissSeconds, in: 2...10, step: 0.5) {
                            Text("回复后保留：\(String(format: "%.1f", prefs.autoDismissSeconds)) 秒")
                        }
                    }
                }
                .formStyle(.grouped)
            }
            .tabItem { Label("语音与唤醒", systemImage: "waveform") }

            ScrollView {
                Form {
                    Section("天气") {
                        Toggle("自动定位当前城市", isOn: $prefs.usesAutomaticLocation)
                        if prefs.usesAutomaticLocation {
                            HStack {
                                Text(location.status).font(.footnote).foregroundStyle(.secondary)
                                Spacer()
                                if location.isDenied {
                                    Button("打开定位权限") { location.openPrivacySettings() }
                                } else {
                                    Button("重新定位") { location.refresh() }
                                }
                            }
                        }
                        TextField("固定城市", text: $prefs.weatherCity, prompt: Text(prefs.usesAutomaticLocation ? "留空则使用自动定位" : "例如：北京、杭州"))
                        Text("优先级：问题里提到的城市 → 固定城市 → 自动定位。Mac 主要通过附近的 Wi-Fi 定位，只精确到城市附近，坐标不保存。天气数据来自 Open-Meteo，无需密钥。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("提醒与计时") {
                        Text("可以说：十分钟后提醒我关火、明天早上八点叫我起床、下午三点半提醒我开会、定一个五分钟的计时器、我有哪些提醒、取消所有提醒。提醒响起后说“再过五分钟”可以稍后再提醒。")
                            .font(.footnote).foregroundStyle(.secondary)
                        if reminderStore.reminders.isEmpty {
                            Text("暂无待办提醒").font(.footnote).foregroundStyle(.secondary)
                        } else {
                            ForEach(reminderStore.reminders) { reminder in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(ReminderFormatter.announcementTitle(for: reminder))
                                        Text(ReminderFormatter.spokenTime(reminder.fireDate, now: Date()))
                                            .font(.footnote).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button(role: .destructive) { appState.removeReminder(reminder) } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("取消这个提醒")
                                }
                            }
                        }
                        Text("提醒保存在本机，应用重启后仍有效；应用未运行期间到点的提醒会在下次启动时补报。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("对话体验") {
                        Toggle("回答后继续倾听，不用再说唤醒词", isOn: $prefs.isFollowUpEnabled)
                        if prefs.isFollowUpEnabled {
                            Slider(value: $prefs.followUpSeconds, in: 3...12, step: 1) {
                                Text("继续倾听：\(Int(prefs.followUpSeconds)) 秒")
                            }
                        }
                        Toggle("全局快捷键 \(GlobalHotKey.displayName)（开始说话 / 发送 / 打断）", isOn: $prefs.isGlobalHotKeyEnabled)
                        Toggle("待命时在悬浮窗显示“刚刚听到”的文字", isOn: $prefs.showsStandbyTranscript)
                        Text("待命识别会转写身边的所有说话声，默认不显示。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            }
            .tabItem { Label("技能", systemImage: "sparkles") }

            Form {
                Section("小喷的人设与系统提示词") {
                    TextEditor(text: $prefs.systemPrompt)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(minHeight: 200)
                    Text("最近 6 轮完整对话保存在内存中，退出后清除；切换模型或提示词会开启新对话。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("清空本次对话记录") { appState.clearConversation() }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("角色", systemImage: "person.text.rectangle") }
        }
        .padding(12)
        .frame(width: 580, height: 560)
        .onChange(of: prefs.isWakeWordEnabled) { _, _ in appState.refreshWakeSettings() }
        .onChange(of: prefs.ttsEngine) { _, engine in
            if engine == .localQwen { Task { await synthesizer.prepareLocalModel() } }
        }
        .task(id: prefs.wakeWord) {
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            appState.refreshWakeSettings()
        }
        .onChange(of: prefs.isGlobalHotKeyEnabled) { _, enabled in GlobalHotKey.shared.setEnabled(enabled) }
        .onChange(of: prefs.usesAutomaticLocation) { _, enabled in if enabled { location.refresh() } }
        .task(id: currentKeyTaskID) { await saveCurrentKeyAfterPause() }
        .task(id: currentAccount) {
            if let account = currentAccount { await readSavedKey(account: account) }
        }
        .onChange(of: connectionConfiguration) { _, _ in
            connectionTask?.cancel()
            isTestingConnection = false
            testResult = nil
        }
        .onDisappear {
            connectionTask?.cancel()
            isTestingConnection = false
            let accounts = editedKeys
            Task { for account in accounts { _ = await saveKey(keyInputs[account] ?? "", account: account) } }
        }
    }

    private var voiceSection: some View {
        Section("回复语音") {
            Picker("朗读方式", selection: $prefs.ttsEngine) {
                ForEach(TTSEngineType.allCases) { engine in
                    Text(engine.displayName).tag(engine)
                }
            }
            if prefs.ttsEngine == .localQwen {
                Picker("声音", selection: $prefs.qwenVoice) {
                    ForEach(QwenVoice.allCases) { voice in
                        Text(voice.displayName).tag(voice)
                    }
                }
                TextField("说话风格", text: $prefs.qwenVoiceStyle, axis: .vertical)
                    .lineLimit(2...4)
                Text("模型约 3.1 GB，准备完成后在本机离线生成语音。首次加载需要稍等，后续会保持模型就绪。声音和风格自动保存。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text(synthesizer.localModelStatus)
                    .font(.footnote).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack {
                    Button("准备本机语音") {
                        isPreparingLocalVoice = true
                        Task {
                            defer { isPreparingLocalVoice = false }
                            await synthesizer.prepareLocalModel()
                        }
                    }
                    .disabled(isPreparingLocalVoice || appState.isVoicePreviewing)
                    if isPreparingLocalVoice { ProgressView().controlSize(.small) }
                }
            } else {
                Slider(value: $prefs.ttsVoiceRate, in: 0.3...0.8, step: 0.02) {
                    Text("语速：\(String(format: "%.2f", prefs.ttsVoiceRate))")
                }
                Text("使用 macOS 系统中文语音。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            HStack {
                Button("试听") { appState.previewVoice() }
                    .disabled(appState.isVoicePreviewing || isPreparingLocalVoice)
                if appState.isVoicePreviewing { ProgressView().controlSize(.small) }
            }
        }
    }

    private var keyStorageNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = keyReadError ?? keySaveError {
                Text(error).foregroundStyle(.red)
            } else {
                Text("密钥停止输入后自动保存到 macOS 钥匙串。")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("读取已有密钥") {
                    if let account = currentAccount {
                        Task { await readSavedKey(account: account, allowUserInteraction: true) }
                    }
                }
                .disabled(isLoadingKey || currentAccount.map(editedKeys.contains) ?? true)
                if isLoadingKey { ProgressView().controlSize(.small) }
            }
        }
        .font(.footnote)
    }

    private var connectionConfiguration: [String] {
        [prefs.providerType.rawValue, prefs.ollamaBaseURL, prefs.ollamaModel,
         prefs.anthropicModel, prefs.openAIVendor.rawValue, prefs.openAIBaseURL, prefs.openAIModel,
         currentAccount.flatMap { keyInputs[$0] } ?? "", String(prefs.openAIThinkingEnabled)]
    }

    private var currentKeyTaskID: String {
        guard let account = currentAccount else { return "" }
        return account + "\u{0}" + (keyInputs[account] ?? "")
    }

    private func saveCurrentKeyAfterPause() async {
        guard let account = currentAccount, editedKeys.contains(account) else { return }
        do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
        _ = await saveKey(keyInputs[account] ?? "", account: account)
    }

    private func saveCurrentKey() async {
        guard let account = currentAccount else { return }
        _ = await saveKey(keyInputs[account] ?? "", account: account)
    }

    @discardableResult
    private func saveKey(_ value: String, account: String) async -> Bool {
        guard editedKeys.contains(account) else { return loadedKeys.contains(account) }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if savedKeys[account] == trimmed {
            editedKeys.remove(account)
            return true
        }
        let preferences = prefs
        do {
            try await Task.detached { try preferences.saveAPIKey(trimmed, account: account) }.value
            guard value == (keyInputs[account] ?? "") else { return false }
            savedKeys[account] = trimmed
            loadedKeys.insert(account)
            editedKeys.remove(account)
            keySaveError = nil
            keyReadError = nil
            return true
        } catch {
            keySaveError = error.localizedDescription
            return false
        }
    }

    private func keyBinding() -> Binding<String> {
        Binding(get: { currentAccount.flatMap { keyInputs[$0] } ?? "" }, set: { value in
            guard let account = currentAccount else { return }
            keyInputs[account] = value
            editedKeys.insert(account)
            keyReadError = nil
        })
    }

    private func readSavedKey(account: String, allowUserInteraction: Bool = false) async {
        guard !editedKeys.contains(account),
              allowUserInteraction || !loadedKeys.contains(account) else { return }
        let requestID = UUID()
        keyReadRequestID = requestID
        isLoadingKey = true
        defer { if keyReadRequestID == requestID { isLoadingKey = false } }
        do {
            let value = try await KeychainHelper.readKeyAsync(
                key: account, allowUserInteraction: allowUserInteraction,
                timeout: allowUserInteraction ? 60 : 8
            ) ?? ""
            guard !Task.isCancelled, keyReadRequestID == requestID, currentAccount == account,
                  !editedKeys.contains(account) else { return }
            keyInputs[account] = value
            savedKeys[account] = value
            loadedKeys.insert(account)
            prefs.cacheAPIKey(value, account: account)
            keyReadError = nil
        } catch {
            guard !Task.isCancelled, keyReadRequestID == requestID, currentAccount == account else { return }
            keyReadError = "已有密钥暂时无法读取。可点击“读取已有密钥”完成系统授权，或重新填写密钥。"
        }
    }

    private func testConnection() {
        let configuration = connectionConfiguration
        let account = currentAccount
        let key = (account.flatMap { keyInputs[$0] } ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let provider: any LLMProviderProtocol
        switch prefs.providerType {
        case .ollama: provider = OllamaProvider(baseURL: prefs.ollamaBaseURL, model: prefs.ollamaModel)
        case .anthropic: provider = AnthropicProvider(apiKey: key, model: prefs.anthropicModel)
        case .openAI: provider = OpenAIProvider(baseURL: prefs.openAIBaseURL, apiKey: key, model: prefs.openAIModel,
                                                options: prefs.openAIRequestOptions)
        }
        isTestingConnection = true
        testResult = nil
        connectionTask = Task { @MainActor in
            if let account {
                guard await saveKey(keyInputs[account] ?? "", account: account), !Task.isCancelled,
                      configuration == connectionConfiguration else {
                    isTestingConnection = false
                    return
                }
            }
            do {
                let success = try await provider.testConnection()
                guard !Task.isCancelled, configuration == connectionConfiguration else { return }
                testSucceeded = success
                testResult = success ? "服务与所选模型检查通过。" : "连接失败，请检查配置。"
            } catch {
                guard !Task.isCancelled, configuration == connectionConfiguration else { return }
                testSucceeded = false
                testResult = error.localizedDescription
            }
            isTestingConnection = false
        }
    }

    private func openPrivacy(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
