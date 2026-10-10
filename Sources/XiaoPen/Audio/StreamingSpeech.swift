import Foundation

/// Model deltas may end anywhere; only consume text once a safe speech boundary exists.
struct StreamingSpeechTextBuffer: Sendable {
    private(set) var pendingText = ""
    private let maximumBufferedLength: Int
    private let minimumClauseLength: Int
    /// The first utterance may end at an early comma so speech starts sooner;
    /// later ones keep longer phrases for more natural prosody.
    private let firstClauseLength: Int
    private var hasEmitted = false

    init(maximumBufferedLength: Int = 80, minimumClauseLength: Int = 24, firstClauseLength: Int = 10) {
        precondition(maximumBufferedLength > 0)
        precondition(minimumClauseLength > 0 && minimumClauseLength <= maximumBufferedLength)
        precondition(firstClauseLength > 0)
        self.maximumBufferedLength = maximumBufferedLength
        self.minimumClauseLength = minimumClauseLength
        self.firstClauseLength = firstClauseLength
    }

    mutating func append(_ delta: String) -> [String] {
        pendingText += delta
        var sentences: [String] = []
        while !pendingText.isEmpty {
            let characters = Array(pendingText)
            let sentenceEnd = characters.indices.first { isSentenceEnd(at: $0, in: characters) }
            let clauseEnd = characters.count >= maximumBufferedLength ? safeClauseEnd(in: characters)
                : (hasEmitted ? nil : clauseCandidates(in: characters, minimumLength: firstClauseLength).first)
            let boundary: Int?
            if let sentenceEnd, let clauseEnd {
                boundary = min(sentenceEnd, clauseEnd)
            } else {
                boundary = sentenceEnd ?? clauseEnd
            }
            guard let boundary else { break }
            sentences.append(String(characters[...boundary]))
            hasEmitted = true
            pendingText = String(characters.dropFirst(boundary + 1))
        }
        return sentences
    }

    mutating func finish() -> [String] {
        guard !pendingText.isEmpty else { return [] }
        let remainder = pendingText
        pendingText = ""
        return [remainder]
    }

    private func isSentenceEnd(at index: Int, in characters: [Character]) -> Bool {
        let character = characters[index]
        if "。！？".contains(character) || character.isNewline { return true }
        if character == "!" || character == "?" {
            return !isInsideURL(at: index, in: characters)
        }
        guard character == ".", index + 1 < characters.count,
              characters[index + 1].isWhitespace,
              !isInsideURL(at: index, in: characters) else { return false }

        // Wait for lookahead: "3." + "14" must never become two utterances.
        // Initials, abbreviations and numbered lists are intentionally conservative.
        let token = precedingToken(through: index, in: characters).lowercased()
        let abbreviations: Set<String> = ["mr.", "mrs.", "ms.", "dr.", "prof.", "sr.", "jr.",
                                          "st.", "vs.", "etc.", "e.g.", "i.e."]
        if abbreviations.contains(token) { return false }
        let stem = token.dropLast()
        if !stem.isEmpty && stem.allSatisfy(\.isNumber) { return false }
        let initials = stem.split(separator: ".")
        if !initials.isEmpty && initials.allSatisfy({ $0.count == 1 && $0.first?.isLetter == true }) {
            return false
        }
        return true
    }

    private func safeClauseEnd(in characters: [Character]) -> Int? {
        let candidates = clauseCandidates(in: characters, minimumLength: minimumClauseLength)
        return candidates.last(where: { $0 < maximumBufferedLength }) ?? candidates.first
    }

    private func clauseCandidates(in characters: [Character], minimumLength: Int) -> [Int] {
        characters.indices.filter { index in
            guard index + 1 >= minimumLength,
                  characters[index] == "," || characters[index] == "，",
                  !isInsideURL(at: index, in: characters) else { return false }
            if characters[index] == ",", index > 0, characters[index - 1].isNumber {
                // A trailing comma needs lookahead too, as in "1," + "234".
                if index + 1 == characters.count || characters[index + 1].isNumber { return false }
            }
            return true
        }
    }

    private func isInsideURL(at index: Int, in characters: [Character]) -> Bool {
        let token = precedingToken(through: index, in: characters).lowercased()
        return token.contains("://") || token.contains("www.")
    }

    private func precedingToken(through index: Int, in characters: [Character]) -> String {
        var start = index
        while start > 0 && !characters[start - 1].isWhitespace
            && !"。！？".contains(characters[start - 1]) {
            start -= 1
        }
        return String(characters[start...index])
    }
}

/// A drained speech queue is not completion until the model has finished generating.
struct StreamingSpeechLifecycle: Sendable {
    private(set) var currentID: UUID?
    private(set) var generationFinished = false
    private(set) var pendingUtteranceIDs: Set<UUID> = []
    private var hasStarted = false

    mutating func begin() -> UUID {
        invalidate()
        let identifier = UUID()
        currentID = identifier
        return identifier
    }

    func isCurrent(_ identifier: UUID) -> Bool { currentID == identifier }

    mutating func enqueueUtterance(sessionID: UUID) -> UUID? {
        guard isCurrent(sessionID), !generationFinished else { return nil }
        let identifier = UUID()
        pendingUtteranceIDs.insert(identifier)
        return identifier
    }

    mutating func didStart(utteranceID: UUID, sessionID: UUID) -> Bool {
        guard isCurrent(sessionID), pendingUtteranceIDs.contains(utteranceID), !hasStarted else { return false }
        hasStarted = true
        return true
    }

    mutating func didFinish(utteranceID: UUID, sessionID: UUID) -> UUID? {
        guard isCurrent(sessionID), pendingUtteranceIDs.remove(utteranceID) != nil else { return nil }
        return completeIfReady()
    }

    mutating func finishGeneration(sessionID: UUID) -> UUID? {
        guard isCurrent(sessionID) else { return nil }
        generationFinished = true
        return completeIfReady()
    }

    mutating func invalidate() {
        currentID = nil
        generationFinished = false
        pendingUtteranceIDs.removeAll(keepingCapacity: true)
        hasStarted = false
    }

    private mutating func completeIfReady() -> UUID? {
        guard generationFinished, pendingUtteranceIDs.isEmpty, let identifier = currentID else { return nil }
        invalidate()
        return identifier
    }
}
