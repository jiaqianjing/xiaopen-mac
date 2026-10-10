import Foundation
import Observation
import AVFoundation
import AppKit
import OSLog

public enum SpeakerState: String, Sendable {
    case idle = "待命"
    case listening = "正在倾听..."
    case thinking = "正在思考..."
    case speaking = "正在回复..."
}

@Observable
@MainActor
public final class AppState {
    public static let shared = AppState()

    public private(set) var state: SpeakerState = .idle
    public private(set) var audioLevel: Float = 0
    public private(set) var currentTranscript = ""
    public private(set) var currentResponse = ""
    public private(set) var isSystemResponse = false
    public private(set) var errorMessage: String?
    public private(set) var deviceStatus = "正在检查权限..."
    public private(set) var recognitionStatus = ""
    public private(set) var standbyTranscript = ""
    public private(set) var speechBlockReason: String?
    public private(set) var speechRecoveryAction: SpeechFailureAction?
    public private(set) var isFinalizingSpeech = false
    public private(set) var isVoicePreviewing = false
    /// Listening right after a reply, without the wake word.
    public private(set) var isFollowUpListening = false
    /// The reminder being announced, so the HUD can offer snooze and dismiss.
    public private(set) var activeReminder: Reminder?
    /// Counts voice wake-ups; the first-run guide uses it to confirm the wake word works.
    public private(set) var voiceWakeCount = 0
    public var hasPermissions: Bool { permissionsGranted }
    public var statusText: String {
        if state == .listening, isFinalizingSpeech { return "正在整理语音..." }
        if state == .listening, isFollowUpListening, currentTranscript.isEmpty { return "还在听 · 可以接着说" }
        guard state == .idle else { return state.rawValue }
        if speechBlockReason != nil {
            if speechRecoveryAction == .retryRecognition { return "语音识别暂无响应" }
            if speechRecoveryAction == .localRecognitionUnavailable { return "本机语音识别不可用" }
            return "语音暂不可用 · 需要系统设置"
        }
        if !permissionsGranted { return "等待语音权限" }
        if !AppPreferences.shared.isWakeWordEnabled { return "手动模式" }
        if !AudioEngineManager.shared.isRunning { return "等待麦克风" }
        if errorMessage != nil { return "待命 · 请查看提示" }
        return "待命 · 等待唤醒词"
    }
    public private(set) var isPreparingAudio = false
    public var isHUDVisible = false {
        didSet { FloatingPanelController.shared.setVisible(isHUDVisible) }
    }

    private var silenceTimer: Timer?
    private var dismissTimer: Timer?
    private var currentTask: Task<Void, Never>?
    private var finalTranscriptTask: Task<Void, Never>?
    private var conversationID: UUID?
    private var activeRecognitionID: UUID?
    private var activeSpeechID: UUID?
    private var transcriptHandoff = VoiceTranscriptHandoff()
    private var voiceEndpoint = VoiceEndpointPolicy()
    private var permissionsGranted = false
    private var wantsAudioCapture = false
    private var history = ConversationHistory()
    private var historyConfiguration: [String] = []
    private var hasModelError = false
    private var replySubmittedAt: TimeInterval?
    private var allowsFollowUp = false
    private var reminderQueue: [Reminder] = []
    /// A reminder request that is still waiting for the user to say when.
    private var pendingReminder: (message: String, expiresAt: TimeInterval)?
    private var lastWeatherPrefetch: WeatherQuery?
    /// Restarts a standby request after a pause, so each utterance is recognized on its own.
    private var standbyRotationTask: Task<Void, Never>?
    private var recognitionStartedAt: TimeInterval?
    private var followUpRewoken = false
    @ObservationIgnored private let logger = Logger(subsystem: "com.jiaqianjing.XiaoPen", category: "lifecycle")

    private init() {
        setupAudioPipeline()
        ReminderStore.shared.onFire = { [weak self] reminder in self?.enqueueReminder(reminder) }
        if AppPreferences.shared.ttsEngine == .localQwen {
            Task { await SpeechSynthesizer.shared.prepareLocalModel() }
        }
    }

