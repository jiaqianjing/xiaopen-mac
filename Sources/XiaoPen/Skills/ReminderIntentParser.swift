import Foundation

public enum ReminderCommand: Equatable, Sendable {
    case create(fireDate: Date, message: String, isTimer: Bool)
    case list
    case cancel(all: Bool, keyword: String?)
}

public enum ReminderParseResult: Equatable, Sendable {
    case command(ReminderCommand)
    /// A reminder request without a time; the caller asks when and keeps the message.
    case needsTime(message: String)
    case noMatch
}

/// Recognizes direct reminder, timer and alarm requests in Chinese so they run
/// locally and instantly, without depending on a model's tool-calling support.
public enum ReminderIntentParser {
    /// `acceptsBareTime` lets a follow-up such as "十分钟后" or "再过五分钟"
    /// complete a pending reminder or snooze one that just fired.
    public static func parse(_ input: String, now: Date, calendar: Calendar = .current,
                             wakeWord: String = "", acceptsBareTime: Bool = false) -> ReminderParseResult {
        var text = normalize(input)
        guard !text.isEmpty, text.count <= 80,
              !text.contains(where: { "\"'“”‘’「」『』《》`".contains($0) }) else { return .noMatch }
        if !wakeWord.isEmpty, startsWithWakeWord(text, wakeWord: wakeWord),
           let query = WakeWordDetector.query(in: text, targetWakeWord: wakeWord, isEnabled: true) {
            text = normalize(query)
        }
        text = replacing("^(?:请你?|麻烦你?|帮我|帮忙|你)+", in: text)
        guard !text.isEmpty else { return .noMatch }

        if let cancel = cancelCommand(in: text) { return .command(cancel) }
        if matches(listPattern, text) { return .command(.list) }

        let hasTrigger = matches(triggerPattern, text)
        if let time = timeExpression(in: text, now: now, calendar: calendar) {
            let remainder = text.replacingCharacters(in: time.range, with: "")
            if hasTrigger {
                let message = extractMessage(from: remainder)
                let isTimer = time.isRelative && (message.isEmpty || matches("计时|倒计时|定时", text))
                return .command(.create(fireDate: time.fireDate, message: message, isTimer: isTimer))
            }
            if acceptsBareTime {
                let rest = replacing("(?:提醒|再|吧|的|就|在|大概|左右|好|好的|那|那就|嗯|我|叫|喊|一下|以后|之后|后)", in: remainder)
                if rest.count <= 4 {
                    return .command(.create(fireDate: time.fireDate, message: "", isTimer: time.isRelative))
                }
            }
            return .noMatch
        }

        // Only a request that starts like a reminder asks for a time; questions stay with the model.
        guard matches("^(?:提醒我|提醒一下我?|叫我|喊我|(?:定|设|设置|订)(?:一)?个?(?:闹钟|定时器?|计时器?|提醒))", text) else {
            return .noMatch
        }
        let message = extractMessage(from: text)
        guard message.count <= 16, !matches("怎么|什么|为什么|如何|吗|呢|？|\\?|哪", message) else { return .noMatch }
        return .needsTime(message: message)
    }

    // MARK: - Commands

    private static let reminderNoun = "(?:提醒|闹钟|定时器|定时|计时器|计时|倒计时)"
    private static let triggerPattern =
        "提醒一下我|提醒我|提醒一下|叫我|喊我|通知我|(?:定|设|设置|订)(?:一)?个?(?:闹钟|定时器?|计时器?|提醒)|倒计时|计时"
    private static let listPattern =
        "^(?:我|现在|目前)?(?:还)?(?:有|有没有)(?:哪些|什么|几个|多少个?)?\(reminderNoun)(?:吗|呢|啊)?$"
        + "|^(?:查看|查一下|查查|看看|看一下|列出|说说|告诉我)(?:一下)?(?:我的|现在的|所有的?|全部的?)*\(reminderNoun)(?:吧|呢)?$"
        + "|^(?:我的|现在的)?\(reminderNoun)(?:有哪些|有什么|有几个|列表)(?:吗|呢)?$"

