import SwiftUI
import AppKit

@MainActor
public struct SettingsView: View {
    @Bindable private var prefs = AppPreferences.shared
    @Bindable private var appState = AppState.shared
    private let reminderStore = ReminderStore.shared
    private let location = LocationService.shared
    private let synthesizer = SpeechSynthesizer.shared
    private let installer = VoiceModelInstaller.shared
    private let updates = UpdateChecker.shared
    @State private var isPreparingLocalVoice = false
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchAtLoginError: String?
    @State private var isModelInstalled = LocalSpeechWorker.isModelInstalled
    @State private var cloudKeyMissing = false
    @State private var showsSponsor = false
    @State private var cloudTestResult: String?
    @State private var isTestingCloud = false

    public init() {}

    public var body: some View {
        TabView {
            general.tabItem { Label("通用", systemImage: "gearshape") }
            BrainSettingsForm { personaSection }
                .tabItem { Label("大脑", systemImage: "brain") }
            voice.tabItem { Label("声音", systemImage: "waveform") }
            skills.tabItem { Label("技能", systemImage: "sparkles") }
            about.tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 600, height: 580)
        .sheet(isPresented: $showsSponsor) { SponsorView() }
        .onChange(of: prefs.isWakeWordEnabled) { _, _ in appState.refreshWakeSettings() }
        .onChange(of: prefs.ttsEngine) { _, engine in
            if engine == .localQwen, LocalSpeechWorker.isModelInstalled { Task { await synthesizer.prepareLocalModel() } }
        }
        .task(id: prefs.wakeWord) {
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            appState.refreshWakeSettings()
        }
        .onChange(of: prefs.isGlobalHotKeyEnabled) { _, enabled in GlobalHotKey.shared.setEnabled(enabled) }
        .onChange(of: prefs.speechRecognitionMode) { _, _ in appState.refreshWakeSettings() }
        .task(id: prefs.speechRecognitionMode) {
            guard prefs.speechRecognitionMode == .cloud, let account = prefs.cloudASRKeyAccount else {
                cloudKeyMissing = false
                return
            }
            let key = (try? await prefs.readAPIKey(account: account)) ?? ""
            cloudKeyMissing = key.isEmpty
        }
        .onChange(of: prefs.usesAutomaticLocation) { _, enabled in if enabled { location.refresh() } }
        .onChange(of: installer.phase) { _, phase in
            if phase == .installed {
                isModelInstalled = true
                if prefs.ttsEngine == .localQwen { Task { await synthesizer.prepareLocalModel() } }
            }
        }
    }

    // MARK: - 通用

