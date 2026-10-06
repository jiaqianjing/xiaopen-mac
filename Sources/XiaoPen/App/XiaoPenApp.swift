import SwiftUI
import AppKit

@main
struct XiaoPenApp: App {
    @State private var appState = AppState.shared
    
    init() {
        Task { @MainActor in
            _ = await SpeechRecognizer.requestAuthorization()
            AppState.shared.startEngine()
            FloatingPanelController.shared.setup()
        }
    }
    
    var body: some Scene {
        MenuBarExtra("小喷", systemImage: iconForState(appState.state)) {
            VStack(alignment: .leading, spacing: 6) {
                Text("小喷 Mac 智能音箱")
                    .font(.headline)
                
                Text("状态: \(appState.state.rawValue)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Divider()
                
                Button("唤醒小喷 (对讲模式)") {
                    appState.triggerWakeUp()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                
                Button(appState.isHUDVisible ? "隐藏悬浮窗口" : "显示悬浮窗口") {
                    appState.isHUDVisible.toggle()
                }
                
                Divider()
                
                Button("偏好设置...") {
                    openSettings()
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
    
    private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