    private static func cancelCommand(in text: String) -> ReminderCommand? {
        if let groups = captures("^(?:不用|不要|别|无需|不需要)(?:再)?(?:提醒|叫|喊)(?:我)?(?:了)?(.*)$", in: text) {
            return .cancel(all: false, keyword: keyword(from: groups[0]))
        }
        let verb = "(?:取消|删掉|删除|关掉|关闭|停掉|停止|撤销|清空|去掉)(?:掉)?"
        if let groups = captures("^\(verb)(?:我的)?(所有|全部)?(?:的)?(.*?)\(reminderNoun)(?:吧|吗)?$", in: text) {
            let all = !groups[0].isEmpty || text.hasPrefix("清空")
            return .cancel(all: all, keyword: all ? nil : keyword(from: groups[1]))
        }
        if let groups = captures("^(?:把|将)(所有|全部)?(?:的)?(.*?)\(reminderNoun)(?:都|全)?(?:给我)?\(verb)(?:吧)?$", in: text) {
            let all = !groups[0].isEmpty
            return .cancel(all: all, keyword: all ? nil : keyword(from: groups[1]))
        }
        return nil
    }

    private static func keyword(from value: String) -> String? {
        let cleaned = replacing("^(?:那个|这个|刚才|刚刚|刚才的|一个|个|最后)+|的$", in: value)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func extractMessage(from text: String) -> String {
        var candidate = text
        if let range = candidate.range(of: "(?:提醒一下我|提醒我|提醒一下|叫我|喊我|通知我)", options: .regularExpression) {
            let after = String(candidate[range.upperBound...])
            candidate = cleanMessage(after).isEmpty ? String(candidate[..<range.lowerBound]) : after
        }
        return cleanMessage(candidate)
    }

    private static func cleanMessage(_ value: String) -> String {
        var text = value
        text = replacing("倒计时|计时器?|闹钟|定时器?", in: text)
        text = replacing("^(?:定|设|设置|订)(?:一)?个?的?(?:提醒)?|(?:定|设|设置|订)(?:一)?个?(?:提醒)?$", in: text)
        text = replacing("记得要?|别忘了|不要忘了|到时候|到时|的话|一下", in: text)
        text = replacing("^[，,、的要去该在我得]+", in: text)
        text = replacing("^(?:我要|我得|我该)", in: text)
        text = replacing("[，,、的吧哦啊呀噢哈]+$", in: text)
        return text
    }

    // MARK: - Time

    struct TimeExpression {
        let fireDate: Date
        let range: Range<String.Index>
        let isRelative: Bool
    }

    private static let number = "([0-9]+|[零〇一二两三四五六七八九十百]+)"

    static func timeExpression(in text: String, now: Date, calendar: Calendar) -> TimeExpression? {
        absoluteTime(in: text, now: now, calendar: calendar) ?? relativeTime(in: text, now: now)
    }

    private static func relativeTime(in text: String, now: Date) -> TimeExpression? {
        let suffix = "(?:以后|之后|后)?"
        let prefix = "(?:再过|过)?"
        var best: (seconds: Int, range: Range<String.Index>)?
        func consider(_ seconds: Int?, _ range: Range<String.Index>) {
            guard let seconds, seconds > 0, seconds <= 7 * 24 * 3600, best == nil else { return }
            best = (seconds, range)
        }
        if let match = firstMatch("\(prefix)\(number)(?:个)?(半)?(?:小时|钟头)(半)?(?:\(number)分(?:钟)?)?\(suffix)", in: text) {
            let hours = ChineseNumber.parse(match.groups[0]) ?? 0
            let half = !match.groups[1].isEmpty || !match.groups[2].isEmpty
            let minutes = ChineseNumber.parse(match.groups[3]) ?? 0
            consider(hours * 3600 + (half ? 1800 : 0) + minutes * 60, match.range)
        }
        if let match = firstMatch("\(prefix)半(?:个)?(?:小时|钟头)\(suffix)", in: text) {
            consider(1800, match.range)
        }
        if let match = firstMatch("\(prefix)\(number)?刻钟\(suffix)", in: text) {
            consider((ChineseNumber.parse(match.groups[0]) ?? 1) * 900, match.range)
        }
        if let match = firstMatch("\(prefix)\(number)分(半)?(钟)?(半)?\(suffix)", in: text) {
            // A bare "分" is a clock minute ("3点10分") unless it reads as a duration.
            let value = String(text[match.range])
            if !match.groups[2].isEmpty || value.hasSuffix("后") || value.hasPrefix("过") || value.hasPrefix("再过") {
                let half = !match.groups[1].isEmpty || !match.groups[3].isEmpty
                consider((ChineseNumber.parse(match.groups[0]) ?? 0) * 60 + (half ? 30 : 0), match.range)
            }
        }
        if let match = firstMatch("\(prefix)\(number)秒(?:钟)?\(suffix)", in: text) {
            consider(ChineseNumber.parse(match.groups[0]), match.range)
        }
        guard let best else { return nil }
        return TimeExpression(fireDate: now.addingTimeInterval(TimeInterval(best.seconds)), range: best.range, isRelative: true)
    }

    private static func absoluteTime(in text: String, now: Date, calendar: Calendar) -> TimeExpression? {
        let day = "(今天|今晚|明天|明早|明晚|后天|大后天)?(?:(下)?(?:个)?(?:周|星期|礼拜)([一二三四五六日天1-7]))?"
        let period = "(凌晨|早上|早晨|清晨|上午|中午|下午|傍晚|晚上|夜里|夜间)?"
        let pattern = "\(day)(?:的)?\(period)\(number)(?:点|:|时)(?:钟)?(?:([0-9]{1,2}|[零〇一二三四五六七八九十]+)(?:分)?|(半)|(一刻)|(三刻)|(整))?"
        guard let match = firstMatch(pattern, in: text),
              var hour = ChineseNumber.parse(match.groups[4]) else { return nil }
        let dayWord = match.groups[0]
        let weekdayWord = match.groups[2]
        var periodWord = match.groups[3]
        let hasMinutePart = match.groups[5...9].contains { !$0.isEmpty }
        // "大一点" / "早一点" are not 1 o'clock.
        if match.groups[4] == "一", dayWord.isEmpty, weekdayWord.isEmpty, periodWord.isEmpty, !hasMinutePart { return nil }
        var minute = 0
        if !match.groups[5].isEmpty { minute = ChineseNumber.parse(match.groups[5]) ?? -1 }
        if !match.groups[6].isEmpty { minute = 30 }
        if !match.groups[7].isEmpty { minute = 15 }
        if !match.groups[8].isEmpty { minute = 45 }
        if periodWord.isEmpty {
            if dayWord == "今晚" || dayWord == "明晚" { periodWord = "晚上" }
            if dayWord == "明早" { periodWord = "早上" }
        }
        guard (0...24).contains(hour), (0...59).contains(minute) else { return nil }

        var extraDays = 0
        switch periodWord {
        case "下午", "傍晚", "晚上", "夜里", "夜间":
            if hour < 12 { hour += 12 } else if hour == 12, periodWord != "下午" { hour = 0; extraDays = 1 }
        case "中午":
            if hour < 11 { hour += 12 }
        case "凌晨":
            if hour == 12 { hour = 0 }
        default:
            break
        }
        if hour == 24 { hour = 0; extraDays += 1 }

        let today = calendar.startOfDay(for: now)
        func date(dayOffset: Int, hour: Int) -> Date? {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: today) else { return nil }
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
        }

        let fireDate: Date?
        if !weekdayWord.isEmpty {
            let target = ["一": 0, "二": 1, "三": 2, "四": 3, "五": 4, "六": 5, "日": 6, "天": 6,
                          "1": 0, "2": 1, "3": 2, "4": 3, "5": 4, "6": 5, "7": 6][weekdayWord] ?? 0
            let current = (calendar.component(.weekday, from: now) + 5) % 7
            var offset = match.groups[1].isEmpty ? target - current : 7 - current + target
            if offset < 0 { offset += 7 }
            if periodWord.isEmpty, (1...5).contains(hour) { hour += 12 }
            var candidate = date(dayOffset: offset + extraDays, hour: hour)
            if let value = candidate, value <= now { candidate = date(dayOffset: offset + 7 + extraDays, hour: hour) }
            fireDate = candidate
        } else if !dayWord.isEmpty {
            let offset = ["今天": 0, "今晚": 0, "明天": 1, "明早": 1, "明晚": 1, "后天": 2, "大后天": 3][dayWord] ?? 0
            if periodWord.isEmpty, offset > 0, (1...5).contains(hour) { hour += 12 }
            var candidate = date(dayOffset: offset + extraDays, hour: hour)
            if offset == 0, periodWord.isEmpty, let value = candidate, value <= now, hour < 12 {
                candidate = date(dayOffset: extraDays, hour: hour + 12)
            }
            fireDate = candidate
        } else if !periodWord.isEmpty {
            var candidate = date(dayOffset: extraDays, hour: hour)
            if let value = candidate, value <= now { candidate = date(dayOffset: 1 + extraDays, hour: hour) }
            fireDate = candidate
        } else {
            // "8点" means the next 8 o'clock, morning or evening.
            let options = [date(dayOffset: 0, hour: hour), hour < 12 ? date(dayOffset: 0, hour: hour + 12) : nil,
                           date(dayOffset: 1, hour: hour)]
            fireDate = options.compactMap { $0 }.first { $0 > now }
        }
        guard let fireDate, fireDate > now else { return nil }
        return TimeExpression(fireDate: fireDate, range: match.range, isRelative: false)
    }