    private var general: some View {
        Form {
            Section {
                Toggle("登录时自动启动小喷", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            try LaunchAtLogin.setEnabled(enabled)
                            launchAtLoginError = nil
                        } catch {
                            launchAtLoginError = "设置失败：\(error.localizedDescription)"
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    }
                if let launchAtLoginError {
                    Text(launchAtLoginError).font(.footnote).foregroundStyle(.red)
                } else if LaunchAtLogin.needsApproval {
                    HStack {
                        Text("需要在系统设置的“登录项”中允许。").font(.footnote).foregroundStyle(.orange)
                        Button("打开登录项") { LaunchAtLogin.openSystemSettings() }
                    }
                }
                Toggle("全局快捷键 \(GlobalHotKey.displayName)", isOn: $prefs.isGlobalHotKeyEnabled)
                Text("在任何应用里按一下开始说话，说话时再按立即发送，回答时按下可以打断。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("唤醒") {
                Toggle("语音唤醒", isOn: $prefs.isWakeWordEnabled)
                TextField("唤醒词", text: $prefs.wakeWord, prompt: Text("例如：小喷小喷"))
                    .disabled(!prefs.isWakeWordEnabled)
                if prefs.isWakeWordEnabled && !WakeWordDetector.isValid(prefs.wakeWord) {
                    Label("请输入包含文字的唤醒词。", systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                } else {
                    Text("建议 4 个字左右、叠词效果最好。同音字也能唤醒（例如“小盆小盆”）。关闭后待命时不采音，仍可用快捷键或菜单开始说话。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Toggle("回声消除（推荐）", isOn: $prefs.isEchoCancellationEnabled)
                    .onChange(of: prefs.isEchoCancellationEnabled) { _, _ in appState.refreshWakeSettings() }
                Picker("回答时打断", selection: $prefs.bargeInMode) {
                    Text("直接说话就能打断").tag(BargeInMode.natural)
                    Text("说唤醒词才打断").tag(BargeInMode.wakeWord)
                    Text("不打断").tag(BargeInMode.off)
                }
                .disabled(!prefs.isEchoCancellationEnabled || !prefs.isWakeWordEnabled)
                Text("回声消除使用 macOS 的语音处理，从麦克风里去掉小喷自己的声音，并做降噪和自动增益，打断依赖它。“直接说话”会在听到人声时先压低音量并用云端识别确认，确认是你在说话才停下；需要云端识别。使用蓝牙耳机时会自动关闭。")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("回答后继续听，不用再叫我", isOn: $prefs.isFollowUpEnabled)
                if prefs.isFollowUpEnabled {
                    Slider(value: $prefs.followUpSeconds, in: 3...12, step: 1) {
                        Text("继续听 \(Int(prefs.followUpSeconds)) 秒")
                    }
                }
            }
            Section("识别你说的问题") {
                Picker("识别方式", selection: $prefs.speechRecognitionMode) {
                    Text("云端识别（千问，更准）").tag(SpeechRecognitionMode.cloud)
                    Text("本机识别（离线）").tag(SpeechRecognitionMode.local)
                }
                .pickerStyle(.radioGroup)
                if prefs.speechRecognitionMode == .cloud {
                    HStack {
                        TextField("识别模型", text: $prefs.cloudASRModel)
                        Menu("常用") {
                            ForEach(AppPreferences.cloudASRModels, id: \.self) { model in
                                Button(model) { prefs.cloudASRModel = model }
                            }
                        }
                        .fixedSize()
                    }
                    if cloudKeyMissing {
                        Label("需要先在“大脑”里选择千问 AI 平台并填写 API Key；没有密钥时会自动用本机识别。",
                              systemImage: "key")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    HStack {
                        Button("测试云端识别") { testCloudRecognition() }
                            .disabled(isTestingCloud)
                        if isTestingCloud { ProgressView().controlSize(.small) }
                        if let cloudTestResult {
                            Text(cloudTestResult).font(.footnote).textSelection(.enabled)
                        }
                    }
                    Text("唤醒词始终在本机识别。叫醒小喷后，从唤醒前约 2.5 秒开始的录音会实时发送到千问 AI 平台识别，直到你说完；按识别时长计费，以平台价格为准。网络或密钥有问题时自动改用本机识别。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("全部在这台 Mac 上识别，不上传录音；离麦克风较远或有噪音时准确率较低。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("对话浮窗") {
                Slider(value: $prefs.autoDismissSeconds, in: 2...10, step: 0.5) {
                    Text("回答后保留 \(String(format: "%.1f", prefs.autoDismissSeconds)) 秒")
                }
                Toggle("待命时显示“刚刚听到”的文字", isOn: $prefs.showsStandbyTranscript)
                Text("待命识别会转写身边所有的说话声，默认不显示。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("麦克风与语音识别") {
                LabeledContent("状态", value: appState.statusText)
                if !appState.recognitionStatus.isEmpty {
                    Text(appState.recognitionStatus).font(.footnote).foregroundStyle(.secondary)
                }
                Text("唤醒词由本机识别，需要在系统“键盘 → 听写”中开启普通话（中国大陆）。")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack {
                    Button("重新检测") { Task { await appState.startEngine() } }
                        .disabled(appState.isPreparingAudio)
                    Button("听写设置") { appState.openDictationSettings() }
                    Button("隐私权限") { openPrivacy("Microphone") }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var personaSection: some View {
        Section("人设") {
            TextEditor(text: $prefs.systemPrompt)
                .font(.system(size: 13))
                .frame(minHeight: 90)
            Text("决定小喷的性格和说话方式。最近 6 轮对话只保存在内存里，切换模型或修改人设会开启新对话。")
                .font(.footnote).foregroundStyle(.secondary)
            Button("清空对话记录") { appState.clearConversation() }
        }
    }

    // MARK: - 声音

    private var voice: some View {
        Form {
            Section("朗读声音") {
                Picker("声音", selection: $prefs.ttsEngine) {
                    Text("系统语音 · 无需下载").tag(TTSEngineType.system)
                    Text("自然语音 · Qwen3-TTS 本机生成").tag(TTSEngineType.localQwen)
                }
                .pickerStyle(.radioGroup)
                if prefs.ttsEngine == .system {
                    Slider(value: $prefs.ttsVoiceRate, in: 0.3...0.8, step: 0.02) {
                        Text("语速 \(String(format: "%.2f", prefs.ttsVoiceRate))")
                    }
                }
                HStack {
                    Button("试听") { appState.previewVoice() }
                        .disabled(appState.isVoicePreviewing || isPreparingLocalVoice
                                  || (prefs.ttsEngine == .localQwen && !isModelInstalled))
                    if appState.isVoicePreviewing { ProgressView().controlSize(.small) }
                }
            }
            if prefs.ttsEngine == .localQwen {
                Section("自然语音") {
                    if ProcessInfo.processInfo.physicalMemory < 16 * 1_073_741_824 {
                        Label("这台 Mac 内存少于 16 GB。自然语音运行时约占 3.7 GB 内存，可能让其他应用变慢，建议使用系统语音。",
                              systemImage: "memorychip")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    if isModelInstalled {
                        Picker("音色", selection: $prefs.qwenVoice) {
                            ForEach(QwenVoice.allCases) { voice in Text(voice.displayName).tag(voice) }
                        }
                        TextField("说话风格", text: $prefs.qwenVoiceStyle, axis: .vertical)
                            .lineLimit(2...4)
                        LabeledContent("状态") {
                            Text(synthesizer.localModelStatus).font(.footnote).textSelection(.enabled)
                        }
                        Button("重新加载模型") {
                            isPreparingLocalVoice = true
                            Task {
                                defer { isPreparingLocalVoice = false }
                                await synthesizer.prepareLocalModel()
                            }
                        }
                        .disabled(isPreparingLocalVoice || appState.isVoicePreviewing)
                    } else {
                        modelDownload
                    }
                    Text("模型在本机 GPU 上运行，不调用云端接口，也不需要额外密钥。首次加载约十几秒，之后保持就绪。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var modelDownload: some View {
        let gigabytes = String(format: "%.1f", Double(installer.totalBytes) / 1_000_000_000)
        switch installer.phase {
        case .downloading(let received, let total):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(received), total: Double(max(total, 1)))
                HStack {
                    Text("已下载 \(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button("暂停") { installer.cancel() }
                }
            }
        case .checking, .verifying:
            HStack {
                ProgressView().controlSize(.small)
                Text(installer.phase == .checking ? "正在检查已下载的文件…" : "正在校验文件…").font(.footnote)
            }
        case .failed(let message):
            Text(message).font(.footnote).foregroundStyle(.red)
            Button("重试下载") { installer.install() }
        case .idle, .installed:
            Text("需要先下载模型（约 \(gigabytes) GB）。下载可以随时暂停，下次会接着下；每个文件都会校验完整性。")
                .font(.footnote).foregroundStyle(.secondary)
            Button("下载自然语音模型") { installer.install() }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - 技能

    private var skills: some View {
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
                TextField("固定城市", text: $prefs.weatherCity,
                          prompt: Text(prefs.usesAutomaticLocation ? "留空则使用自动定位" : "例如：北京、杭州"))
                Text("问题里提到的城市优先，其次是固定城市，最后是自动定位。Mac 通过附近的 Wi-Fi 定位，只精确到城市附近。天气来自 Open-Meteo。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("提醒与计时") {
                if reminderStore.reminders.isEmpty {
                    Text("暂无待办提醒").foregroundStyle(.secondary)
                } else {
                    ForEach(reminderStore.reminders) { reminder in
                        HStack {
                            Image(systemName: reminder.isTimer ? "timer" : "alarm").foregroundStyle(.orange)
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
                Text("例如：十分钟后提醒我关火 · 明天早上八点叫我起床 · 定一个五分钟的计时器 · 我有哪些提醒 · 取消所有提醒。响起后说“再过五分钟”可以稍后再提醒。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("系统音量") {
                Text("例如：音量调到 40% · 音量调大一点 · 静音 · 取消静音 · 现在音量多少。在本机直接执行，不经过模型。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 关于

    private var about: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    MascotView(state: .idle, level: 0, size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("小喷").font(.title2.bold())
                        Text("版本 \(AppInfo.version)（\(AppInfo.build)）").foregroundStyle(.secondary)
                        Text("住在菜单栏里的语音伙伴").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                HStack {
                    Label("小喷是开源项目，欢迎支持作者。", systemImage: "heart.fill").foregroundStyle(.pink)
                    Spacer()
                    Button("支持小喷") { showsSponsor = true }
                }
            }
            Section("更新") {
                HStack {
                    Button("检查更新") { Task { await updates.check() } }
                    if let result = updates.lastResult {
                        Text(result).font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let release = updates.available {
                        Link("下载 \(release.version)", destination: release.url)
                    }
                }
            }
            Section("帮助与反馈") {
                Button("重新打开使用引导") { OnboardingWindowController.shared.show() }
                Button("导出诊断信息…") { DiagnosticsExporter.exportWithSavePanel() }
                if prefs.isTranscriptDiagnosticsActive, let until = prefs.transcriptDiagnosticsUntil {
                    HStack {
                        Text("正在记录识别文字，\(until.formatted(date: .omitted, time: .shortened)) 自动停止")
                            .font(.footnote).foregroundStyle(.orange)
                        Button("立即停止") { prefs.transcriptDiagnosticsUntil = nil }
                    }
                } else {
                    Button("记录识别文字 30 分钟（排查唤醒和识别问题）") {
                        prefs.transcriptDiagnosticsUntil = Date().addingTimeInterval(30 * 60)
                    }
                }
                Text("诊断信息包含本次运行的日志和配置概要，不含密钥；只有开启“记录识别文字”的 30 分钟内，日志才会包含识别出的文字。")
                    .font(.footnote).foregroundStyle(.secondary)
                Link("反馈问题", destination: AppInfo.issuesURL)
                Link("隐私说明", destination: AppInfo.privacyURL)
                Link("项目主页", destination: AppInfo.homepage)
            }
        }
        .formStyle(.grouped)
    }

    private func testCloudRecognition() {
        guard let account = prefs.cloudASRKeyAccount else { return }
        isTestingCloud = true
        cloudTestResult = nil
        Task {
            defer { isTestingCloud = false }
            let key = (try? await prefs.readAPIKey(account: account)) ?? ""
            guard !key.isEmpty else {
                cloudTestResult = "没有千问 AI 平台的 API Key"
                return
            }
            switch await CloudSpeechSelfTest.run(apiKey: key, model: prefs.cloudASRModel) {
            case .success(let text):
                cloudTestResult = text.isEmpty ? "连接成功，但没有识别出文字" : "说“\(CloudSpeechSelfTest.phrase)”，识别为“\(text)”"
            case .failure(let error):
                cloudTestResult = error.localizedDescription
            }
        }
    }

    private func openPrivacy(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
