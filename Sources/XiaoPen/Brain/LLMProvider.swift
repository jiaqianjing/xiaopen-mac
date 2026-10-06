import Foundation

public struct ChatMessage: Codable, Sendable {
    public let role: String
    public let content: String
    
    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public protocol LLMProviderProtocol: Sendable {
    func streamChat(messages: [ChatMessage], systemPrompt: String) async throws -> AsyncThrowingStream<String, Error>
    func testConnection() async throws -> Bool
}
