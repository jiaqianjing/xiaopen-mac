import Foundation
import Speech
import AVFoundation
import OSLog

/// The render callback and recognizer lifecycle share this request exclusively under a lock.
private final class SpeechAudioRequestBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var input = SpeechInputSnapshot()

    func replace(with request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        defer { lock.unlock() }
        self.request?.endAudio()
        self.request = request
        input = SpeechInputSnapshot()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let request else { return }
        let format = buffer.format
        if input.firstFormat == nil {
            input.firstFormat = SpeechInputSnapshot.Format(
                sampleRate: format.sampleRate, channelCount: format.channelCount,
                commonFormat: format.commonFormat.rawValue, isInterleaved: format.isInterleaved,
                firstFrameCount: buffer.frameLength)
        }
        guard buffer.frameLength > 0, format.sampleRate > 0, format.channelCount > 0 else { return }
        let duration = Double(buffer.frameLength) / format.sampleRate
        input.bufferCount += 1
        input.audioDuration += duration
        input.lastBufferUptime = ProcessInfo.processInfo.systemUptime
        // The same first-channel energy that drives the waveform supplies a scalar
        // signal-presence estimate. No samples are retained and no logging runs here.
        if let samples = buffer.floatChannelData?[0] {
            let stride = format.isInterleaved ? Int(format.channelCount) : 1
            var squareSum: Float = 0
            for frame in 0..<Int(buffer.frameLength) {
                let sample = samples[frame * stride]
                squareSum += sample * sample
            }
            let meanSquare = squareSum / Float(buffer.frameLength)
            if meanSquare.isFinite, meanSquare >= 0.0001 {
                input.voicedDuration += duration
            }
        }
        request.append(buffer)
    }

    func snapshot() -> SpeechInputSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return input
    }
}

@MainActor
public final class SpeechRecognizer {
    public static let shared = SpeechRecognizer()

    private var recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.jiaqianjing.XiaoPen", category: "SpeechRecognition")
    private nonisolated let audioRequest = SpeechAudioRequestBridge()
    private var recognitionTask: SFSpeechRecognitionTask?
    private var session = AudioSessionLifecycle()
    private var restartTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var shouldRecognize = false
    private var acceptsResults = false
    private var isFinishing = false
    private var wakeWord = ""
    private var recoveryBackoff = AudioRecoveryBackoff()
    private var hasReceivedTranscript = false
    private var didLogFirstBuffer = false
    private var sessionStartedAt: TimeInterval = 0
    private var needsRecognizerReset = false
    private let inputWatchdog = SpeechInputWatchdog()
    private var inputRecoveryBudget = SpeechInputRecoveryBudget()

    public var currentSessionID: UUID? { session.currentID }
    public private(set) var statusMessage = "语音识别未启动。"
    public private(set) var blockedFailure: SpeechRecognitionFailure?
    public var supportsOnDeviceRecognition: Bool { recognizer?.supportsOnDeviceRecognition ?? false }
    public var isServiceAvailable: Bool { recognizer?.isAvailable ?? false }
    public var recognitionLocaleIdentifier: String { recognizer?.locale.identifier ?? "zh-CN" }
    public var onTranscriptUpdate: (@Sendable (String, Bool, UUID) -> Void)?
    public var onSessionStarted: (@Sendable (UUID) -> Void)?
    public var onStatusMessage: (@Sendable (String) -> Void)?
    public var onRecognitionError: (@Sendable (String, UUID) -> Void)?

    private init() {}

