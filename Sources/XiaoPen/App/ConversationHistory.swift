import Foundation

/// Completed turns only; kept in memory and bounded before the next model request.
struct ConversationHistory {
    private var turns: [(user: String, assistant: String)] = []
    private let maximumTurns: Int
    private let maximumCharacters: Int

    init(maximumTurns: Int = 6, maximumCharacters: Int = 12_000) {
        self.maximumTurns = max(0, maximumTurns)
        self.maximumCharacters = max(0, maximumCharacters)
    }

    func messages(adding user: String) -> [ChatMessage] {
        turns.flatMap {
            [ChatMessage(role: "user", content: $0.user), ChatMessage(role: "assistant", content: $0.assistant)]
        } + [ChatMessage(role: "user", content: user)]
    }

    mutating func record(user: String, assistant: String) {
        guard !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !assistant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        turns.append((user, assistant))
        while turns.count > maximumTurns || turns.reduce(0, { $0 + $1.user.count + $1.assistant.count }) > maximumCharacters {
            turns.removeFirst()
        }
    }

    mutating func clear() { turns.removeAll() }
}