    private func setupAudioPipeline() {
        let audio = AudioEngineManager.shared
        let recognition = SpeechRecognizer.shared
        audio.onAudioBuffer = { buffer in recognition.appendAudioBuffer(buffer) }
        audio.onAudioLevel = { [weak self] level in
            Task { @MainActor [weak self] in
                guard let self, self.wantsAudioCapture, AudioEngineManager.shared.isRunning else { return }
                self.audioLevel = level
            }
        }
        audio.onStatusMessage = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self, self.wantsAudioCapture else { return }
                guard message == AudioEngineManager.shared.statusMessage else { return }
                self.deviceStatus = message
            }
        }
        audio.onCaptureError = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self, self.wantsAudioCapture, !AudioEngineManager.shared.isRunning,
                      message == AudioEngineManager.shared.statusMessage else { return }
                self.errorMessage = message
            }
        }
        audio.onCaptureAvailabilityChanged = { [weak self] available in
            Task { @MainActor [weak self] in
                guard let self, self.wantsAudioCapture,
                      available == AudioEngineManager.shared.isRunning else { return }
                if available {
                    if !self.hasModelError { self.errorMessage = nil }
                    self.startRecognitionForCurrentState()
                } else {
                    self.cancelInteraction()
                    if !AppPreferences.shared.isWakeWordEnabled {
                        self.pauseCapture()
                    }
                    self.errorMessage = "麦克风不可用，请连接麦克风后重试。"
                    self.deviceStatus = "等待麦克风连接"
                    self.isHUDVisible = true
                }
            }
        }
        recognition.onSessionStarted = { [weak self] identifier in
            Task { @MainActor [weak self] in
                guard let self, self.wantsAudioCapture,
                      SpeechRecognizer.shared.currentSessionID == identifier else { return }
                if self.state == .listening {
                    self.transcriptHandoff.recognitionStarted(identifier)
                }
                self.activeRecognitionID = identifier
                self.recognitionStartedAt = ProcessInfo.processInfo.systemUptime
            }
        }
        recognition.onStatusMessage = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self, self.wantsAudioCapture else { return }
                guard message == SpeechRecognizer.shared.statusMessage else { return }
                self.recognitionStatus = message
            }
        }
        recognition.onRecognitionError = { [weak self] message, identifier in
            Task { @MainActor [weak self] in
                guard let self, self.activeRecognitionID == identifier,
                      SpeechRecognizer.shared.currentSessionID == identifier else { return }
                if let failure = SpeechRecognizer.shared.blockedFailure, failure.isBlocking {
                    self.hasModelError = false
                    self.cancelInteraction()
                    self.pauseCapture()
                    self.speechBlockReason = message
                    self.speechRecoveryAction = failure.actionNeed
                    self.recognitionStatus = message
                    self.deviceStatus = "麦克风已暂停 · 语音唤醒不可用"
                    self.isHUDVisible = true
                }
                self.errorMessage = message
            }
        }
        recognition.onTranscriptUpdate = { [weak self] transcript, isFinal, identifier in
            Task { @MainActor [weak self] in
                guard let self, self.activeRecognitionID == identifier,
                      SpeechRecognizer.shared.currentSessionID == identifier else { return }
                if !self.hasModelError { self.errorMessage = nil }
                if self.state == .idle {
                    self.standbyTranscript = String(transcript.suffix(160))
                    let prefs = AppPreferences.shared
                    if prefs.isWakeWordEnabled {
                        self.triggerVoiceWakeUp(transcript: transcript, identifier: identifier)
                        if self.state == .idle {
                            self.scheduleStandbyRotation(identifier: identifier, transcriptLength: transcript.count)
                        }
                        if isFinal, self.state == .listening, !self.currentTranscript.isEmpty {
                            self.stopListeningAndProcess(finalResultAvailable: true)
                        }
                    }
                } else if self.state == .listening {
                    if var query = self.transcriptHandoff.update(transcript: transcript, sessionID: identifier, isFinal: isFinal) {
                        if self.isFollowUpListening, let stripped = self.strippingWakeWord(from: query) {
                            query = stripped
                            if stripped.isEmpty, !self.followUpRewoken {
                                // Only the wake phrase so far: treat it as a fresh wake-up.
                                self.followUpRewoken = true
                                NSSound(named: "Tink")?.play()
                                self.scheduleVoiceExpiry(self.voiceEndpoint.begin(now: ProcessInfo.processInfo.systemUptime))
                            }
                        }
                        self.currentTranscript = query
                        self.noteListeningProgress(query)
                        if !self.isFinalizingSpeech {
                            if isFinal, query.isEmpty {
                                self.scheduleVoiceExpiry(self.voiceEndpoint.begin(now: ProcessInfo.processInfo.systemUptime))
                            } else if let expiry = self.voiceEndpoint.update(transcript: query, now: ProcessInfo.processInfo.systemUptime,
                                                                             likelyComplete: self.looksLikeCompleteRequest(query)) {
                                self.scheduleVoiceExpiry(expiry)
                            }
                        }
                    }
                    if isFinal, self.isFinalizingSpeech || !self.currentTranscript.isEmpty {
                        self.stopListeningAndProcess(finalResultAvailable: true)
                    }
                }
            }
        }
        SpeechSynthesizer.shared.onSpeakingStarted = { [weak self] identifier in
            Task { @MainActor [weak self] in
                guard let self, self.activeSpeechID == identifier, self.conversationID != nil else { return }
                self.state = .speaking
                if let submittedAt = self.replySubmittedAt {
                    self.logger.notice("开始朗读：fromSubmitSeconds=\(ProcessInfo.processInfo.systemUptime - submittedAt)")
                }
            }
        }
        SpeechSynthesizer.shared.onSpeakingFinished = { [weak self] identifier in
            Task { @MainActor [weak self] in
                guard let self, self.activeSpeechID == identifier, self.conversationID != nil else { return }
                self.activeSpeechID = nil
                self.finishInteraction()
            }
        }
        SpeechSynthesizer.shared.onSpeechError = { [weak self] identifier, message in
            guard let self, self.activeSpeechID == identifier, self.conversationID != nil else { return }
            self.hasModelError = true
            self.errorMessage = "朗读失败：\(message) 回答仍可查看文字。"
            self.state = .thinking
        }
    }

    public func startEngine() async {
        guard !isPreparingAudio else { return }
        isPreparingAudio = true
        defer {
            isPreparingAudio = false
            // Started after the reset above so a reminder that is already due is not cancelled.
            ReminderStore.shared.start()
            _ = deliverReminderIfPossible()
        }
        cancelInteraction()
        pauseCapture()
        errorMessage = nil
        hasModelError = false
        speechBlockReason = nil
        speechRecoveryAction = nil
        standbyTranscript = ""
        deviceStatus = "正在检查麦克风和语音识别权限..."
        logger.notice("启动：检查麦克风和语音识别权限")
        let microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        logger.notice("麦克风权限：\(microphoneAllowed)")
        guard microphoneAllowed else {
            permissionsGranted = false
            showStartupError("麦克风权限未开启。请在系统设置 → 隐私与安全性 → 麦克风中允许小喷。")
            return
        }
        let speechAllowed = await SpeechRecognizer.requestAuthorization()
        logger.notice("语音识别权限：\(speechAllowed)")
        guard speechAllowed else {
            permissionsGranted = false
            showStartupError("语音识别权限未开启。请在系统设置 → 隐私与安全性 → 语音识别中允许小喷。")
            return
        }
        permissionsGranted = true
        refreshWakeSettings()
        // Ask for location after the voice permissions, so dialogs do not stack at launch.
        if AppPreferences.shared.usesAutomaticLocation, AppPreferences.shared.weatherCity.isEmpty {
            LocationService.shared.prepare()
        }
    }

    private func showStartupError(_ message: String) {
        hasModelError = false
        errorMessage = message
        logger.error("启动提示：\(message, privacy: .public)")
        deviceStatus = message
        isHUDVisible = true
    }

    public func refreshWakeSettings() {
        guard state == .idle else { return }
        let prefs = AppPreferences.shared
        guard permissionsGranted else { return }
        if speechBlockReason != nil {
            pauseCapture()
            deviceStatus = "麦克风已暂停 · 修复系统语音设置后请重新检测"
            return
        }
        guard prefs.isWakeWordEnabled, WakeWordDetector.isValid(prefs.wakeWord) else {
            pauseCapture()
            deviceStatus = "麦克风已暂停 · 可从菜单手动唤醒"
            recognitionStatus = ""
            return
        }
        pauseCapture()
        resumeCapture()
    }

    private func resumeCapture() {
        wantsAudioCapture = true
        do {
            try AudioEngineManager.shared.start()
            logger.notice("麦克风采集已启动")
            startRecognitionForCurrentState()
        } catch {
            logger.error("麦克风启动失败：\(error.localizedDescription, privacy: .public)")
            activeRecognitionID = nil
            SpeechRecognizer.shared.stopRecognition()
            errorMessage = error.localizedDescription
            deviceStatus = error.localizedDescription
            isHUDVisible = true
        }
    }

    private func startRecognitionForCurrentState() {
        guard wantsAudioCapture, AudioEngineManager.shared.isRunning,
              state == .idle || state == .listening else { return }
        if let identifier = activeRecognitionID, SpeechRecognizer.shared.currentSessionID == identifier { return }
        let word = state == .idle ? AppPreferences.shared.wakeWord : ""
        activeRecognitionID = SpeechRecognizer.shared.startRecognition(wakeWord: word)
    }

    private func pauseCapture() {
        standbyRotationTask?.cancel()
        standbyRotationTask = nil
        wantsAudioCapture = false
        activeRecognitionID = nil
        SpeechRecognizer.shared.stopRecognition()
        AudioEngineManager.shared.stop()
        audioLevel = 0
    }

    public func triggerWakeUp(initialQuery: String = "") {
        guard !isPreparingAudio else { return }
        cancelInteraction()
        pauseCapture()
        guard permissionsGranted else {
            showStartupError("请先在偏好设置中检查麦克风和语音识别权限，再点“重新检测”。")
            return
        }
        if let reason = speechBlockReason {
            errorMessage = reason
            deviceStatus = "语音暂不可用 · 修复系统设置后请重新检测"
            isHUDVisible = true
            return
        }
        errorMessage = nil
        hasModelError = false
        conversationID = UUID()
        state = .listening
        transcriptHandoff.beginManual(initialQuery: initialQuery)
        currentTranscript = initialQuery
        currentResponse = ""
        isHUDVisible = true
        resumeCapture()
        guard AudioEngineManager.shared.isRunning else {
            state = .idle
            conversationID = nil
            return
        }
        NSSound(named: "Tink")?.play()
        LLMConnectionWarmer.warm(AppPreferences.shared.activeEndpointURL)
        scheduleVoiceExpiry(voiceEndpoint.begin(now: ProcessInfo.processInfo.systemUptime, initialTranscript: initialQuery))
    }

    private func triggerVoiceWakeUp(transcript: String, identifier: UUID) {
        guard state == .idle, !isPreparingAudio, permissionsGranted,
              speechBlockReason == nil, activeRecognitionID == identifier,
              let query = transcriptHandoff.beginWake(transcript: transcript,
                  wakeWord: AppPreferences.shared.wakeWord, sessionID: identifier) else { return }
        // Keep the tap and cumulative recognition request: the rest of the same
        // spoken sentence may already be buffered but not yet transcribed.
        dismissTimer?.invalidate()
        dismissTimer = nil
        errorMessage = nil
        hasModelError = false
        conversationID = UUID()
        state = .listening
        currentTranscript = query
        currentResponse = ""
        isHUDVisible = true
        standbyRotationTask?.cancel()
        voiceWakeCount += 1
        let sessionSeconds = recognitionStartedAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? -1
        logger.notice("自定义唤醒词匹配成功 · 保留当前识别会话：sessionSeconds=\(sessionSeconds), transcriptLength=\(transcript.count)")
        NSSound(named: "Tink")?.play()
        LLMConnectionWarmer.warm(AppPreferences.shared.activeEndpointURL)
        noteListeningProgress(query)
        scheduleVoiceExpiry(voiceEndpoint.begin(now: ProcessInfo.processInfo.systemUptime, initialTranscript: query))
    }

    public func stopListeningAndProcess(finalResultAvailable: Bool = false) {
        guard state == .listening else { return }
        silenceTimer?.invalidate()
        silenceTimer = nil
        voiceEndpoint.cancel()
        if finalResultAvailable {
            processFinalTranscript()
            return
        }
        guard !isFinalizingSpeech else { return }
        isFinalizingSpeech = true
        // Stop new samples while retaining this request's final hypothesis briefly.
        // A local recognizer may revise its partial after endAudio/finish.
        wantsAudioCapture = false
        AudioEngineManager.shared.stop()
        audioLevel = 0
        SpeechRecognizer.shared.finishAudio()
        let identifier = conversationID
        finalTranscriptTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            guard let self, !Task.isCancelled, self.conversationID == identifier,
                  self.state == .listening, self.isFinalizingSpeech else { return }
            self.processFinalTranscript()
        }
    }

    private func processFinalTranscript() {
        finalTranscriptTask?.cancel()
        finalTranscriptTask = nil
        isFinalizingSpeech = false
        pauseCapture()
        let prompt = currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            finishInteraction(delay: 1)
            return
        }
        state = .thinking
        logger.notice("语音输入结束：characters=\(prompt.count)")
        deviceStatus = "回复期间麦克风已暂停"
        processPrompt(prompt, systemInput: transcriptHandoff.rawSystemCommandTranscript, isVoiceInput: true)
    }

    public func sendText(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        cancelInteraction()
        pauseCapture()
        errorMessage = nil
        hasModelError = false
        conversationID = UUID()
        currentTranscript = prompt
        currentResponse = ""
        state = .thinking
        deviceStatus = "回复期间麦克风已暂停"
        isHUDVisible = true
        processPrompt(prompt)
    }

    public func previewVoice() {
        cancelInteraction()
        pauseCapture()
        errorMessage = nil
        hasModelError = false
        conversationID = UUID()
        isVoicePreviewing = true
        isSystemResponse = false
        currentTranscript = "语音试听"
        currentResponse = "嗨，我是小喷。今天也别太紧绷，有事叫我，没事咱们就发会儿呆。"
        state = .thinking
        deviceStatus = "语音试听期间麦克风已暂停"
        isHUDVisible = true
        replySubmittedAt = ProcessInfo.processInfo.systemUptime
        activeSpeechID = SpeechSynthesizer.shared.speak(text: currentResponse, rate: AppPreferences.shared.ttsVoiceRate)
    }

    private func processPrompt(_ userText: String, systemInput: String? = nil, isVoiceInput: Bool = false) {
        guard let identifier = conversationID else { return }
        isSystemResponse = false
        activeReminder = nil
        allowsFollowUp = isVoiceInput
        let prefs = AppPreferences.shared
        let selectedProvider = prefs.providerType
        let requestOptions = prefs.openAIRequestOptions
        let keyAccount = prefs.apiKeyAccount(for: selectedProvider)
        let baseURL: String
        let model: String
        let configuration: [String]
        switch selectedProvider {
        case .ollama:
            baseURL = prefs.ollamaBaseURL
            model = prefs.ollamaModel
            configuration = [prefs.providerType.rawValue, prefs.ollamaBaseURL, prefs.ollamaModel, prefs.systemPrompt]
        case .anthropic:
            baseURL = ""
            model = prefs.anthropicModel
            configuration = [prefs.providerType.rawValue, prefs.anthropicModel, prefs.systemPrompt]
        case .openAI:
            baseURL = prefs.openAIBaseURL
            model = prefs.openAIModel
            configuration = [prefs.providerType.rawValue, prefs.openAIBaseURL, prefs.openAIModel, prefs.systemPrompt,
                             String(describing: requestOptions)]
        }
        if configuration != historyConfiguration {
            history.clear()
            historyConfiguration = configuration
        }
        replySubmittedAt = ProcessInfo.processInfo.systemUptime
        if processSystemVolumePrompt(userText, systemInput: systemInput) { return }
        if processReminderPrompt(userText) { return }
        let messages = history.messages(adding: userText)
        let systemPrompt = prefs.systemPrompt + AssistantContext.systemPromptSuffix
        let weatherQuery = WeatherIntentDetector.detect(userText)
        let manualCity = prefs.weatherCity.trimmingCharacters(in: .whitespacesAndNewlines)
        let usesLocation = manualCity.isEmpty && prefs.usesAutomaticLocation
        let voiceRate = prefs.ttsVoiceRate
        lastWeatherPrefetch = nil
        currentTask = Task { [weak self] in
            do {
                // Key read and weather lookup overlap; both are usually cached already.
                // Only weather waits for a fresh fix (bounded); other questions use the cached city.
                async let located: LocationService.Place? = usesLocation
                    ? (weatherQuery != nil ? LocationService.shared.currentPlace() : LocationService.shared.place) : nil
                let apiKey = if let keyAccount { try await prefs.readAPIKey(account: keyAccount) } else { "" }
                let place = await located
                let city = manualCity.isEmpty ? (place?.city ?? "") : manualCity
                let extra = await Self.weatherNote(for: weatherQuery, city: manualCity, located: place)
                try Task.checkCancellation()
                guard let self, self.conversationID == identifier else { return }
                var requestMessages = messages
                requestMessages[requestMessages.count - 1] = ChatMessage(
                    role: "user", content: AssistantContext.decorate(userText, now: Date(), city: city, extra: [extra])
                )
                let provider: any LLMProviderProtocol
                switch selectedProvider {
                case .ollama: provider = OllamaProvider(baseURL: baseURL, model: model)
                case .anthropic: provider = AnthropicProvider(apiKey: apiKey, model: model)
                case .openAI: provider = OpenAIProvider(baseURL: baseURL, apiKey: apiKey, model: model, options: requestOptions)
                }
                self.logger.notice("模型请求开始：provider=\(selectedProvider.rawValue, privacy: .public), model=\(model, privacy: .public)")
                let requestStartedAt = ProcessInfo.processInfo.systemUptime
                let stream = try await provider.streamChat(messages: requestMessages, systemPrompt: systemPrompt)
                try Task.checkCancellation()
                guard self.conversationID == identifier else { return }
                let speechID = SpeechSynthesizer.shared.beginStream(rate: voiceRate)
                self.activeSpeechID = speechID
                var response = ""
                for try await chunk in stream {
                    try Task.checkCancellation()
                    guard self.conversationID == identifier else { return }
                    if response.isEmpty, !chunk.isEmpty {
                        self.logger.notice("模型首字：elapsedSeconds=\(ProcessInfo.processInfo.systemUptime - requestStartedAt)")
                    }
                    response += chunk
                    self.currentResponse = response
                    SpeechSynthesizer.shared.enqueue(text: chunk, sessionID: speechID)
                }
                try Task.checkCancellation()
                guard self.conversationID == identifier else { return }
                self.currentTask = nil
                guard !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.hasModelError = true
                    self.errorMessage = "模型返回了空回复，请检查配置后重试。"
                    self.activeSpeechID = nil
                    SpeechSynthesizer.shared.stop()
                    self.finishInteraction()
                    return
                }
                self.history.record(user: userText, assistant: response)
                self.logger.notice("模型回复完成：characters=\(response.count), elapsedSeconds=\(ProcessInfo.processInfo.systemUptime - requestStartedAt)")
                SpeechSynthesizer.shared.finishStream(sessionID: speechID)
            } catch {
                guard let self, !Task.isCancelled, self.conversationID == identifier else { return }
                self.currentTask = nil
                self.activeSpeechID = nil
                SpeechSynthesizer.shared.stop()
                self.hasModelError = true
                self.errorMessage = "请求失败：\(error.localizedDescription)"
                self.finishInteraction()
            }
        }
    }

    private nonisolated static func weatherNote(for query: WeatherQuery?, city: String,
                                                located: LocationService.Place?) async -> String {
        guard let query else { return "" }
        return await WeatherService.shared.context(for: query, defaultCity: city, located: located)
    }

    // MARK: - Reminders

    private func processReminderPrompt(_ userText: String) -> Bool {
        let store = ReminderStore.shared
        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        let pending = pendingReminder.flatMap { uptime < $0.expiresAt ? $0.message : nil }
        let snoozeMessage = store.recentlyFiredMessage()
        let result = ReminderIntentParser.parse(userText, now: now, wakeWord: AppPreferences.shared.wakeWord,
                                                acceptsBareTime: pending != nil || snoozeMessage != nil)
        let reply: String
        switch result {
        case .noMatch:
            return false
        case .needsTime(let message):
            pendingReminder = (message, uptime + 90)
            reply = "好的，什么时候提醒你\(message)？比如十分钟后，或者明天早上八点。"
        case .command(.create(let fireDate, let message, let isTimer)):
            let finalMessage = message.isEmpty ? (pending ?? snoozeMessage ?? "") : message
            pendingReminder = nil
            let reminder = store.add(fireDate: fireDate, message: finalMessage, isTimer: isTimer)
            logger.notice("已创建提醒：inSeconds=\(fireDate.timeIntervalSince(now))")
            reply = ReminderFormatter.confirmation(for: reminder, now: now)
        case .command(.list):
            reply = ReminderFormatter.listing(store.reminders, now: now)
        case .command(.cancel(let all, let keyword)):
            if all {
                let count = store.removeAll()
                reply = count == 0 ? "现在没有提醒需要取消。" : "已取消全部\(count)个提醒。"
            } else if let target = store.cancellationTarget(keyword: keyword) {
                store.remove(target)
                reply = "已取消\(ReminderFormatter.spokenTime(target.fireDate, now: now))的提醒：\(ReminderFormatter.announcementTitle(for: target))。"
            } else if let keyword, !store.reminders.isEmpty {
                reply = "没有找到和“\(keyword)”有关的提醒。"
            } else {
                reply = "现在没有提醒需要取消。"
            }
        }
        respondLocally(reply, user: userText)
        return true
    }

    private func respondLocally(_ text: String, user: String) {
        isSystemResponse = true
        currentResponse = text
        history.record(user: user, assistant: text)
        activeSpeechID = SpeechSynthesizer.shared.speak(text: text, rate: AppPreferences.shared.ttsVoiceRate)
    }

    private func enqueueReminder(_ reminder: Reminder) {
        reminderQueue.append(reminder)
        _ = deliverReminderIfPossible()
    }

    /// Announces a due reminder unless the user is mid-conversation; it then waits for the turn to end.
    private func deliverReminderIfPossible() -> Bool {
        guard state == .idle, !isPreparingAudio, !isVoicePreviewing, !reminderQueue.isEmpty else { return false }
        let reminder = reminderQueue.removeFirst()
        dismissTimer?.invalidate()
        dismissTimer = nil
        pauseCapture()
        transcriptHandoff.reset()
        voiceEndpoint.cancel()
        conversationID = UUID()
        errorMessage = nil
        hasModelError = false
        activeReminder = reminder
        isSystemResponse = true
        currentTranscript = ""
        currentResponse = ReminderFormatter.announcement(for: reminder, now: Date())
        state = .thinking
        isHUDVisible = true
        // A follow-up lets the user say "再过五分钟" without the wake word.
        allowsFollowUp = permissionsGranted
        NSSound(named: "Glass")?.play()
        activeSpeechID = SpeechSynthesizer.shared.speak(text: currentResponse, rate: AppPreferences.shared.ttsVoiceRate)
        return true
    }

    public func snoozeActiveReminder(minutes: Int = 5) {
        guard let reminder = activeReminder else { return }
        let snoozed = ReminderStore.shared.add(fireDate: Date().addingTimeInterval(TimeInterval(minutes * 60)),
                                               message: reminder.message, isTimer: reminder.isTimer)
        interrupt()
        activeReminder = nil
        isSystemResponse = true
        currentTranscript = ""
        currentResponse = ReminderFormatter.confirmation(for: snoozed, now: Date())
        scheduleAutoDismiss()
    }

    public func removeReminder(_ reminder: Reminder) {
        ReminderStore.shared.remove(reminder)
    }

    // MARK: - Listening helpers

    /// A long standby request makes on-device recognition slower and buries the wake
    /// phrase in unrelated speech. After a pause (or a lot of text) start a fresh
    /// request; the microphone keeps running, so no audio is dropped between words.
    private func scheduleStandbyRotation(identifier: UUID, transcriptLength: Int) {
        standbyRotationTask?.cancel()
        let pause: Duration = transcriptLength > 60 ? .milliseconds(300) : .milliseconds(1500)
        standbyRotationTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: pause) } catch { return }
            guard let self, self.state == .idle, self.wantsAudioCapture,
                  self.activeRecognitionID == identifier,
                  SpeechRecognizer.shared.currentSessionID == identifier else { return }
            self.standbyRotationTask = nil
            self.activeRecognitionID = SpeechRecognizer.shared.startRecognition(wakeWord: AppPreferences.shared.wakeWord)
        }
    }

    /// In follow-up mode the user may still start with the wake phrase out of habit.
    private func strippingWakeWord(from query: String) -> String? {
        let wakeWord = AppPreferences.shared.wakeWord
        guard WakeWordDetector.isValid(wakeWord),
              let rest = WakeWordDetector.query(in: query, targetWakeWord: wakeWord, isEnabled: true) else { return nil }
        // Only a leading wake phrase is removed; a mention later in the sentence is content.
        let leading = WakeWordDetector.query(in: String(query.prefix(wakeWord.count + 2)), targetWakeWord: wakeWord, isEnabled: true)
        return leading == nil ? nil : rest
    }

    /// Shortens the end-of-speech wait for questions and recognized local commands.
    private func looksLikeCompleteRequest(_ query: String) -> Bool {
        if VoiceEndpointPolicy.endsLikeQuestion(query) { return true }
        if SystemVolumeIntentParser.parse(query) != .noMatch { return true }
        switch ReminderIntentParser.parse(query, now: Date()) {
        case .command(.create(_, let message, _)):
            // "十分钟后提醒我" is often followed by what to be reminded of.
            return !message.isEmpty || query.contains("计时") || query.contains("闹钟")
        case .command:
            return true
        default:
            return false
        }
    }

    private func noteListeningProgress(_ query: String) {
        if isFollowUpListening, !query.isEmpty, !currentResponse.isEmpty {
            // The previous answer stays visible until the user actually starts a new question.
            currentResponse = ""
            isSystemResponse = false
            activeReminder = nil
        }
        // Start the weather lookup while the user is still talking.
        if let weather = WeatherIntentDetector.detect(query), weather != lastWeatherPrefetch {
            lastWeatherPrefetch = weather
            let prefs = AppPreferences.shared
            let city = prefs.weatherCity.trimmingCharacters(in: .whitespacesAndNewlines)
            let usesLocation = city.isEmpty && prefs.usesAutomaticLocation
            Task {
                let located = usesLocation ? await LocationService.shared.currentPlace() : nil
                await WeatherService.shared.prefetch(weather, defaultCity: city, located: located)
            }
        }
    }

    private func startFollowUpListening() -> Bool {
        let prefs = AppPreferences.shared
        guard allowsFollowUp, prefs.isFollowUpEnabled, permissionsGranted, speechBlockReason == nil,
              errorMessage == nil, !isPreparingAudio else { return false }
        allowsFollowUp = false
        conversationID = UUID()
        state = .listening
        isFollowUpListening = true
        followUpRewoken = false
        transcriptHandoff.beginManual(initialQuery: "")
        currentTranscript = ""
        isHUDVisible = true
        resumeCapture()
        guard AudioEngineManager.shared.isRunning else {
            state = .idle
            conversationID = nil
            isFollowUpListening = false
            return false
        }
        if let sound = NSSound(named: "Tink") {
            sound.volume = 0.35
            sound.play()
        }
        LLMConnectionWarmer.warm(prefs.activeEndpointURL)
        scheduleVoiceExpiry(voiceEndpoint.begin(now: ProcessInfo.processInfo.systemUptime,
                                                initialWaitDuration: prefs.followUpSeconds))
        return true
    }

    /// One shortcut for the whole conversation: start, send, or interrupt.
    public func toggleVoiceInteraction() {
        switch state {
        case .idle:
            triggerWakeUp()
        case .listening:
            if currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                interrupt()
            } else {
                stopListeningAndProcess()
            }
        case .thinking, .speaking:
            interrupt()
        }
    }

    private func processSystemVolumePrompt(_ userText: String, systemInput: String?) -> Bool {
        let wakeWord = AppPreferences.shared.wakeWord
        let displayedIntent = SystemVolumeIntentParser.parse(userText, wakeWord: wakeWord)
        var intent = systemInput.map { SystemVolumeIntentParser.parse($0, wakeWord: wakeWord) } ?? displayedIntent
        if systemInput != nil, intent == .noMatch, displayedIntent != .noMatch {
            // Wake handoff may hide a negation, quotation, or later ASR revision.
            // A system action must be authorized by the complete latest input.
            intent = .invalidIntent("没有收到完整、独立的音量指令。请重新说完整唤醒词和音量指令。")
        }
        switch intent {
        case .noMatch:
            return false
        case .invalidIntent(let reason):
            isSystemResponse = true
            errorMessage = reason
            hasModelError = true
            currentResponse = "音量操作未执行。"
            finishInteraction()
        case .command(let command):
            isSystemResponse = true
            do {
                let result = try SystemVolumeController.shared.execute(command)
                currentResponse = SystemVolumeFeedback.message(for: result, command: command)
                history.record(user: userText, assistant: currentResponse)
                logger.notice("系统音量操作完成：changed=\(result.changed), percent=\(result.after.volumePercent ?? -1)")
                if SystemVolumeFeedback.shouldSpeak(result.after, command: command) {
                    activeSpeechID = SpeechSynthesizer.shared.speak(
                        text: currentResponse, rate: AppPreferences.shared.ttsVoiceRate
                    )
                } else {
                    finishInteraction()
                }
            } catch {
                errorMessage = "音量操作未完成：\(error.localizedDescription)"
                hasModelError = true
                currentResponse = "音量操作未完成，系统没有确认结果。"
                logger.error("系统音量操作失败：\(error.localizedDescription, privacy: .public)")
                finishInteraction()
            }
        }
        return true
    }

    private func cancelInteraction() {
        // Invalidate IDs before cancelling work that can enqueue completion callbacks.
        conversationID = nil
        activeSpeechID = nil
        replySubmittedAt = nil
        activeRecognitionID = nil
        currentTask?.cancel()
        currentTask = nil
        finalTranscriptTask?.cancel()
        finalTranscriptTask = nil
        isFinalizingSpeech = false
        isVoicePreviewing = false
        SpeechSynthesizer.shared.stop()
        SpeechRecognizer.shared.stopRecognition()
        silenceTimer?.invalidate()
        silenceTimer = nil
        dismissTimer?.invalidate()
        dismissTimer = nil
        transcriptHandoff.reset()
        voiceEndpoint.cancel()
        allowsFollowUp = false
        isFollowUpListening = false
        activeReminder = nil
        state = .idle
    }

    private func finishInteraction(delay: TimeInterval? = nil) {
        conversationID = nil
        replySubmittedAt = nil
        state = .idle
        isVoicePreviewing = false
        isFollowUpListening = false
        if deliverReminderIfPossible() { return }
        if startFollowUpListening() { return }
        allowsFollowUp = false
        refreshWakeSettings()
        if errorMessage == nil { scheduleAutoDismiss(delay: delay) }
    }

    public func interrupt() {
        cancelInteraction()
        refreshWakeSettings()
        if !reminderQueue.isEmpty {
            Task { @MainActor [weak self] in _ = self?.deliverReminderIfPossible() }
        }
    }

    public func dismissHUD() {
        interrupt()
        isHUDVisible = false
    }

    public func clearConversation() {
        interrupt()
        history.clear()
        currentTranscript = ""
        currentResponse = ""
    }

    public func openDictationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    public func shutdown() {
        SpeechSynthesizer.shared.shutdown()
        cancelInteraction()
        pauseCapture()
    }

    private func scheduleVoiceExpiry(_ expiry: VoiceEndpointPolicy.Expiry) {
        silenceTimer?.invalidate()
        let identifier = conversationID
        let remaining = max(0.01, expiry.deadline - ProcessInfo.processInfo.systemUptime)
        let timer = Timer(timeInterval: remaining, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.state == .listening, self.conversationID == identifier,
                      self.voiceEndpoint.expiry?.generation == expiry.generation else { return }
                if self.voiceEndpoint.isExpired(generation: expiry.generation, now: ProcessInfo.processInfo.systemUptime) {
                    self.stopListeningAndProcess()
                } else {
                    self.scheduleVoiceExpiry(expiry)
                }
            }
        }
        silenceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func scheduleAutoDismiss(delay: TimeInterval? = nil) {
        dismissTimer?.invalidate()
        let interval = delay ?? AppPreferences.shared.autoDismissSeconds
        dismissTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                // A reminder stays on screen until it is acknowledged.
                guard let self, self.state == .idle, self.activeReminder == nil else { return }
                self.isHUDVisible = false
            }
        }
    }
}
