import SwiftUI

@MainActor
public struct FloatingHUDView: View {
    @Bindable private var appState = AppState.shared
    @Bindable private var prefs = AppPreferences.shared
    private let reminders = ReminderStore.shared
    @State private var textInput = ""

    public init() {}

    public var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image("Mascot", bundle: .module)
                    .resizable().scaledToFit()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .scaleEffect(1 + CGFloat(appState.audioLevel) * 0.08)
                    .animation(.easeInOut(duration: 0.15), value: appState.audioLevel)
                    .accessibilityLabel("小抱枕")
                VStack(alignment: .leading, spacing: 3) {
                    Text("小喷").font(.system(size: 14, weight: .semibold, design: .rounded))
                    HStack(spacing: 6) {
                        if appState.state == .thinking { ProgressView().controlSize(.mini) }
                        Text(appState.statusText).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Text("\(providerName) · \(selectedModel)")
                            .lineLimit(1).truncationMode(.middle)
                        if !reminders.reminders.isEmpty {
                            Label("\(reminders.reminders.count)", systemImage: "alarm")
                                .help("待办提醒：\(reminders.reminders.count) 个")
                        }
                    }
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Spacer()
                Button { appState.dismissHUD() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("隐藏并结束当前会话")
            }

            WaveformVisualizer(level: appState.audioLevel,
                               isSpeaking: appState.state == .speaking)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let error = appState.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12)).foregroundStyle(.orange)
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if appState.speechBlockReason != nil {
                        HStack {
                            if appState.speechRecoveryAction != .retryRecognition {
                                Button("系统听写设置") { appState.openDictationSettings() }
                            }
                            Button("重新检测") { Task { await appState.startEngine() } }
                                .disabled(appState.isPreparingAudio)
                        }
                    }
                    if appState.state == .idle {
                        Text(prefs.isWakeWordEnabled ? "说“\(prefs.wakeWord)”唤醒，或点下方“直接说话”。" : "语音唤醒已关闭，可点下方“直接说话”。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        if prefs.showsStandbyTranscript, !appState.standbyTranscript.isEmpty {
                            textCard(title: "刚刚听到", text: appState.standbyTranscript)
                        }
                    }
                    if (appState.state == .idle || appState.state == .listening), !appState.recognitionStatus.isEmpty {
                        Text(appState.recognitionStatus)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if !appState.currentTranscript.isEmpty {
                        textCard(title: "你说", text: appState.currentTranscript)
                    }
                    if let reminder = appState.activeReminder {
                        reminderCard(reminder)
                    } else if !appState.currentResponse.isEmpty {
                        textCard(title: appState.isSystemResponse ? "本机操作" : "小喷说", text: appState.currentResponse)
                    }
                    if appState.currentTranscript.isEmpty && appState.errorMessage == nil {
                        Text(appState.state == .listening ? listeningHint : appState.deviceStatus)
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)

            HStack(spacing: 8) {
                TextField("也可以打字聊…", text: $textInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(sendText)
                Button(action: sendText) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
                }
                .buttonStyle(.plain)
                .disabled(textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("发送文字消息")
            }

            HStack {
                SettingsLink { Text("设置") }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                if appState.state == .idle {
                    Button("直接说话") { appState.triggerWakeUp() }
                        .help(prefs.isGlobalHotKeyEnabled ? "任意应用中按 \(GlobalHotKey.displayName)" : "直接开始说话")
                        .disabled(appState.isPreparingAudio || appState.speechBlockReason != nil)
                    Button("重新检测") { Task { await appState.startEngine() } }
                        .disabled(appState.isPreparingAudio)
                } else if appState.state == .listening {
                    Button("说完了，发送") { appState.stopListeningAndProcess() }
                        .disabled(appState.currentTranscript.isEmpty || appState.isFinalizingSpeech)
                } else if appState.state == .thinking || appState.state == .speaking {
                    Button("打断") { appState.interrupt() }
                }
            }
        }
        .padding(18)
        .frame(width: 380, height: 420)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private func sendText() {
        appState.sendText(textInput)
        textInput = ""
    }

    private var providerName: String {
        prefs.providerType == .openAI ? prefs.openAIVendor.displayName : prefs.providerType.displayName
    }

    private var listeningHint: String {
        if appState.isFollowUpListening { return "还可以接着问，不用再说唤醒词。" }
        return prefs.isGlobalHotKeyEnabled ? "我在听，慢慢说。说完再按 \(GlobalHotKey.displayName) 可立即发送。" : "我在听，慢慢说。"
    }

    private func reminderCard(_ reminder: Reminder) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(reminder.isTimer ? "计时结束" : "提醒", systemImage: "alarm.fill")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange)
            Text(ReminderFormatter.announcementTitle(for: reminder))
                .font(.system(size: 16, weight: .medium, design: .rounded))
            HStack {
                Button("知道了") { appState.dismissHUD() }
                    .keyboardShortcut(.defaultAction)
                Button("5 分钟后再提醒") { appState.snoozeActiveReminder(minutes: 5) }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    private var selectedModel: String {
        switch prefs.providerType {
        case .ollama: return prefs.ollamaModel
        case .anthropic: return prefs.anthropicModel
        case .openAI: return prefs.openAIModel
        }
    }

    private func textCard(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 14, design: .rounded)).textSelection(.enabled)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
}