    // MARK: - Text helpers

    private static func normalize(_ input: String) -> String {
        var text = input.folding(options: [.widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        text = text.filter { !$0.isWhitespace }
        text = text.replacingOccurrences(of: "：", with: ":")
        return text.trimmingCharacters(in: CharacterSet(charactersIn: "，。？！,.?!~～"))
    }

    private static func startsWithWakeWord(_ text: String, wakeWord: String) -> Bool {
        let letters: (String) -> String = { value in
            value.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .filter { $0.isLetter || $0.isNumber }
        }
        let phrase = letters(wakeWord)
        return !phrase.isEmpty && letters(text).hasPrefix(phrase)
    }

    private struct Match {
        let range: Range<String.Index>
        let groups: [String]
    }

    private static func firstMatch(_ pattern: String, in text: String) -> Match? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(result.range, in: text), !range.isEmpty else { return nil }
        let groups = (1..<result.numberOfRanges).map { index -> String in
            Range(result.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
        return Match(range: range, groups: groups)
    }

    private static func captures(_ pattern: String, in text: String) -> [String]? {
        firstMatch(pattern, in: text)?.groups
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func replacing(_ pattern: String, in text: String) -> String {
        text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
}

enum ChineseNumber {
    /// Parses Arabic digits or simple Chinese numerals such as 十五, 二十, 两, 一百零五.
    static func parse(_ text: String) -> Int? {
        if let value = Int(text) { return value }
        guard !text.isEmpty else { return nil }
        let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
                                        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        let units: [Character: Int] = ["十": 10, "百": 100]
        var total = 0
        var current = 0
        for character in text {
            if let digit = digits[character] {
                current = digit
            } else if let unit = units[character] {
                total += (current == 0 ? 1 : current) * unit
                current = 0
            } else {
                return nil
            }
        }
        return total + current
    }
}
