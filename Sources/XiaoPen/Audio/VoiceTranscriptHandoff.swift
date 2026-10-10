import Foundation

/// Keeps cumulative ASR updates in one request across the wake-to-listening transition.
struct VoiceTranscriptHandoff: Sendable {
    private(set) var query = ""
    /// Complete user ASR text, retaining any text before a matched wake phrase.
    /// System commands must validate this instead of the conversational suffix.
    private(set) var rawSystemCommandTranscript = ""
    private(set) var currentSessionID: UUID?
    private var wakeWord: String?
    private var carriedPrefix = ""
    private var rawCarriedPrefix = ""

    /// A valid wake match may have an empty query when the user has only said the wake word.
    @discardableResult
    mutating func beginWake(transcript: String, wakeWord: String, sessionID: UUID) -> String? {
        guard let query = WakeWordDetector.query(in: transcript, targetWakeWord: wakeWord, isEnabled: true) else {
            return nil
        }
        reset()
        self.wakeWord = wakeWord
        currentSessionID = sessionID
        self.query = query
        rawSystemCommandTranscript = transcript
        return query
    }

    mutating func beginManual(initialQuery: String = "") {
        reset()
        query = initialQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        carriedPrefix = query
        rawSystemCommandTranscript = initialQuery
        rawCarriedPrefix = initialQuery
    }

    /// The caller must first validate this ID against the recognizer's current session.
    /// A restarted request contains new audio, so only that request's latest partial is appended.
    mutating func recognitionStarted(_ sessionID: UUID) {
        guard currentSessionID != sessionID else { return }
        carriedPrefix = query
        rawCarriedPrefix = rawSystemCommandTranscript
        wakeWord = nil
        currentSessionID = sessionID
    }

    @discardableResult
    mutating func update(transcript: String, sessionID: UUID, isFinal: Bool = false) -> String? {
        guard currentSessionID == sessionID else { return nil }
        // Save every current hypothesis before wake matching, including an empty
        // or revised hypothesis. A stale usable query must not authorize a write.
        let rawText = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        rawSystemCommandTranscript = rawText.isEmpty ? rawCarriedPrefix :
            (rawCarriedPrefix.isEmpty ? transcript : rawCarriedPrefix + " " + transcript)
        let newText: String
        if let wakeWord {
            // Partial hypotheses can revise the wake word. Until it matches again,
            // preserve the last usable query instead of inserting the wake phrase.
            guard let suffix = WakeWordDetector.query(in: transcript, targetWakeWord: wakeWord, isEnabled: true) else {
                return nil
            }
            newText = suffix
        } else {
            newText = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !newText.isEmpty || isFinal else { return nil }
        query = newText.isEmpty ? carriedPrefix : (carriedPrefix.isEmpty ? newText : carriedPrefix + " " + newText)
        return query
    }

    mutating func reset() {
        query = ""
        rawSystemCommandTranscript = ""
        currentSessionID = nil
        wakeWord = nil
        carriedPrefix = ""
        rawCarriedPrefix = ""
    }
}
