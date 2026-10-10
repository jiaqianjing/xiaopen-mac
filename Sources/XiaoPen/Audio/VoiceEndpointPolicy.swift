import Foundation

/// Transcript activity sets a monotonic deadline; audio energy alone never extends it.
struct VoiceEndpointPolicy: Sendable {
    struct Expiry: Sendable, Equatable {
        let generation: UUID
        let deadline: TimeInterval
    }

    let initialWaitDuration: TimeInterval
    let silenceDuration: TimeInterval
    /// Used once the words so far already form a question or a recognized command.
    let completeSilenceDuration: TimeInterval
    private(set) var expiry: Expiry?
    private var lastMeaningfulText = ""

    init(initialWaitDuration: TimeInterval = 6, silenceDuration: TimeInterval = 1.2,
         completeSilenceDuration: TimeInterval = 0.7) {
        precondition(initialWaitDuration > 0 && silenceDuration > 0 && completeSilenceDuration > 0)
        self.initialWaitDuration = initialWaitDuration
        self.silenceDuration = silenceDuration
        self.completeSilenceDuration = min(completeSilenceDuration, silenceDuration)
    }

    @discardableResult
    mutating func begin(now: TimeInterval, initialTranscript: String = "",
                        initialWaitDuration: TimeInterval? = nil) -> Expiry {
        lastMeaningfulText = Self.meaningfulText(initialTranscript)
        let wait = max(0.5, initialWaitDuration ?? self.initialWaitDuration)
        let duration = lastMeaningfulText.isEmpty ? wait : silenceDuration
        return arm(deadline: now + duration)
    }

    /// Empty, repeated, and punctuation-only changes do not represent new spoken words.
    @discardableResult
    mutating func update(transcript: String, now: TimeInterval, likelyComplete: Bool = false) -> Expiry? {
        guard expiry != nil else { return nil }
        let meaningfulText = Self.meaningfulText(transcript)
        guard !meaningfulText.isEmpty, meaningfulText != lastMeaningfulText else { return nil }
        lastMeaningfulText = meaningfulText
        let pause = likelyComplete && meaningfulText.count >= 3 ? completeSilenceDuration : silenceDuration
        return arm(deadline: now + pause)
    }

    /// Sentence-final question particles; trailing periods are not trusted because
    /// partial transcripts can be punctuated before the speaker has finished.
    static func endsLikeQuestion(_ transcript: String) -> Bool {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return false }
        if last == "？" || last == "?" { return true }
        let stripped = trimmed.trimmingCharacters(in: .punctuationCharacters)
        guard stripped.count >= 4, let final = stripped.last else { return false }
        return "吗呢么嘛".contains(final)
    }

    /// Checking the generation rejects a timer that fired before a later transcript reset.
    func isExpired(generation: UUID, now: TimeInterval) -> Bool {
        guard let expiry, expiry.generation == generation else { return false }
        return now >= expiry.deadline
    }

    mutating func cancel() {
        expiry = nil
        lastMeaningfulText = ""
    }

    private mutating func arm(deadline: TimeInterval) -> Expiry {
        let expiry = Expiry(generation: UUID(), deadline: deadline)
        self.expiry = expiry
        return expiry
    }

    private static func meaningfulText(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return String(folded.filter { $0.isLetter || $0.isNumber })
    }
}
