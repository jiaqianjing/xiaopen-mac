import SwiftUI
import AppKit

@main
struct XiaoPenApp: App {
    @State private var appState = AppState.shared
    @State private var reminders = ReminderStore.shared
    @State private var updates = UpdateChecker.shared
    @NSApplicationDelegateAdaptor(XiaoPenAppDelegate.self) private var appDelegate

    init() {
        Task { @MainActor in
            FloatingPanelController.shared.setup()
            GlobalHotKey.shared.action = { AppState.shared.toggleVoiceInteraction() }
            GlobalHotKey.shared.setEnabled(AppPreferences.shared.isGlobalHotKeyEnabled)
            UpdateChecker.shared.checkIfDue()
            if AppPreferences.shared.hasCompletedOnboarding {
                await AppState.shared.startEngine()
            } else {
                // Permissions are requested step by step inside the guide.
                OnboardingWindowController.shared.show()
            }
        }
    }

    var body: some Scene {
        MenuBarExtra("小喷", systemImage: iconForState(appState.state)) {
            Text(headerText)
            if appState.speechBlockReason != nil || appState.errorMessage != nil {
                Button("⚠︎ \(issueSummary)") { appState.isHUDVisible = true }
            }
            Divider()

            if appState.state == .idle {
                Button("开始说话") { appState.triggerWakeUp() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                    .disabled(appState.isPreparingAudio || appState.speechBlockReason != nil)
            } else {
                Button("停止") { appState.interrupt() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
            }
            Button(appState.isHUDVisible ? "收起对话浮窗" : "显示对话浮窗") {
                appState.isHUDVisible.toggle()
            }

            if !reminders.reminders.isEmpty {
                Divider()
                Menu("提醒（\(reminders.reminders.count)）") {
                    ForEach(reminders.reminders) { reminder in
                        Button("取消：\(ReminderFormatter.spokenTime(reminder.fireDate, now: Date())) · \(ReminderFormatter.announcementTitle(for: reminder))") {
                            appState.removeReminder(reminder)
                        }
                    }
                    Divider()
                    Button("全部取消") { _ = ReminderStore.shared.removeAll() }
                }
            }

            Divider()
            SettingsLink { Text("设置…") }
                .keyboardShortcut(",", modifiers: .command)
            if let release = updates.available {
                Button("下载新版本 \(release.version)…") { NSWorkspace.shared.open(release.url) }
            }
            Divider()
            Button("退出小喷") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }

        Settings {
            SettingsView()
        }
    }

    private var headerText: String {
        let prefs = AppPreferences.shared
        switch appState.state {
        case .idle:
            if !appState.hasPermissions { return "小喷 · 等待授权" }
            if prefs.isWakeWordEnabled, WakeWordDetector.isValid(prefs.wakeWord) {
                return "小喷 · 说“\(prefs.wakeWord)”或按 \(GlobalHotKey.displayName)"
            }
            return "小喷 · 按 \(GlobalHotKey.displayName) 开始说话"
        case .listening: return "小喷 · 正在听"
        case .thinking: return "小喷 · 正在想"
        case .speaking: return "小喷 · 正在说"
        }
    }

    private var issueSummary: String {
        let message = appState.speechBlockReason ?? appState.errorMessage ?? ""
        return message.count > 28 ? String(message.prefix(28)) + "…" : message
    }

    private func iconForState(_ state: SpeakerState) -> String {
        if appState.speechBlockReason != nil { return "exclamationmark.bubble" }
        switch state {
        case .idle: return "bubble.left.and.text.bubble.right"
        case .listening: return "waveform"
        case .thinking: return "ellipsis.bubble"
        case .speaking: return "speaker.wave.2.bubble.left"
        }
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
