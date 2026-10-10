import Foundation

public enum SystemVolumeCommand: Equatable, Sendable {
    case setPercent(Int)
    case adjustPercent(Int)
    case setMuted(Bool)
    case query
}

public enum SystemVolumeParseResult: Equatable, Sendable {
    case command(SystemVolumeCommand)
    case invalidIntent(String)
    case noMatch
}

/// Recognizes only complete, direct requests from the user's input.
/// Wake phrases belong to the caller, which knows the user's configured phrase.
public enum SystemVolumeIntentParser {
    /// Text input may include the configured wake phrase. Only a phrase at the
    /// beginning is eligible; quoted or reported speech never strips a prefix.
    public static func parse(_ input: String, wakeWord: String) -> SystemVolumeParseResult {
        let direct = parse(input)
        guard direct == .noMatch,
              !input.contains(where: { "\"'“”‘’「」『』《》`".contains($0) }),
              wakePrefixMatches(input, phrase: wakeWord),
              let query = WakeWordDetector.query(in: input, targetWakeWord: wakeWord, isEnabled: true) else {
            return direct
        }
        return parse(query)
    }

    public static func parse(_ input: String) -> SystemVolumeParseResult {
        var text = input.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        // Quoted commands are descriptions, not permission to change a device.
        guard !text.contains(where: { "\"'“”‘’「」『』《》`".contains($0) }) else { return .noMatch }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "，。？！,.?!")))
        text = text.filter { !$0.isWhitespace }
        guard !text.isEmpty, text.count <= 160 else { return .noMatch }

        text = replacingFirst(pattern: "^(?:请帮我|请|麻烦你帮我|麻烦帮我|麻烦你|麻烦|帮我|帮忙)", in: text)
        text = replacingFirst(pattern: "(?:谢谢|好吗|好么|可以吗|行吗|吧)$", in: text)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "，。？！,.?!"))

        if matches("^(?:查询|查看|查一下|查|告诉我)?(?:当前|现在)?(?:的)?\(subject)(?:现在|当前)?(?:是多少|有多少|多少|多大|大小)?$", text) ||
            matches("^(?:现在|当前)?(?:系统|电脑|扬声器)?(?:有|是)?静音(?:了吗|了没|吗|没有)$", text) ||
            matches("^(?:whatisthe(?:current)?volume|what(?:'s|is)thevolume|currentvolume|checkvolume)$", text) {
            return .command(.query)
        }

        if matches("^(?:把|将)?(?:\(subject)|系统|电脑|扬声器)?(?:取消静音|解除静音|关闭静音|恢复声音|恢复音量|打开声音)(?:一下)?$", text) ||
            matches("^(?:取消|解除|关闭)(?:\(subject)(?:的)?)?静音(?:一下)?$", text) ||
            matches("^unmute(?:the)?(?:volume|speakers)?$", text) {
            return .command(.setMuted(false))
        }
        if matches("^(?:把|将)?(?:\(subject)|系统|电脑|扬声器)?(?:设为静音|设置为静音|调成静音|静音|关闭声音)(?:一下)?$", text) ||
            matches("^(?:开启|打开)(?:\(subject)(?:的)?)?静音(?:一下)?$", text) ||
            matches("^mute(?:the)?(?:volume|speakers)?$", text) {
            return .command(.setMuted(true))
        }

        if let number = capturedNumber(in: text, patterns: [
            "^(?:把|将)?\(subject)(?:调到|调至|调成|设为|设到|设置为|设置到|设置成|改为|改成|调整到|调整为)\(operand)(?:一下)?$",
            "^set(?:the)?volume(?:to|at)\(operand)$"
        ]) {
            return commandWithNumber(number, adjustmentSign: nil)
        }

        for (direction, sign) in [(increase, 1), (decrease, -1)] {
            // “大一点” means the default step, not one percentage point.
            if matches("^(?:把|将)?\(subject)\(direction)(?:一点|一些|点|些|一档|一格|一下)?(?:儿)?$", text) ||
                matches("^\(direction)\(subject)(?:一点|一些|点|些|一档|一格|一下)?(?:儿)?$", text) ||
                matches("^\(sign > 0 ? "大" : "小")(?:点声|一点声|声一点|声点)(?:儿)?$", text) ||
                matches("^turn(?:the)?volume\(sign > 0 ? "up" : "down")$", text) ||
                matches("^volume\(sign > 0 ? "up" : "down")$", text) {
                return .command(.adjustPercent(sign * 10))
            }
            if let number = capturedNumber(in: text, patterns: [
                "^(?:把|将)?\(subject)\(direction)(?:了)?\(operand)(?:一下)?$",
                "^\(direction)\(subject)(?:了)?\(operand)(?:一下)?$",
                "^\(sign > 0 ? "increase" : "decrease")(?:the)?volumeby\(operand)$"
            ]) {
                return commandWithNumber(number, adjustmentSign: sign)
            }
        }
        return .noMatch
    }

    private static let subject = "(?:(?:系统|电脑|扬声器)(?:的)?)?(?:音量|声音)"
    private static let increase = "(?:调大|调高|提高|增大|加大|增高|增加|大|高|往上调)"
    private static let decrease = "(?:调小|调低|降低|减小|减低|减弱|减少|小|低|往下调)"
    private static let number = "(?:[-+负正])?[0-9零〇○一二两三四五六七八九十百千万亿]+(?:[.点][0-9零〇○一二两三四五六七八九]+)?"
    private static let operand = "((?:负?百分之)?\(number)(?:%|个百分点|百分点|个点|点|percent|percentagepoints)?)"

    private static func commandWithNumber(_ operand: String, adjustmentSign: Int?) -> SystemVolumeParseResult {
        var number = operand
        for suffix in ["percentagepoints", "个百分点", "百分点", "percent", "个点", "%", "点"] where number.hasSuffix(suffix) {
            number.removeLast(suffix.count)
            break
        }
        if number.hasPrefix("负百分之") {
            number = "负" + number.dropFirst("负百分之".count)
        } else if number.hasPrefix("百分之") {
            number.removeFirst("百分之".count)
        }

        guard let value = integerValue(number) else {
            return .invalidIntent("音量请用 0 到 100 的整数百分比，例如“音量调到百分之四十”。")
        }
        guard (0...100).contains(value) else {
            return .invalidIntent("音量百分比必须在 0 到 100 之间。")
        }
        if let adjustmentSign {
            return .command(.adjustPercent(adjustmentSign * value))
        }
        return .command(.setPercent(value))
    }

    private static func integerValue(_ source: String) -> Int? {
        var text = source
        var sign = 1
        if let first = text.first, "-负+正".contains(first) {
            sign = "-负".contains(first) ? -1 : 1
            text.removeFirst()
        }
        guard !text.isEmpty else { return nil }
        if text.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }) {
            return Int(text).flatMap { $0.multipliedReportingOverflow(by: sign).overflow ? nil : $0 * sign }
        }

        let digits: [Character: Int] = ["零": 0, "〇": 0, "○": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        if text.allSatisfy({ digits[$0] != nil }) {
            var value = 0
            for character in text {
                let product = value.multipliedReportingOverflow(by: 10)
                guard !product.overflow, let digit = digits[character] else { return nil }
                let sum = product.partialValue.addingReportingOverflow(digit)
                guard !sum.overflow else { return nil }
                value = sum.partialValue
            }
            return value * sign
        }

        // Canonical Chinese integer forms; ambiguous colloquial forms such as
        // “一百二” are rejected instead of guessing whether they mean 102 or 120.
        if text == "十" { return sign * 10 }
        if matches("^[一二两三四五六七八九]?十[一二两三四五六七八九]?$", text) {
            let parts = text.split(separator: "十", omittingEmptySubsequences: false)
            let tens = parts[0].first.flatMap { digits[$0] } ?? 1
            let ones = parts[1].first.flatMap { digits[$0] } ?? 0
            return sign * (tens * 10 + ones)
        }
        if text == "一百" { return sign * 100 }
        // These forms are definitely out of range, even though the full value
        // is unnecessary for deciding a 0–100 percent operation.
        if matches("^[一二两三四五六七八九]百(?:零?[一二两三四五六七八九]|[一二两三四五六七八九]?十[一二两三四五六七八九]?)?$", text) ||
            matches("^[一二两三四五六七八九]千(?:.*)$", text) ||
            matches("^[一二两三四五六七八九十百千]+[万亿](?:.*)$", text) {
            return sign * 101
        }
        return nil
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func capturedNumber(in text: String, patterns: [String]) -> String? {
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: fullRange),
                  let range = Range(match.range(at: 1), in: text) else { continue }
            return String(text[range])
        }
        return nil
    }

    private static func replacingFirst(pattern: String, in text: String) -> String {
        guard let range = text.range(of: pattern, options: .regularExpression) else { return text }
        return text.replacingCharacters(in: range, with: "")
    }

    private static func wakePrefixMatches(_ input: String, phrase: String) -> Bool {
        let target = phrase.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { $0.isLetter || $0.isNumber }
        guard !target.isEmpty, input.count <= 160 else { return false }

        var source: [(character: Character, range: Range<String.Index>)] = []
        for index in input.indices {
            let range = index..<input.index(after: index)
            let folded = String(input[index]).folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            for character in folded where character.isLetter || character.isNumber {
                source.append((character, range))
            }
        }
        guard source.count >= target.count,
              String(source.prefix(target.count).map(\.character)) == target else { return false }
        // Case folding can expand a character. The prefix must end at its full
        // original boundary, just as WakeWordDetector requires.
        if source.count > target.count, source[target.count - 1].range == source[target.count].range {
            return false
        }
        let end = source[target.count - 1].range.upperBound
        if let last = target.last, isLatinLetterOrNumber(last), end < input.endIndex,
           isLatinLetterOrNumber(input[end]) {
            return false
        }
        return true
    }

    private static func isLatinLetterOrNumber(_ character: Character) -> Bool {
        let folded = String(character).folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return folded.unicodeScalars.allSatisfy { (97...122).contains($0.value) || (48...57).contains($0.value) }
    }
}
