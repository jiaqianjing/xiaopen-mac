import Foundation

/// Facts the model cannot know on its own. They are attached to the newest user
/// message for the request only: the system prompt and earlier turns stay
/// byte-identical, so platforms with prefix caching can reuse them.
enum AssistantContext {
    static func timeLine(now: Date, calendar: Calendar = .current, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy年M月d日 EEEE HH:mm"
        return "当前时间：\(formatter.string(from: now))（\(timeZone.identifier)）"
    }

    static func decorate(_ userText: String, now: Date, city: String, extra: [String]) -> String {
        var lines = [timeLine(now: now)]
        let city = city.trimmingCharacters(in: .whitespacesAndNewlines)
        if !city.isEmpty { lines.append("用户所在城市：\(city)") }
        lines += extra.filter { !$0.isEmpty }
        return "<背景信息，仅供回答参考，不要复述这段说明>\n\(lines.joined(separator: "\n"))\n</背景信息>\n\(userText)"
    }

    /// Voice replies are read aloud, and local actions must never be claimed by the model.
    static let systemPromptSuffix = """

    你的回答会被直接朗读：不要使用 Markdown、列表符号、表格或表情符号，数字和单位用口语表达，尽量一两句话说完。
    系统音量、定时提醒和闹钟由应用在本机直接执行并确认。到达你这里的请求都没有匹配本机操作，所以不要声称已经调整音量、设置提醒或执行了其他操作。
    用户想设置提醒时，可以示例：十分钟后提醒我关火、明天早上八点叫我起床、取消所有提醒。用户想调音量时，可以示例：音量调到40%、静音。
    如果背景信息里有实时天气数据，请据此简短回答并给出实用建议，不要编造数据；没有数据时不要猜测天气。
    """
}
