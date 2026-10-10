import Foundation
import Observation
import AppKit
import UserNotifications
import OSLog

public struct Reminder: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let fireDate: Date
    public let message: String
    public let isTimer: Bool
    public let createdAt: Date

    public init(id: UUID = UUID(), fireDate: Date, message: String, isTimer: Bool, createdAt: Date = Date()) {
        self.id = id
        self.fireDate = fireDate
        self.message = message
        self.isTimer = isTimer
        self.createdAt = createdAt
    }
}

/// Pending reminders survive restarts. Reminders that came due while the app was
/// not running fire on the next launch, so nothing is silently lost.
@Observable
@MainActor
public final class ReminderStore {
    public static let shared = ReminderStore(fileURL: ReminderStore.defaultFileURL)

    public private(set) var reminders: [Reminder] = []
    /// The latest reminder that fired, so "再过五分钟" can snooze it.
    public private(set) var lastFired: (reminder: Reminder, at: Date)?
    @ObservationIgnored public var onFire: ((Reminder) -> Void)?
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private let logger = Logger(subsystem: "com.jiaqianjing.XiaoPen", category: "reminders")

    init(fileURL: URL?, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
    }

    static var defaultFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("XiaoPen", isDirectory: true)
            .appendingPathComponent("reminders.json")
    }

    public func start() {
        guard !isStarted else { return }
        isStarted = true
        load()
        let workspace = NSWorkspace.shared.notificationCenter
        // Timers do not fire during sleep; re-check due reminders on wake and clock changes.
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reschedule() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reschedule() }
        })
        reschedule()
    }

    @discardableResult
    public func add(fireDate: Date, message: String, isTimer: Bool) -> Reminder {
        let reminder = Reminder(fireDate: fireDate, message: message, isTimer: isTimer, createdAt: now())
        reminders.append(reminder)
        reminders.sort { $0.fireDate < $1.fireDate }
        save()
        ReminderNotifications.schedule(reminder)
        reschedule()
        return reminder
    }

    @discardableResult
    public func remove(_ reminder: Reminder) -> Bool {
        guard let index = reminders.firstIndex(where: { $0.id == reminder.id }) else { return false }
        reminders.remove(at: index)
        ReminderNotifications.cancel([reminder.id])
        save()
        reschedule()
        return true
    }

    @discardableResult
    public func removeAll() -> Int {
        let count = reminders.count
        ReminderNotifications.cancel(reminders.map(\.id))
        reminders.removeAll()
        save()
        reschedule()
        return count
    }

    /// The reminder a vague "取消提醒" most likely means: a keyword match, else the newest one.
    public func cancellationTarget(keyword: String?) -> Reminder? {
        if let keyword, !keyword.isEmpty {
            return reminders.last { $0.message.contains(keyword) || keyword.contains($0.message) && !$0.message.isEmpty }
        }
        return reminders.max { $0.createdAt < $1.createdAt }
    }

    /// Message of a reminder that fired within `window`, used when snoozing by voice.
    public func recentlyFiredMessage(within window: TimeInterval = 180) -> String? {
        guard let lastFired, now().timeIntervalSince(lastFired.at) <= window else { return nil }
        return lastFired.reminder.message
    }

    func reschedule() {
        timer?.invalidate()
        timer = nil
        fireDueReminders()
        guard let next = reminders.first else { return }
        let interval = max(0.2, next.fireDate.timeIntervalSince(now()))
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reschedule() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func fireDueReminders() {
        let current = now()
        let due = reminders.filter { $0.fireDate <= current.addingTimeInterval(0.3) }
        guard !due.isEmpty else { return }
        reminders.removeAll { reminder in due.contains { $0.id == reminder.id } }
        save()
        for reminder in due {
            logger.notice("提醒到期：late=\(current.timeIntervalSince(reminder.fireDate))")
            lastFired = (reminder, current)
            onFire?(reminder)
        }
    }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        do {
            reminders = try JSONDecoder().decode([Reminder].self, from: data).sorted { $0.fireDate < $1.fireDate }
        } catch {
            logger.error("提醒文件无法读取：\(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(reminders).write(to: fileURL, options: .atomic)
        } catch {
            logger.error("提醒保存失败：\(error.localizedDescription, privacy: .public)")
        }
    }
}

