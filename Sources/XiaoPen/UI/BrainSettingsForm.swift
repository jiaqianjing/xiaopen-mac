import SwiftUI
import AppKit

/// Platform, model, key and connection test. Shared by Settings and onboarding;
/// `footer` adds extra sections to the same form.
@MainActor
struct BrainSettingsForm<Footer: View>: View {
    @Bindable private var prefs = AppPreferences.shared
    private let chatGPT = ChatGPTAuth.shared
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
    private let footer: Footer

    init(@ViewBuilder footer: () -> Footer) {
        self.footer = footer()
    }

    private var providerSelection: Binding<String> {
        Binding(get: { prefs.activeProviderID }, set: { prefs.selectProvider($0) })
    }

    private var protocolSelection: Binding<LLMProviderType> {
        Binding(get: { prefs.providerType }, set: { prefs.selectProtocol($0) })
    }

    private var currentAccount: String? { prefs.currentKeyAccount }

    var body: some View {
        Form {
            let preset = prefs.activeProvider
            Section {
                Picker("大脑", selection: providerSelection) {
                    ForEach(ProviderPreset.Group.allCases, id: \.self) { group in
                        Section(group.title) {
                            ForEach(ProviderCatalog.all.filter { $0.group == group }) { item in
                                Text(item.name).tag(item.id)
                            }
                        }
                    }
                }
                if let note = preset.note {
                    Text(note).font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                Text("每个入口的地址、模型和密钥分别保存，切换后不会丢失。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if prefs.providerType == .chatGPT {
                chatGPTSection
            } else {
            Section("\(preset.name) 配置") {
                if preset.protocols.count > 1 {
                    Picker("接口协议", selection: protocolSelection) {
                        ForEach(preset.protocols, id: \.self) { item in Text(item.displayName).tag(item) }
                    }
                    .pickerStyle(.segmented)
                }
                TextField(baseURLLabel, text: $prefs.baseURL,
                          prompt: Text(preset.defaultBaseURL(for: prefs.providerType).isEmpty
                                       ? "https://example.com/anthropic" : preset.defaultBaseURL(for: prefs.providerType)))
                HStack {
                    TextField("模型", text: $prefs.model)
                    if !preset.suggestedModels.isEmpty {
                        Menu("常用") {
                            ForEach(preset.suggestedModels, id: \.self) { model in
                                Button(model) { prefs.model = model }
                            }
                        }
                        .fixedSize()
                    }
                }
                if currentAccount != nil {
                    SecureField(preset.requiresKey ? "API Key" : "API Key（可选）", text: keyBinding())
                        .onSubmit { Task { await saveCurrentKey() } }
                    if let url = preset.consoleURL {
                        Link("在 \(preset.name) 控制台获取 API Key", destination: url).font(.footnote)
                    }
                    keyStorageNote
                }
                if preset.group == .vendor, prefs.providerType == .openAI {
                    Text("语音对话建议选 flash、highspeed 等快速模型。模型列表常有变化，以平台控制台为准。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            }
            if prefs.supportsWebSearch {
                Section("联网搜索") {
                    Toggle("允许联网搜索", isOn: $prefs.isWebSearchEnabled)
                    Text("问新闻、比赛、行情等最新信息时，由模型自行判断是否搜索。搜索时第一句回答会慢约半秒；平台按次收费（快速搜索约 3 元 / 千次，搜到的内容另按输入 token 计费），从你的账户扣除。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if prefs.supportsThinkingControl {
                Section("回复速度") {
                    Toggle("深度思考", isOn: $prefs.thinkingEnabled)
                    Text("日常语音聊天建议关闭：思考会让第一句回答晚好几秒。复杂问题可临时开启。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                HStack {
                    Button("测试连接", action: testConnection)
                        .disabled(isTestingConnection || isLoadingKey)
                    if isTestingConnection { ProgressView().controlSize(.small) }
                }
                Text(prefs.providerType == .anthropic && URL(string: prefs.baseURL)?.host != "api.anthropic.com"
                     ? "会发送一条极短的消息来检查地址、密钥和模型（消耗极少量 token）。"
                     : "检查服务、密钥和所选模型，不生成对话。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let result = testResult {
                    Text(result).font(.footnote)
                        .foregroundStyle(testSucceeded ? Color.green : Color.red)
                        .textSelection(.enabled)
                }
            }
            footer
        }
        .formStyle(.grouped)
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

    @ViewBuilder
    private var chatGPTSection: some View {
        Section("ChatGPT 账号") {
            switch chatGPT.status {
            case .signedIn(let email):
                LabeledContent("已登录", value: email ?? "ChatGPT 账号")
                HStack {
                    Picker("模型", selection: $prefs.model) {
                        if !chatGPT.models.contains(prefs.model) { Text(prefs.model.isEmpty ? "请选择" : prefs.model).tag(prefs.model) }
                        ForEach(chatGPT.models, id: \.self) { Text($0).tag($0) }
                    }
                    Button("刷新") { Task { await chatGPT.loadModels() } }
                }
                Button("退出登录") { chatGPT.signOut() }
            case .signingIn:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("请在浏览器中完成登录…")
                    Spacer()
                    Button("取消") { chatGPT.cancelSignIn() }
                }
            case .signedOut, .failed:
                if case .failed(let message) = chatGPT.status {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
                Button("用 ChatGPT 登录") { chatGPT.signIn() }
                    .buttonStyle(.borderedProminent)
            }
            Text("用浏览器登录 ChatGPT 并同意授权后，小喷的回答会消耗你的 ChatGPT 订阅额度，不需要 API Key；小喷看不到你的 ChatGPT 聊天记录。令牌保存在 macOS 钥匙串，可以随时退出登录或在 ChatGPT 设置中断开。语音识别仍使用千问。国内网络需要能访问 openai.com。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .task {
            await chatGPT.restore()
            if case .signedIn = chatGPT.status, chatGPT.models.isEmpty { await chatGPT.loadModels() }
        }
        .onChange(of: chatGPT.models) { _, models in
            // Pick a fast default once the account's models are known.
            if !models.contains(prefs.model), let first = models.first(where: { $0.contains("mini") }) ?? models.first {
                prefs.model = first
            }
        }
    }

    private var baseURLLabel: String {
        switch prefs.providerType {
        case .openAI: return "接口地址（OpenAI 兼容）"
        case .anthropic: return "接口地址（Anthropic 兼容）"
        case .ollama: return "Ollama 地址"
        case .chatGPT: return "接口地址"
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
        [prefs.activeProviderID, prefs.providerType.rawValue, prefs.baseURL, prefs.model,
         currentAccount.flatMap { keyInputs[$0] } ?? "", String(prefs.thinkingEnabled)]
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
        let provider = LLMProviderFactory.make(protocolType: prefs.providerType, baseURL: prefs.baseURL,
                                               model: prefs.model, apiKey: key, options: prefs.requestOptions,
                                               thinkingEnabled: prefs.thinkingEnabled)
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

}

extension BrainSettingsForm where Footer == EmptyView {
    init() { self.init { EmptyView() } }
}
