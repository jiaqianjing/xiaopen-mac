import Foundation

/// Invalidated identifiers can never finish or update a newer audio session.
struct AudioSessionLifecycle: Sendable {
    private(set) var currentID: UUID?

    mutating func begin() -> UUID {
        let identifier = UUID()
        currentID = identifier
        return identifier
    }

    mutating func invalidate() {
        currentID = nil
    }

    func isCurrent(_ identifier: UUID) -> Bool {
        currentID == identifier
    }

    @discardableResult
    mutating func complete(_ identifier: UUID) -> Bool {
        guard isCurrent(identifier) else { return false }
        invalidate()
        return true
    }
}

/// Retry delays remain bounded without retrying failed services in a tight loop.
struct AudioRecoveryBackoff: Sendable {
    private let initialDelay: TimeInterval
    private let maximumDelay: TimeInterval
    private var next: TimeInterval

    init(initialDelay: TimeInterval = 1, maximumDelay: TimeInterval = 15) {
        precondition(initialDelay > 0 && maximumDelay >= initialDelay)
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
        self.next = initialDelay
    }

    mutating func nextDelay() -> TimeInterval {
        let delay = next
        next = min(next * 2, maximumDelay)
        return delay
    }

    mutating func reset() {
        next = initialDelay
    }
}
