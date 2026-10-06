import Foundation

public final class OllamaProvider: LLMProviderProtocol {
    private let baseURL: String
    private let model: String
    
    public init(baseURL: String, model: String) {
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.model = model
    }
    
    public func streamChat(messages: [ChatMessage], systemPrompt: String) async throws -> AsyncThrowingStream<String, Error> {
        guard let url = URL(string: "\(baseURL)/api/chat") else {
            throw URLError(.badURL)
        }
        
        var allMessages: [ChatMessage] = []
        if !systemPrompt.isEmpty {
            allMessages.append(ChatMessage(role: "system", content: systemPrompt))
        }
        allMessages.append(contentsOf: messages)
        
        let payload: [String: Any] = [
            "model": model,
            "messages": allMessages.map { ["role": $0.role, "content": $0.content] },
            "stream": true
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await line in bytes.lines {
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }
                        
                        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let message = json["message"] as? [String: Any],
                           let content = message["content"] as? String {
                            continuation.yield(content)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    public func testConnection() async throws -> Bool {
        guard let url = URL(string: "\(baseURL)/api/tags") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4.0
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}
