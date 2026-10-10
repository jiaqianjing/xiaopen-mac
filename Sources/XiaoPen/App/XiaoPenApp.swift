import SwiftUI
import AppKit

@main
struct XiaoPenApp: App {
    @State private var appState = AppState.shared
    @NSApplicationDelegateAdaptor(XiaoPenAppDelegate.self) private var appDelegate
    
    init() {
        Task { @MainActor in
            FloatingPanelController.shared.setup()
            GlobalHotKey.shared.action = { AppState.shared.toggleVoiceInteraction() }
            GlobalHotKey.shared.setEnabled(AppPreferences.shared.isGlobalHotKeyEnabled)
            await AppState.shared.startEngine()
        }
    }
    
    var body: some Scene {
        MenuBarExtra("小喷", systemImage: iconForState(appState.state)) {
            VStack(alignment: .leading, spacing: 6) {
                Text("小喷 Mac 智能音箱")
                    .font(.headline)
                
                Text("状态: \(appState.statusText)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Text(wakeWordStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(appState.deviceStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !appState.recognitionStatus.isEmpty {
                    Text(appState.recognitionStatus).font(.caption).foregroundStyle(.secondary)
                }

                if !ReminderStore.shared.reminders.isEmpty {
                    Text("待办提醒：\(ReminderStore.shared.reminders.count) 个 · 下一个 \(ReminderFormatter.spokenTime(ReminderStore.shared.reminders[0].fireDate, now: Date()))")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let error = appState.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }

                if appState.speechBlockReason != nil {
                    if appState.speechRecoveryAction != .retryRecognition {
                        Button("打开系统听写设置") { appState.openDictationSettings() }
                    }
                }
                Button("重新检测语音") { Task { await appState.startEngine() } }
                    .disabled(appState.isPreparingAudio)
                
                Divider()
                
                Button(AppPreferences.shared.isGlobalHotKeyEnabled
                       ? "唤醒小喷（全局 \(GlobalHotKey.displayName)）" : "唤醒小喷 (对讲模式)") {
                    appState.triggerWakeUp()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(appState.isPreparingAudio || appState.speechBlockReason != nil)

                if appState.state != .idle {
                    Button("打断当前会话") { appState.interrupt() }
                }
                
                Button(appState.isHUDVisible ? "隐藏悬浮窗口" : "显示悬浮窗口") {
                    appState.isHUDVisible.toggle()
                }

                Button("清空本次对话记录") { appState.clearConversation() }
                
                Divider()
                
                SettingsLink {
                    Text("偏好设置...")
                }
                .keyboardShortcut(",", modifiers: .command)
                
                Divider()
                
                Button("退出小喷") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
        
        Settings {
            SettingsView()
        }
    }
    
    private func iconForState(_ state: SpeakerState) -> String {
        switch state {
        case .idle: return "sparkles"
        case .listening: return "waveform.circle.fill"
        case .thinking: return "brain.head.profile"
        case .speaking: return "speaker.wave.2.bubble.left.fill"
        }
    }
    
    private var wakeWordStatus: String {
        let prefs = AppPreferences.shared
        guard prefs.isWakeWordEnabled else { return "语音唤醒已关闭 · 可手动唤醒" }
        guard WakeWordDetector.isValid(prefs.wakeWord) else { return "请在设置中填写有效唤醒词" }
        return "唤醒词：\(prefs.wakeWord)"
    }
}

@MainActor
final class XiaoPenAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppState.shared.isHUDVisible = true
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.shutdown()
    }
}
