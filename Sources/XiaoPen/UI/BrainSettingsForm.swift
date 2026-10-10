import SwiftUI
import AppKit

/// Platform, model, key and connection test. Shared by Settings and onboarding;
/// `footer` adds extra sections to the same form.
@MainActor
struct BrainSettingsForm<Footer: View>: View {
    @Bindable private var prefs = AppPreferences.shared
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

    var body: some View {
        Form {
                    Section("模型平台") {
                        Picker("平台", selection: brainChoice) {
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

}

extension BrainSettingsForm where Footer == EmptyView {
    init() { self.init { EmptyView() } }
}