    public static func requestAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined: break
        @unknown default: return false
        }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    @discardableResult
    public func startRecognition(wakeWord: String = "") -> UUID? {
        stopRecognition()
        shouldRecognize = true
        self.wakeWord = wakeWord.trimmingCharacters(in: .whitespacesAndNewlines)
        recoveryBackoff.reset()
        inputRecoveryBudget.reset()
        // Explicit retry recreates the local recognizer after a blocked/stalled task.
        needsRecognizerReset = true
        return beginSession()
    }

    private func beginSession() -> UUID? {
        guard shouldRecognize, !isFinishing else { return nil }
        blockedFailure = nil
        hasReceivedTranscript = false
        didLogFirstBuffer = false
        if needsRecognizerReset {
            recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
            needsRecognizerReset = false
        }
        let sessionID = session.begin()
        onSessionStarted?(sessionID)
        let locale = recognitionLocaleIdentifier
        let serviceAvailable = isServiceAvailable
        let localRecognition = supportsOnDeviceRecognition
        logger.notice("识别尝试：session=\(sessionID.uuidString, privacy: .public), locale=\(locale, privacy: .public), available=\(serviceAvailable), onDevice=\(localRecognition)")
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            let failure = SpeechRecognitionFailure(domain: "kAFAssistantErrorDomain", code: 1700, message: "Speech recognition is not authorized")
            blockRecognition(failure, sessionID: sessionID)
            return sessionID
        }
        guard let recognizer else {
            blockRecognition(.unsupportedLocale("zh-CN"), sessionID: sessionID)
            return sessionID
        }
        guard recognizer.supportsOnDeviceRecognition else {
            // Audio must never leave the machine as an unrequested failure fallback.
            blockRecognition(.localRecognitionUnavailable(), sessionID: sessionID)
            return sessionID
        }
        guard recognizer.isAvailable else {
            let message = "语音识别服务暂不可用，正在等待恢复。"
            setStatus(message)
            onRecognitionError?(message, sessionID)
            scheduleRestart(after: recoveryBackoff.nextDelay())
            return sessionID
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = true
        if !wakeWord.isEmpty {
            request.contextualStrings = [wakeWord]
        }
        setStatus("正在启动本机中文语音识别。")

        audioRequest.replace(with: request)
        sessionStartedAt = ProcessInfo.processInfo.systemUptime
        acceptsResults = true
        recognitionTask = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            // Only Sendable snapshots cross from Apple's callback queue to the main actor.
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failure = error.map { SpeechRecognitionFailure.snapshot($0) }
            Task { @MainActor [weak self] in
                self?.handleResult(transcript: transcript, isFinal: isFinal, failure: failure, sessionID: sessionID)
            }
        }
        logger.notice("识别任务启动：session=\(sessionID.uuidString, privacy: .public), onDevice=\(localRecognition)")
        startWatchdog(sessionID: sessionID)
        return sessionID
    }

    private func handleResult(transcript: String?, isFinal: Bool, failure: SpeechRecognitionFailure?, sessionID: UUID) {
        guard shouldRecognize, acceptsResults, session.isCurrent(sessionID) else { return }
        // A terminal configuration failure takes precedence over any final/partial
        // text in the same callback; it must not dispatch a new wake-up first.
        if let failure, failure.isBlocking {
            logger.error("识别失败：domain=\(failure.domain, privacy: .public), code=\(failure.code)")
            blockRecognition(failure, sessionID: sessionID)
            return
        }
        if let transcript {
            if !transcript.isEmpty, !hasReceivedTranscript {
                hasReceivedTranscript = true
                inputRecoveryBudget.reset()
                logger.notice("收到首条非空转写：session=\(sessionID.uuidString, privacy: .public)")
                blockedFailure = nil
                setStatus("本机中文语音识别正在运行。")
            }
            onTranscriptUpdate?(transcript, isFinal, sessionID)
        }
        if isFinal {
            logger.notice("识别任务完成：session=\(sessionID.uuidString, privacy: .public)")
            blockedFailure = nil
            recoveryBackoff.reset()
            finishCurrentSession(invalidateSession: false)
            if isFinishing {
                setStatus("本机语音识别已完成。")
            } else {
                scheduleRestart(after: 0.4)
            }
        } else if let failure {
            logger.error("识别失败：domain=\(failure.domain, privacy: .public), code=\(failure.code)")
            finishCurrentSession(invalidateSession: false)
            if isFinishing {
                // Finishing may end with an error instead of a final result. The caller
                // owns its bounded wait and can still use the last partial transcription.
                if failure.actionNeed == .resumeListening || failure.actionNeed == .none {
                    setStatus("本机语音识别已结束。")
                } else {
                    setStatus(failure.recoveryMessage)
                    onRecognitionError?(failure.recoveryMessage, sessionID)
                }
                return
            }
            if failure.actionNeed == .resumeListening || failure.actionNeed == .none {
                // Silence ends a recognition window; intentional stop/new-session callbacks
                // are already rejected by the UUID and acceptsResults guards above.
                // Continue desired listening without displaying an error for cancellation.
                scheduleRestart(after: 0.4)
                return
            }
            let delay = recoveryBackoff.nextDelay()
            let message = "\(failure.recoveryMessage)。将在 \(Int(delay)) 秒后重试。"
            setStatus(message)
            onRecognitionError?(message, sessionID)
            scheduleRestart(after: delay)
        }
    }

    private func blockRecognition(_ failure: SpeechRecognitionFailure, sessionID: UUID) {
        shouldRecognize = false
        restartTask?.cancel()
        restartTask = nil
        finishCurrentSession(invalidateSession: false)
        blockedFailure = failure
        logger.error("识别被阻断：domain=\(failure.domain, privacy: .public), code=\(failure.code)")
        setStatus(failure.recoveryMessage)
        onRecognitionError?(failure.recoveryMessage, sessionID)
    }

    public nonisolated func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        audioRequest.append(buffer)
    }

    /// Stop accepting audio while letting the current task process its remaining input.
    /// The caller must stop microphone capture and bound its wait for a final/error callback.
    /// A later stopRecognition() invalidates the UUID and rejects any remaining callbacks.
    public func finishAudio() {
        guard shouldRecognize, session.currentID != nil, !isFinishing else { return }
        isFinishing = true
        restartTask?.cancel()
        restartTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        // replace(nil) calls endAudio under the same lock as append, then prevents
        // queued capture buffers from being added to the finishing request.
        audioRequest.replace(with: nil)
        recognitionTask?.finish()
        if let sessionID = session.currentID {
            logger.notice("请求完成当前识别：session=\(sessionID.uuidString, privacy: .public)")
        }
        setStatus("正在完成本机语音识别。")
    }

    private func setStatus(_ message: String) {
        statusMessage = message
        onStatusMessage?(message)
    }

    private func finishCurrentSession(invalidateSession: Bool = true) {
        acceptsResults = false
        watchdogTask?.cancel()
        watchdogTask = nil
        if invalidateSession { session.invalidate() }
        audioRequest.replace(with: nil)
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    private func startWatchdog(sessionID: UUID) {
        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
                guard let self, !Task.isCancelled, self.shouldRecognize,
                      self.acceptsResults, self.session.isCurrent(sessionID) else { return }
                self.inspectInput(sessionID: sessionID)
            }
        }
    }

    private func inspectInput(sessionID: UUID) {
        let input = audioRequest.snapshot()
        if !didLogFirstBuffer, let format = input.firstFormat {
            didLogFirstBuffer = true
            logger.notice("识别收到首个音频 buffer：session=\(sessionID.uuidString, privacy: .public), sampleRate=\(format.sampleRate), channels=\(format.channelCount), commonFormat=\(format.commonFormat), interleaved=\(format.isInterleaved), frames=\(format.firstFrameCount)")
        }
        guard let stall = inputWatchdog.failure(
            now: ProcessInfo.processInfo.systemUptime, sessionStartedAt: sessionStartedAt,
            input: input, hasReceivedTranscript: hasReceivedTranscript) else { return }
        logger.error("识别输入 watchdog：session=\(sessionID.uuidString, privacy: .public), reason=\(stall.diagnosticName, privacy: .public), buffers=\(input.bufferCount), audioSeconds=\(input.audioDuration), voicedSeconds=\(input.voicedDuration)")
        let willRetry = inputRecoveryBudget.recordFailure()
        let failure = SpeechRecognitionFailure.inputStalled(stall)
        if !willRetry {
            blockRecognition(failure, sessionID: sessionID)
            return
        }
        finishCurrentSession(invalidateSession: false)
        needsRecognizerReset = true
        let delay = recoveryBackoff.nextDelay()
        let message = "\(stall.userMessage)将在 \(Int(delay)) 秒后重启本机识别（\(inputRecoveryBudget.failureCount)/\(inputRecoveryBudget.maximumFailures)）。"
        setStatus(message)
        onRecognitionError?(message, sessionID)
        scheduleRestart(after: delay)
    }

    private func scheduleRestart(after delay: TimeInterval) {
        restartTask?.cancel()
        restartTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.shouldRecognize, !self.isFinishing else { return }
            self.restartTask = nil
            _ = self.beginSession()
        }
    }

    public func stopRecognition() {
        shouldRecognize = false
        isFinishing = false
        restartTask?.cancel()
        restartTask = nil
        finishCurrentSession()
        blockedFailure = nil
        hasReceivedTranscript = false
        statusMessage = "语音识别已停止。"
    }
}
