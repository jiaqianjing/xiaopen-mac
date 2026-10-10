import SwiftUI

/// The conversation card. It grows with its content, shows one primary action for
/// the current state, and keeps diagnostics out of the way unless something needs fixing.
@MainActor
public struct FloatingHUDView: View {
    @Bindable private var appState = AppState.shared
    @Bindable private var prefs = AppPreferences.shared
    private let reminders = ReminderStore.shared
    @State private var textInput = ""
    @State private var showsKeyboard = false
    @FocusState private var inputFocused: Bool

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            content
            if let issue { IssueBanner(issue: issue) }
            if showsKeyboard { inputRow }
            footer
        }
        .padding(16)
        .frame(width: HUDMetrics.width, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .background(GeometryReader { proxy in
            Color.clear.preference(key: HUDHeightKey.self, value: proxy.size.height)
        })
        .onPreferenceChange(HUDHeightKey.self) { height in
            FloatingPanelController.shared.updateHeight(height)
        }
        .animation(.snappy(duration: 0.25), value: appState.state)
        .animation(.snappy(duration: 0.25), value: showsKeyboard)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            MascotView(state: appState.state, level: appState.audioLevel)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(appState.activeReminder == nil ? Color.primary : Color.orange)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                iconButton("keyboard", help: "打字聊天") {
                    showsKeyboard.toggle()
                    inputFocused = showsKeyboard
                }
                iconButton("xmark", help: "收起并结束当前对话") { appState.dismissHUD() }
            }
        }
    }

    private var title: String {
        if appState.activeReminder != nil { return appState.activeReminder?.isTimer == true ? "计时结束" : "提醒" }
        switch appState.state {
        case .idle: return "小喷"
        case .listening: return appState.isFollowUpListening ? "还在听" : "我在听"
        case .thinking: return "想一想…"
        case .speaking: return "小喷"
        }
    }

    private var subtitle: String {
        switch appState.state {
        case .listening:
            if appState.isFinalizingSpeech { return "正在整理你说的话…" }
            return appState.isFollowUpListening ? "可以直接接着问，不用再叫我" : "说完停顿一下就会发送"
        case .thinking:
            return appState.isSystemResponse ? "本机处理中" : "正在问\(providerName)"
        case .speaking:
            return prefs.isFollowUpEnabled ? "说完后可以直接接着问" : "点“停止”可以打断"
        case .idle:
            if issue != nil { return "需要处理一下" }
            if !reminders.reminders.isEmpty {
                return "下一个提醒：\(ReminderFormatter.spokenTime(reminders.reminders[0].fireDate, now: Date()))"
            }
            return wakeHint
        }
    }

    private var wakeHint: String {
        var parts: [String] = []
        if prefs.isWakeWordEnabled, WakeWordDetector.isValid(prefs.wakeWord) { parts.append("说“\(prefs.wakeWord)”叫我") }
        if prefs.isGlobalHotKeyEnabled { parts.append("或按 \(GlobalHotKey.displayName)") }
        return parts.isEmpty ? "点“开始说话”" : parts.joined(separator: " ")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let reminder = appState.activeReminder {
            Text(ReminderFormatter.announcementTitle(for: reminder))
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else if appState.state == .listening {
            VStack(alignment: .leading, spacing: 10) {
                Text(appState.currentTranscript.isEmpty ? "说吧，我在听…" : appState.currentTranscript)
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(appState.currentTranscript.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(.opacity)
                WaveformVisualizer(level: appState.audioLevel, isSpeaking: false)
                    .frame(height: 28)
            }
        } else if !appState.currentTranscript.isEmpty || !appState.currentResponse.isEmpty {
            exchange
        } else if appState.state == .idle, issue == nil {
            suggestions
        }
    }

    private var exchange: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !appState.currentTranscript.isEmpty {
                Text(appState.currentTranscript)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .multilineTextAlignment(.trailing)
            }
            if appState.currentResponse.isEmpty {
                if appState.state == .thinking { TypingIndicator() }
            } else {
                ScrollView {
                    Text(appState.currentResponse)
                        .font(.system(size: 15, design: .rounded))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
                .frame(maxHeight: 240)
                .fixedSize(horizontal: false, vertical: true)
                if appState.isSystemResponse {
                    Label("本机已执行", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("试试这样说").font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
            FlowLayout(spacing: 6) {
                ForEach(["明天会下雨吗", "十分钟后提醒我喝水", "音量调到 40%", "讲个冷笑话"], id: \.self) { example in
                    Button(example) { appState.sendText(example) }
                        .buttonStyle(ChipButtonStyle())
                }
            }
        }
    }

    // MARK: - Input and actions

    private var inputRow: some View {
        HStack(spacing: 8) {
            TextField("输入想说的话，回车发送", text: $textInput)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($inputFocused)
                .onSubmit(sendText)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.primary.opacity(0.06), in: Capsule())
            Button(action: sendText) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 24))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .disabled(textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            SettingsLink { Image(systemName: "gearshape") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("设置")
            if !reminders.reminders.isEmpty, appState.activeReminder == nil {
                Label("\(reminders.reminders.count)", systemImage: "alarm")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .help("待办提醒")
            }
            Spacer()
            actions
        }
        .controlSize(.regular)
    }

    @ViewBuilder
    private var actions: some View {
        if appState.activeReminder != nil {
            Button("5 分钟后") { appState.snoozeActiveReminder(minutes: 5) }
            Button("知道了") { appState.dismissHUD() }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        } else {
            switch appState.state {
            case .idle:
                Button {
                    appState.triggerWakeUp()
                } label: {
                    Label("开始说话", systemImage: "mic.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.isPreparingAudio || appState.speechBlockReason != nil)
            case .listening:
                Button("取消") { appState.interrupt() }
                Button("发送") { appState.stopListeningAndProcess() }
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.currentTranscript.isEmpty || appState.isFinalizingSpeech)
            case .thinking, .speaking:
                Button {
                    appState.interrupt()
                } label: {
                    Label("停止", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.06), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private func sendText() {
        appState.sendText(textInput)
        textInput = ""
    }

    private var providerName: String {
        prefs.providerType == .openAI ? prefs.openAIVendor.displayName : prefs.providerType.displayName
    }

    // MARK: - Issues

    private var issue: HUDIssue? {
        if let reason = appState.speechBlockReason {
            return HUDIssue(message: reason, kind: .speech(appState.speechRecoveryAction))
        }
        guard let message = appState.errorMessage else { return nil }
        if message.contains("API Key") || message.contains("请求失败") || message.contains("模型") {
            return HUDIssue(message: message, kind: .model)
        }
        if message.contains("麦克风") || message.contains("权限") { return HUDIssue(message: message, kind: .device) }
        return HUDIssue(message: message, kind: .other)
    }
}

enum HUDMetrics {
    static let width: CGFloat = 360
}

private struct HUDHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct HUDIssue {
    enum Kind { case speech(SpeechFailureAction?), model, device, other }
    let message: String
    let kind: Kind
}

private struct IssueBanner: View {
    let issue: HUDIssue
    private let appState = AppState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(issue.message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                switch issue.kind {
                case .speech(let action):
                    if action != .retryRecognition {
                        Button("打开听写设置") { appState.openDictationSettings() }
                    }
                    Button("重新检测") { Task { await appState.startEngine() } }
                case .model:
                    SettingsLink { Text("检查模型设置") }
                case .device:
                    Button("重新检测") { Task { await appState.startEngine() } }
                case .other:
                    EmptyView()
                }
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// The cushion mascot breathes while idle, follows the voice while listening,
/// and bobs while thinking or speaking.
struct MascotView: View {
    let state: SpeakerState
    let level: Float
    var size: CGFloat = 44

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: state == .idle && level == 0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Image("Mascot", bundle: .module)
                .resizable().scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
                .scaleEffect(scale(time))
                .offset(y: offset(time))
                .rotationEffect(.degrees(state == .thinking ? sin(time * 3) * 4 : 0))
                .shadow(color: glow.opacity(state == .idle ? 0 : 0.45), radius: 8)
        }
        .accessibilityLabel("小喷")
    }

    private var glow: Color {
        switch state {
        case .listening: return .blue
        case .thinking: return .purple
        case .speaking: return .teal
        case .idle: return .clear
        }
    }

    private func scale(_ time: TimeInterval) -> CGFloat {
        switch state {
        case .listening: return 1 + CGFloat(min(level, 1)) * 0.12
        case .idle: return 1
        default: return 1 + CGFloat(sin(time * 2)) * 0.02
        }
    }

    private func offset(_ time: TimeInterval) -> CGFloat {
        state == .speaking ? CGFloat(sin(time * 6)) * 1.5 : 0
    }
}

private struct TypingIndicator: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3) { index in
                    Circle()
                        .frame(width: 7, height: 7)
                        .opacity(0.3 + 0.7 * max(0, sin(time * 5 - Double(index) * 0.7)))
                }
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
        }
    }
}

struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07), in: Capsule())
            .foregroundStyle(.primary)
    }
}

/// Wraps chips onto as many lines as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (indices: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = ([index], size.width, size.height)
            } else {
                current = (current.indices + [index], needed, max(current.height, size.height))
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
