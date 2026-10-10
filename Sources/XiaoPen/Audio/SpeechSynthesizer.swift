import Foundation
import AVFoundation
import Observation

private struct SpeechUtteranceToken: Sendable {
    let sessionID: UUID
    let utteranceID: UUID
}

/// Delegate callbacks snapshot a stable token before hopping to the main actor.
/// This prevents delayed callbacks from matching a reused utterance object address.
private final class SpeechUtteranceTokens: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [ObjectIdentifier: SpeechUtteranceToken] = [:]

    func insert(_ token: SpeechUtteranceToken, for identifier: ObjectIdentifier) {
        lock.lock()
        defer { lock.unlock() }
        tokens[identifier] = token
    }

    func token(for identifier: ObjectIdentifier, removing: Bool = false) -> SpeechUtteranceToken? {
        lock.lock()
        defer { lock.unlock() }
        return removing ? tokens.removeValue(forKey: identifier) : tokens[identifier]
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        tokens.removeAll(keepingCapacity: true)
    }
}

@Observable
@MainActor
public final class SpeechSynthesizer: NSObject, AVSpeechSynthesizerDelegate {
    public static let shared = SpeechSynthesizer()

    private let synthesizer = AVSpeechSynthesizer()
    private var session = StreamingSpeechLifecycle()
    private var textBuffer = StreamingSpeechTextBuffer()
    private var streamRate: Float = 0.52
    private nonisolated let utteranceTokens = SpeechUtteranceTokens()
    @ObservationIgnored private let localWorker = LocalSpeechWorker()
    @ObservationIgnored private let playbackEngine = AVAudioEngine()
    @ObservationIgnored private let playbackNode = AVAudioPlayerNode()
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private var localQueue: [LocalUtterance] = []
    @ObservationIgnored private var localPlayback: [UUID: LocalPlayback] = [:]
    @ObservationIgnored private var configurationObserver: NSObjectProtocol?
    private var streamEngine: TTSEngineType = .system
    private var streamVoice: QwenVoice = .serena
    private var streamStyle = ""
    private var localFailed = false
    private var preparationID: UUID?
    private var isShuttingDown = false

    private struct LocalUtterance: Sendable {
        let text: String
        let sessionID: UUID
        let utteranceID: UUID
    }

    private struct LocalPlayback {
        var generated = false
        var scheduledBuffers = 0
    }

    public private(set) var localModelStatus = LocalSpeechWorker.isModelInstalled
        ? "本机模型已安装 · 尚未加载" : "本机模型尚未安装（约 3.1 GB）"

    public var onSpeakingStarted: (@Sendable (UUID) -> Void)?
    public var onSpeakingFinished: (@Sendable (UUID) -> Void)?
    public var onSpeechError: (@MainActor @Sendable (UUID, String) -> Void)?

