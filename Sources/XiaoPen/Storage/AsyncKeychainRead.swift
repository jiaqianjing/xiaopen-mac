import Foundation

enum AsyncKeychainRead {
    static func perform(timeout: TimeInterval,
                        operation: @escaping @Sendable () throws -> String?) async throws -> String? {
        guard timeout.isFinite, timeout > 0 else { throw KeychainHelper.ReadError.invalidTimeout }
        let waiter = KeychainReadWaiter()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let value: String? = try await withCheckedThrowingContinuation { continuation in
                guard waiter.register(continuation, timeout: timeout) else { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    guard waiter.isPending else { return }
                    waiter.finish(Result(catching: operation))
                }
            }
            try Task.checkCancellation()
            return value
        } onCancel: {
            waiter.finish(.failure(CancellationError()))
        }
    }
}

// A continuation has no child-task lifetime to join. The blocked OS query may outlive
// its caller; this waiter resumes once and discards any result arriving afterward.
private final class KeychainReadWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Error>?
    private var timeoutWork: DispatchWorkItem?
    private var isFinished = false
    private var earlyError: Error?

    var isPending: Bool { lock.withLock { !isFinished } }

    func register(_ continuation: CheckedContinuation<String?, Error>, timeout: TimeInterval) -> Bool {
        let work = DispatchWorkItem { [weak self] in
            self?.finish(.failure(KeychainHelper.ReadError.timedOut))
        }
        let cancelled: Error? = lock.withLock {
            guard !isFinished else { return earlyError ?? CancellationError() }
            self.continuation = continuation
            timeoutWork = work
            return nil
        }
        if let cancelled {
            continuation.resume(throwing: cancelled)
            return false
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout, execute: work)
        return true
    }

    func finish(_ result: Result<String?, Error>) {
        let waiting: (CheckedContinuation<String?, Error>?, DispatchWorkItem?)? = lock.withLock {
            guard !isFinished else { return nil }
            isFinished = true
            if continuation == nil, case .failure(let error) = result { earlyError = error }
            let waiting = (continuation, timeoutWork)
            continuation = nil
            timeoutWork = nil
            return waiting
        }
        guard let waiting else { return }
        waiting.1?.cancel()
        waiting.0?.resume(with: result)
    }
}
