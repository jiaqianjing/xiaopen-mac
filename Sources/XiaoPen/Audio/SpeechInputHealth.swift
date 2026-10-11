import Foundation

/// Scalar metadata only: this snapshot never owns audio samples or recognized text.
struct SpeechInputSnapshot: Sendable {
    struct Format: Sendable {
        let sampleRate: Double
        let channelCount: UInt32
        let commonFormat: UInt
        let isInterleaved: Bool
        let firstFrameCount: UInt32
    }

    var firstFormat: Format?
    var bufferCount: UInt64 = 0
    var audioDuration: TimeInterval = 0
    var voicedDuration: TimeInterval = 0
    /// Voiced audio within the last `recentWindow` seconds; isolated noises spread
    /// over a long quiet standby never add up to a "stall".
    var recentVoicedDuration: TimeInterval = 0
    var lastBufferUptime: TimeInterval?
    var peakMeanSquare: Double = 0
    var voicedMeanSquareSum: Double = 0
    var voicedBufferCount = 0
    var quietMeanSquareSum: Double = 0
    var quietBufferCount = 0

    var peakLevelDB: Int { Self.decibels(peakMeanSquare) }
    var voicedAverageLevelDB: Int {
        voicedBufferCount == 0 ? -120 : Self.decibels(voicedMeanSquareSum / Double(voicedBufferCount))
    }
    var noiseFloorDB: Int {
        quietBufferCount == 0 ? -120 : Self.decibels(quietMeanSquareSum / Double(quietBufferCount))
    }

    /// Power in dBFS from a mean square; -120 stands for digital silence.
    static func decibels(_ meanSquare: Double) -> Int {
        meanSquare > 0 ? max(-120, Int((10 * log10(meanSquare)).rounded())) : -120
    }

    static let recentWindow: TimeInterval = 12
}

enum SpeechInputStall: Sendable, Equatable {
    case noBuffers
    case inputStopped
    case noTranscription

    var diagnosticName: String {
        switch self {
        case .noBuffers: return "no_buffers"
        case .inputStopped: return "input_stopped"
        case .noTranscription: return "no_transcription"
        }
    }

    var userMessage: String {
        switch self {
        case .noBuffers:
            return "语音识别未收到麦克风音频，请检查输入设备连接。"
        case .inputStopped:
            return "麦克风音频已中断，请检查输入设备连接。"
        case .noTranscription:
            return "已收到麦克风声音，但本机语音识别未返回文字。"
        }
    }
}

/// Silence and occasional noise are normal. A failure needs missing input, or
/// sustained recent sound (like someone talking) that produces no text at all.
struct SpeechInputWatchdog: Sendable {
    let startupGrace: TimeInterval
    let minimumVoicedDuration: TimeInterval
    let missingBufferTimeout: TimeInterval

    init(startupGrace: TimeInterval = 15,
         minimumVoicedDuration: TimeInterval = 4,
         missingBufferTimeout: TimeInterval = 5) {
        precondition(startupGrace > 0 && minimumVoicedDuration > 0 && missingBufferTimeout > 0)
        self.startupGrace = startupGrace
        self.minimumVoicedDuration = minimumVoicedDuration
        self.missingBufferTimeout = missingBufferTimeout
    }

    func failure(now: TimeInterval, sessionStartedAt: TimeInterval,
                 input: SpeechInputSnapshot, hasReceivedTranscript: Bool) -> SpeechInputStall? {
        guard now - sessionStartedAt >= startupGrace else { return nil }
        guard input.bufferCount > 0, let lastBuffer = input.lastBufferUptime else { return .noBuffers }
        if now - lastBuffer >= missingBufferTimeout { return .inputStopped }
        if !hasReceivedTranscript, input.recentVoicedDuration >= minimumVoicedDuration { return .noTranscription }
        return nil
    }
}

/// An explicit retry or a genuine transcription restores the bounded automatic retry budget.
struct SpeechInputRecoveryBudget: Sendable {
    let maximumFailures: Int
    private(set) var failureCount = 0

    init(maximumFailures: Int = 3) {
        precondition(maximumFailures > 0)
        self.maximumFailures = maximumFailures
    }

    mutating func recordFailure() -> Bool {
        failureCount = min(failureCount + 1, maximumFailures)
        return failureCount < maximumFailures
    }

    mutating func reset() {
        failureCount = 0
    }
}