    private override init() {
        super.init()
        synthesizer.delegate = self
        playbackEngine.attach(playbackNode)
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        playbackEngine.connect(playbackNode, to: playbackEngine.mainMixerNode, format: format)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: playbackEngine, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.streamEngine == .localQwen, !self.localFailed,
                      let sessionID = self.session.currentID else { return }
                self.failSpeech(LocalSpeechError.outputChanged, sessionID: sessionID)
            }
        }
    }

    @discardableResult
    public func speak(text: String, rate: Float = 0.52) -> UUID {
        let identifier = beginStream(rate: rate)
        enqueue(text: text, sessionID: identifier)
        finishStream(sessionID: identifier)
        return identifier
    }

    @discardableResult
    public func beginStream(rate: Float = 0.52) -> UUID {
        stop()
        let prefs = AppPreferences.shared
        streamEngine = prefs.ttsEngine
        streamVoice = prefs.qwenVoice
        streamStyle = String(prefs.qwenVoiceStyle.prefix(300))
        localFailed = false
        streamRate = rate.isFinite ? min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate) : 0.52
        return session.begin()
    }

    /// Accepts a raw model delta, not just an already completed sentence.
    public func enqueue(text: String, sessionID: UUID) {
        guard session.isCurrent(sessionID), !session.generationFinished else { return }
        guard !localFailed else { return }
        for sentence in textBuffer.append(text) {
            queue(sentence, sessionID: sessionID)
        }
    }

    public func finishStream(sessionID: UUID) {
        guard session.isCurrent(sessionID), !session.generationFinished else { return }
        if !localFailed {
            for remainder in textBuffer.finish() {
                queue(remainder, sessionID: sessionID)
            }
        }
        if let finished = session.finishGeneration(sessionID: sessionID) {
            onSpeakingFinished?(finished)
        }
    }

    private func queue(_ text: String, sessionID: UUID) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let utteranceID = session.enqueueUtterance(sessionID: sessionID) else { return }
        if streamEngine == .localQwen {
            localQueue.append(LocalUtterance(text: text, sessionID: sessionID, utteranceID: utteranceID))
            localPlayback[utteranceID] = LocalPlayback()
            startLocalGenerationIfNeeded(sessionID: sessionID)
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = streamRate
        utterance.pitchMultiplier = 1.05
        utterance.volume = 1.0

        utteranceTokens.insert(SpeechUtteranceToken(sessionID: sessionID, utteranceID: utteranceID),
                               for: ObjectIdentifier(utterance))
        synthesizer.speak(utterance)
    }

    public func stop() {
        // Invalidate before stopSpeaking can emit a cancellation delegate callback.
        let oldSession = session.currentID
        session.invalidate()
        textBuffer = StreamingSpeechTextBuffer()
        utteranceTokens.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
        generationTask?.cancel()
        generationTask = nil
        localQueue.removeAll()
        localPlayback.removeAll()
        startedLocalUtterances.removeAll()
        playbackNode.stop()
        playbackEngine.stop()
        if let oldSession {
            if streamEngine == .localQwen {
                preparationID = nil
                localModelStatus = "本机语音已中断 · 正在重新准备"
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.localWorker.stop(sessionID: oldSession)
                if !self.isShuttingDown, AppPreferences.shared.ttsEngine == .localQwen {
                    await self.prepareLocalModel()
                }
            }
        }
    }

    public func shutdown() {
        isShuttingDown = true
        stop()
        preparationID = nil
        Task { await localWorker.shutdown() }
    }

    public func prepareLocalModel() async {
        guard preparationID == nil, !isShuttingDown else { return }
        let identifier = UUID()
        preparationID = identifier
        localModelStatus = "正在加载本机语音模型..."
        defer { if preparationID == identifier { preparationID = nil } }
        do {
            try await localWorker.prepare()
            guard !Task.isCancelled, preparationID == identifier else { return }
            localModelStatus = "Qwen3-TTS 1.7B · 本机语音已就绪"
        } catch {
            guard !Task.isCancelled, preparationID == identifier else { return }
            localModelStatus = error.localizedDescription
        }
    }

    private func startLocalGenerationIfNeeded(sessionID: UUID) {
        guard generationTask == nil, !localFailed else { return }
        let voice = streamVoice.rawValue
        let style = streamStyle
        generationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.session.isCurrent(sessionID), !self.localQueue.isEmpty {
                let utterance = self.localQueue.removeFirst()
                do {
                    try Task.checkCancellation()
                    let stream = try await self.localWorker.generate(
                        text: utterance.text, voice: voice, style: style,
                        sessionID: sessionID, utteranceID: utterance.utteranceID)
                    for try await event in stream {
                        try Task.checkCancellation()
                        guard self.session.isCurrent(sessionID) else { return }
                        switch event {
                        case .audio(let samples, let sampleRate):
                            try self.scheduleAudio(samples, sampleRate: sampleRate, utterance: utterance)
                        }
                    }
                    try Task.checkCancellation()
                    guard self.session.isCurrent(sessionID) else { return }
                    guard var playback = self.localPlayback[utterance.utteranceID], playback.scheduledBuffers > 0
                        || self.startedLocalUtterances.contains(utterance.utteranceID) else {
                        throw LocalSpeechError.invalidAudio
                    }
                    playback.generated = true
                    self.localPlayback[utterance.utteranceID] = playback
                    self.completeLocalUtteranceIfReady(utterance)
                } catch {
                    guard !Task.isCancelled, self.session.isCurrent(sessionID) else { return }
                    self.failSpeech(error, sessionID: sessionID)
                    return
                }
            }
            if self.session.isCurrent(sessionID) { self.generationTask = nil }
        }
    }

    @ObservationIgnored private var startedLocalUtterances: Set<UUID> = []

    private func scheduleAudio(_ samples: [Float], sampleRate: Int, utterance: LocalUtterance) throws {
        guard sampleRate == 24_000, !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?.pointee else { throw LocalSpeechError.invalidAudio }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel.update(from: base, count: source.count)
        }
        if !playbackEngine.isRunning { try playbackEngine.start() }
        guard var playback = localPlayback[utterance.utteranceID] else { return }
        playback.scheduledBuffers += 1
        localPlayback[utterance.utteranceID] = playback
        playbackNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.session.isCurrent(utterance.sessionID),
                      var playback = self.localPlayback[utterance.utteranceID] else { return }
                playback.scheduledBuffers -= 1
                self.localPlayback[utterance.utteranceID] = playback
                self.completeLocalUtteranceIfReady(utterance)
            }
        }
        if !playbackNode.isPlaying { playbackNode.play() }
        startedLocalUtterances.insert(utterance.utteranceID)
        localModelStatus = "Qwen3-TTS 1.7B · 本机语音已就绪"
        if session.didStart(utteranceID: utterance.utteranceID, sessionID: utterance.sessionID) {
            onSpeakingStarted?(utterance.sessionID)
        }
    }

    private func completeLocalUtteranceIfReady(_ utterance: LocalUtterance) {
        guard let playback = localPlayback[utterance.utteranceID], playback.generated,
              playback.scheduledBuffers == 0 else { return }
        localPlayback.removeValue(forKey: utterance.utteranceID)
        startedLocalUtterances.remove(utterance.utteranceID)
        if let finished = session.didFinish(utteranceID: utterance.utteranceID, sessionID: utterance.sessionID) {
            onSpeakingFinished?(finished)
        }
    }

    private func failSpeech(_ error: Error, sessionID: UUID) {
        guard session.isCurrent(sessionID) else { return }
        localFailed = true
        generationTask = nil
        localQueue.removeAll()
        localPlayback.removeAll()
        startedLocalUtterances.removeAll()
        playbackNode.stop()
        playbackEngine.stop()
        if streamEngine == .localQwen { localModelStatus = error.localizedDescription }
        onSpeechError?(sessionID, error.localizedDescription)
        if streamEngine == .localQwen { Task { await localWorker.stop(sessionID: sessionID) } }
        utteranceTokens.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
        for utteranceID in session.pendingUtteranceIDs {
            if let finished = session.didFinish(utteranceID: utteranceID, sessionID: sessionID) {
                onSpeakingFinished?(finished)
            }
        }
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        guard let token = utteranceTokens.token(for: ObjectIdentifier(utterance)) else { return }
        Task { @MainActor [weak self] in
            guard let self, self.session.didStart(utteranceID: token.utteranceID, sessionID: token.sessionID) else { return }
            self.onSpeakingStarted?(token.sessionID)
        }
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard let token = utteranceTokens.token(for: ObjectIdentifier(utterance), removing: true) else { return }
        Task { @MainActor [weak self] in
            guard let self, let finished = self.session.didFinish(utteranceID: token.utteranceID, sessionID: token.sessionID) else { return }
            self.onSpeakingFinished?(finished)
        }
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        // A deliberate interruption belongs to the caller, not a completed reply.
        guard let token = utteranceTokens.token(for: ObjectIdentifier(utterance), removing: true) else { return }
        Task { @MainActor [weak self] in
            guard let self, self.session.isCurrent(token.sessionID) else { return }
            self.failSpeech(LocalSpeechError.systemInterrupted, sessionID: token.sessionID)
        }
    }
}
