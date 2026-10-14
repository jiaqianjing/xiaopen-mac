import Foundation
import OSLog

/// Keeps the Mac out of idle system sleep while XiaoPen waits for the wake word.
/// The display may still turn off and the screen may lock; only system sleep,
/// which stops the microphone, is held off. No permission or system setting is needed.
@MainActor
final class SystemSleepGuard {
    static let shared = SystemSleepGuard()

    private let begin: () -> NSObjectProtocol
    private let end: (NSObjectProtocol) -> Void
    private var activity: NSObjectProtocol?
    private let logger = Logger(subsystem: "com.jiaqianjing.XiaoPen", category: "power")

    var isActive: Bool { activity != nil }

    init(begin: @escaping () -> NSObjectProtocol = {
             ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled,
                                                   reason: "Listening for the wake word")
         },
         end: @escaping (NSObjectProtocol) -> Void = { ProcessInfo.processInfo.endActivity($0) }) {
        self.begin = begin
        self.end = end
    }

    func setActive(_ active: Bool) {
        if active {
            guard activity == nil else { return }
            activity = begin()
            logger.notice("待命时阻止系统睡眠")
        } else if let activity {
            end(activity)
            self.activity = nil
            logger.notice("允许系统睡眠")
        }
    }
}