/// System notifications let a reminder reach the user even while the Mac is muted
/// or the user is away from the speaker. They need a real app bundle.
enum ReminderNotifications {
    private static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    static func schedule(_ reminder: Reminder) {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = reminder.isTimer ? "小喷 · 计时结束" : "小喷 · 提醒"
            content.body = ReminderFormatter.announcementTitle(for: reminder)
            content.sound = nil
            let interval = max(1, reminder.fireDate.timeIntervalSinceNow)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: reminder.id.uuidString, content: content, trigger: trigger))
        }
    }

    static func cancel(_ identifiers: [UUID]) {
        guard isAvailable, !identifiers.isEmpty else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers.map(\.uuidString))
    }
}

enum ReminderFormatter {
    static func announcementTitle(for reminder: Reminder) -> String {
        if reminder.message.isEmpty { return reminder.isTimer ? "计时结束" : "时间到了" }
        return reminder.message
    }

    /// Spoken when a reminder fires.
    static func announcement(for reminder: Reminder, now: Date) -> String {
        let late = now.timeIntervalSince(reminder.fireDate) > 120
        let missed = late ? "（原定\(spokenTime(reminder.fireDate, now: reminder.fireDate))，刚才没能准时提醒）" : ""
        if reminder.message.isEmpty {
            return reminder.isTimer ? "时间到！计时结束了。\(missed)" : "时间到了。\(missed)"
        }
        return "提醒你：\(reminder.message)。\(missed)"
    }

    static func confirmation(for reminder: Reminder, now: Date) -> String {
        let seconds = Int(reminder.fireDate.timeIntervalSince(now).rounded())
        let what = reminder.message.isEmpty ? "叫你" : "提醒你\(reminder.message)"
        if reminder.isTimer || seconds < 3600 {
            return "好的，\(spokenDuration(seconds))后\(what)。"
        }
        return "好的，\(spokenTime(reminder.fireDate, now: now))\(what)。"
    }

    static func listing(_ reminders: [Reminder], now: Date) -> String {
        guard !reminders.isEmpty else { return "现在没有待办的提醒。" }
        let items = reminders.prefix(5).map { reminder in
            "\(spokenTime(reminder.fireDate, now: now))，\(announcementTitle(for: reminder))"
        }
        let more = reminders.count > 5 ? "，还有\(reminders.count - 5)个" : ""
        return "你有\(reminders.count)个提醒：\(items.joined(separator: "；"))\(more)。"
    }

    static func spokenDuration(_ seconds: Int) -> String {
        let seconds = max(1, seconds)
        if seconds < 60 { return "\(seconds)秒" }
        let minutes = Int((Double(seconds) / 60).rounded())
        if minutes < 60 { return "\(minutes)分钟" }
        let hours = minutes / 60
        let rest = minutes % 60
        if rest == 0 { return "\(hours)小时" }
        if rest == 30 { return "\(hours)个半小时" }
        return "\(hours)小时\(rest)分钟"
    }

    /// "今天下午3点半", "明天早上8点", "10月12日晚上9点15分".
    static func spokenTime(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        let dayLabel: String
        switch days {
        case 0: dayLabel = "今天"
        case 1: dayLabel = "明天"
        case 2: dayLabel = "后天"
        default:
            let components = calendar.dateComponents([.month, .day], from: date)
            dayLabel = "\(components.month ?? 0)月\(components.day ?? 0)日"
        }
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        let period: String
        switch hour {
        case 0..<5: period = "凌晨"
        case 5..<9: period = "早上"
        case 9..<12: period = "上午"
        case 12..<13: period = "中午"
        case 13..<18: period = "下午"
        default: period = "晚上"
        }
        let displayHour = hour > 12 ? hour - 12 : (hour == 0 ? 12 : hour)
        let minuteText = minute == 0 ? "" : (minute == 30 ? "半" : "\(minute)分")
        return "\(dayLabel)\(period)\(displayHour)点\(minuteText)"
    }
}
