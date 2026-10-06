import Foundation

public final class OpenAIProvider: LLMProviderProtocol {
    private let baseURL: String
    private let apiKey: String
    private let model: String
    
    public init(baseURL: String, apiKey: String, model: String) {
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.apiKey = apiKey
        self.model = model
    }
    
    public func streamChat(messages: [ChatMessage], systemPrompt: String) async throws -> AsyncThrowingStream<String, Error> {
        let endpoint = baseURL.hasSuffix("/v1") ? "\(baseURL)/chat/completions" : "\(baseURL)/v1/chat/completions"
        guard let url = URL(string: endpoint) else {
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
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
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
                        if jsonString == "[DONE]" {
                            break
                        }
                        guard !jsonString.isEmpty, let data = jsonString.data(using: .utf8) else { continue }
                        
                        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let choices = json["choices"] as? [[String: Any]],
                           let delta = choices.first?["delta"] as? [String: Any],
                           let content = delta["content"] as? String {
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
        return !baseURL.isEmpty
    }
}
