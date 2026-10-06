import Foundation

public final class AnthropicProvider: LLMProviderProtocol {
    private let apiKey: String
    private let model: String
    
    public init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
    }
    
    public func streamChat(messages: [ChatMessage], systemPrompt: String) async throws -> AsyncThrowingStream<String, Error> {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw URLError(.badURL)
        }
        
        let filteredMessages = messages.filter { $0.role != "system" }
        let payload: [String: Any] = [
            "model": model,
            "max_tokens": 600,
            "system": systemPrompt,
            "messages": filteredMessages.map { ["role": $0.role, "content": $0.content] },
            "stream": true
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let jsonString = String(line.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !jsonString.isEmpty, let data = jsonString.data(using: .utf8) else { continue }
                        
                        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let delta = json["delta"] as? [String: Any],
                           let text = delta["text"] as? String {
                            continuation.yield(text)
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
        return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
