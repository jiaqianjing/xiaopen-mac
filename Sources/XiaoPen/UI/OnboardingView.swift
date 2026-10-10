import SwiftUI
import AppKit
import AVFoundation
import Speech

/// First-run window. Permissions are requested here, one step at a time,
/// instead of as a burst of system dialogs at launch.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
                                  styleMask: [.titled, .closable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: OnboardingView { [weak self] in self?.close() })
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            // Closing early still leaves a working app; it can be reopened from Settings → 关于.
            AppPreferences.shared.hasCompletedOnboarding = true
            if !AppState.shared.hasPermissions { await AppState.shared.startEngine() }
            self.window = nil
        }
    }
}

private enum OnboardingStep: Int, CaseIterable {
    case welcome, permissions, brain, wake, done
}

struct OnboardingView: View {
    let finish: () -> Void
    @State private var step: OnboardingStep = .welcome
    @Bindable private var appState = AppState.shared
    @Bindable private var prefs = AppPreferences.shared
    private let location = LocationService.shared
    @State private var wakeCountAtStart = 0
    @State private var launchAtLogin = true

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: welcome
                case .permissions: permissions
                case .brain: brain
                case .wake: wake
                case .done: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .opacity))
            Divider()
            footer.padding(16)
        }
        .frame(width: 620, height: 560)
        .animation(.snappy, value: step)
    }

    // MARK: - Steps

    private var welcome: some View {
        VStack(spacing: 18) {
            Spacer()
            MascotView(state: .speaking, level: 0, size: 112)
            Text("嗨，我是小喷").font(.system(size: 30, weight: .bold, design: .rounded))
            VStack(spacing: 4) {
                Text("住在菜单栏里的语音伙伴")
                Text("叫我一声，聊天、查天气、定提醒、调音量")
            }
            .font(.title3).foregroundStyle(.secondary)
            HStack(spacing: 28) {
                feature("waveform", "语音识别在本机完成")
                feature("bolt.fill", "提醒和音量即时执行")
                feature("lock.fill", "密钥存在钥匙串")
            }
            .padding(.top, 8)
            Spacer()
        }
        .padding(32)
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepTitle("先打个招呼", "小喷需要听见你。语音识别全部在这台 Mac 上进行，不会上传录音。")
            VStack(spacing: 10) {
                permissionRow("mic.fill", "麦克风", "听见你说话", microphoneState)
                permissionRow("text.bubble.fill", "语音识别", "把语音转成文字（本机）", speechState)
                permissionRow("character.bubble.fill", "中文听写", "系统设置 → 键盘 → 听写 → 普通话", dictationState,
                              action: appState.speechBlockReason != nil ? ("打开听写设置", { appState.openDictationSettings() }) : nil)
                permissionRow("location.fill", "定位（可选）", "查天气时自动知道你在哪个城市", locationState,
                              action: location.isDenied ? ("打开定位权限", { location.openPrivacySettings() })
                                                        : (location.place == nil ? ("允许定位", { location.prepare() }) : nil))
            }
            HStack {
                Button {
                    Task { await appState.startEngine() }
                } label: {
                    Label(appState.hasPermissions ? "重新检测" : "授权麦克风和语音识别", systemImage: "checkmark.shield")
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.isPreparingAudio)
                if appState.isPreparingAudio { ProgressView().controlSize(.small) }
            }
            if let error = appState.errorMessage, !appState.hasPermissions || appState.speechBlockReason != nil {
                Text(error).font(.footnote).foregroundStyle(.orange)
            }
            Spacer()
        }
        .padding(32)
    }

    private var brain: some View {
        VStack(alignment: .leading, spacing: 8) {
            stepTitle("选一个大脑", "回答问题用的是云端大模型。选好平台、填入 API Key，点“测试”确认能连上。推荐选快速（flash）模型，回答更快。")
                .padding(.horizontal, 32).padding(.top, 32)
            BrainSettingsForm()
        }
    }

    private var wake: some View {
        VStack(spacing: 18) {
            stepTitle("叫我一声试试", nil).frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
            let heard = appState.voiceWakeCount > wakeCountAtStart
            ZStack {
                Circle().fill((heard ? Color.green : Color.accentColor).opacity(0.12)).frame(width: 150, height: 150)
                if heard {
                    Image(systemName: "checkmark").font(.system(size: 54, weight: .bold)).foregroundStyle(.green)
                } else {
                    MascotView(state: appState.state == .idle ? .listening : appState.state,
                               level: appState.audioLevel, size: 84)
                }
            }
            Text(heard ? "听到啦！" : "对着 Mac 说“\(prefs.wakeWord)”")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
            Text(heard ? "以后直接说唤醒词加问题就行，比如“\(prefs.wakeWord)，明天会下雨吗”。"
                       : "说完后右上角会出现对话卡片。如果没反应，可以靠近一点再试，或换一个唤醒词。")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            HStack {
                Text("唤醒词")
                TextField("唤醒词", text: $prefs.wakeWord).frame(width: 160).textFieldStyle(.roundedBorder)
            }
            .padding(.top, 6)
            Spacer()
        }
        .padding(32)
        .onAppear {
            wakeCountAtStart = appState.voiceWakeCount
            if !prefs.isWakeWordEnabled { prefs.isWakeWordEnabled = true }
            appState.refreshWakeSettings()
        }
        .task(id: prefs.wakeWord) {
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            appState.refreshWakeSettings()
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepTitle("准备好了", "这些都可以直接说：")
            VStack(alignment: .leading, spacing: 10) {
                example("cloud.sun.fill", "明天会下雨吗？")
                example("alarm.fill", "十分钟后提醒我关火")
                example("speaker.wave.2.fill", "音量调到 40%")
                example("bubble.left.and.bubble.right.fill", "回答完直接接着问，不用再叫我")
                example("command", "在任何应用里按 \(GlobalHotKey.displayName) 也能开始说话")
            }
            Toggle("登录时自动启动小喷", isOn: $launchAtLogin).padding(.top, 8)
            Spacer()
        }
        .padding(32)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(OnboardingStep.allCases, id: \.self) { item in
                    Capsule().fill(item == step ? Color.accentColor : Color.primary.opacity(0.15))
                        .frame(width: item == step ? 18 : 7, height: 7)
                }
            }
            Spacer()
            if step != .welcome {
                Button("上一步") { move(-1) }
            }
            switch step {
            case .welcome:
                Button("开始设置") { move(1) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            case .permissions:
                Button(appState.hasPermissions ? "下一步" : "稍后再说") { move(1) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            case .brain, .wake:
                Button(step == .wake && appState.voiceWakeCount <= wakeCountAtStart ? "跳过" : "下一步") { move(1) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            case .done:
                Button("开始使用") {
                    try? LaunchAtLogin.setEnabled(launchAtLogin)
                    prefs.hasCompletedOnboarding = true
                    finish()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func move(_ delta: Int) {
        step = OnboardingStep(rawValue: step.rawValue + delta) ?? step
    }

    // MARK: - Pieces

    private enum RowState { case ok, needed, optional }

    private var microphoneState: RowState {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? .ok : .needed
    }

    private var speechState: RowState {
        SFSpeechRecognizer.authorizationStatus() == .authorized ? .ok : .needed
    }

    private var dictationState: RowState {
        appState.hasPermissions && appState.speechBlockReason == nil ? .ok : .needed
    }

    private var locationState: RowState {
        location.place != nil ? .ok : .optional
    }

    private func permissionRow(_ symbol: String, _ title: String, _ detail: String, _ state: RowState,
                               action: (String, () -> Void)? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 16)).frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            if let action { Button(action.0, action: action.1).controlSize(.small) }
            switch state {
            case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .needed: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
            case .optional: Text("可选").font(.footnote).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    private func stepTitle(_ title: String, _ detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 24, weight: .bold, design: .rounded))
            if let detail { Text(detail).foregroundStyle(.secondary) }
        }
    }

    private func feature(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(Color.accentColor)
            Text(text).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(width: 130)
    }

    private func example(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).font(.system(size: 15))
        } icon: {
            Image(systemName: symbol).foregroundStyle(Color.accentColor).frame(width: 24)
        }
    }
}
