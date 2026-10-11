import Foundation

public enum WakeWordDetector {
    public static func isValid(_ wakeWord: String) -> Bool {
        !normalizedCharacters(in: wakeWord).isEmpty
    }

    /// Returns the original text after the configured phrase, or nil if it did not match.
    /// An empty string is a valid match when the user only says the wake phrase.
    public static func query(
        in transcript: String,
        targetWakeWord: String,
        isEnabled: Bool
    ) -> String? {
        guard isEnabled else { return nil }

        let targetCharacters = normalizedCharacters(in: targetWakeWord)
        let target = targetCharacters.map(\.key)
        let source = normalizedCharacters(in: transcript)
        guard !target.isEmpty, source.count >= target.count else { return nil }

        // Exact (phonetic) matches first; then, for Chinese phrases of four or more
        // syllables, allow one syllable whose initial was misheard (喷→芬/本).
        let tolerant = target.count >= 4 && target.allSatisfy { $0.count >= 2 }
        for pass in tolerant ? [false, true] : [false] {
        for offset in 0...(source.count - target.count) {
            let endOffset = offset + target.count
            let keys = source[offset..<endOffset].map(\.key)
            guard pass ? Self.differsByOneInitial(keys, target) : keys == target else { continue }

            // Case folding can expand one character (for example ß -> ss).
            // Accept matches only at complete original-character boundaries.
            if offset > 0, source[offset - 1].range == source[offset].range { continue }
            if endOffset < source.count, source[endOffset - 1].range == source[endOffset].range { continue }

            let start = source[offset].range.lowerBound
            let end = source[endOffset - 1].range.upperBound

            // English phrases must not match inside words such as "this" or "orbiting".
            if let first = targetCharacters.first?.character, isLatinLetterOrNumber(first), start > transcript.startIndex {
                let previous = transcript[transcript.index(before: start)]
                if isLatinLetterOrNumber(previous) { continue }
            }
            if let last = targetCharacters.last?.character, isLatinLetterOrNumber(last), end < transcript.endIndex,
               isLatinLetterOrNumber(transcript[end]) {
                continue
            }

            return String(transcript[end...]).trimmingCharacters(
                in: .whitespacesAndNewlines.union(.punctuationCharacters)
            )
        }
        }
        return nil
    }

    /// True when every syllable matches except one whose final (vowel part) still matches.
    static func differsByOneInitial(_ keys: [String], _ target: [String]) -> Bool {
        guard keys.count == target.count else { return false }
        var mismatches = 0
        for (key, expected) in zip(keys, target) where key != expected {
            mismatches += 1
            guard mismatches <= 1, key.count >= 2, pinyinFinal(key) == pinyinFinal(expected),
                  !pinyinFinal(key).isEmpty else { return false }
        }
        return mismatches == 1
    }

    private static func pinyinFinal(_ key: String) -> String {
        let initials: Set<Character> = ["b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h", "j", "q", "x",
                                        "z", "c", "s", "r", "y", "w"]
        guard let first = key.first, initials.contains(first) else { return key }
        return String(key.dropFirst())
    }

    private static func isLatinLetterOrNumber(_ character: Character) -> Bool {
        let folded = String(character).folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return folded.unicodeScalars.allSatisfy {
            (97...122).contains($0.value) || (48...57).contains($0.value)
        }
    }

    private static func normalizedCharacters(
        in text: String
    ) -> [(character: Character, key: String, range: Range<String.Index>)] {
        var result: [(character: Character, key: String, range: Range<String.Index>)] = []
        for index in text.indices {
            let range = index..<text.index(after: index)
            let folded = String(text[index]).folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            for character in folded where character.isLetter || character.isNumber {
                result.append((character, phoneticKey(for: character), range))
            }
        }
        return result
    }

    private static let phoneticCache = PhoneticCache()

    /// Speech recognition often writes a Chinese wake word with a homophone
    /// (喷/盆, 鹏/喷 in many accents). Han characters are compared by toneless
    /// pinyin with common accent mergers; other characters compare as themselves.
    static func phoneticKey(for character: Character) -> String {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1,
              (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value) else {
            return String(character)
        }
        if let cached = phoneticCache.value(for: character) { return cached }
        var pinyin = String(character).applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false)?
            .lowercased().filter(\.isLetter) ?? String(character)
        if pinyin.isEmpty { pinyin = String(character) }
        // Retroflex/flat initials and -ng/-n finals are routinely merged by speakers and ASR.
        for (from, to) in [("zh", "z"), ("ch", "c"), ("sh", "s")] where pinyin.hasPrefix(from) {
            pinyin = to + pinyin.dropFirst(from.count)
        }
        if pinyin.hasSuffix("eng") || pinyin.hasSuffix("ing") { pinyin.removeLast() }
        phoneticCache.store(pinyin, for: character)
        return pinyin
    }
}

private final class PhoneticCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Character: String] = [:]

    func value(for character: Character) -> String? { lock.withLock { values[character] } }
    func store(_ value: String, for character: Character) { lock.withLock { values[character] = value } }
}
