import Foundation

public enum LLMProviderError: LocalizedError, Equatable, Sendable {
    case invalidConfiguration(String)
    case httpError(statusCode: Int, message: String?)
    case modelUnavailable(String)
    case streamError(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message), .streamError(let message), .invalidResponse(let message):
            return message
        case .modelUnavailable(let model):
            return "模型 \(model) 不可用，请检查模型名称及账户访问权限。"
        case .httpError(let status, let message):
            let description: String
            switch status {
            case 400: description = "请求配置无效，请检查模型与接口设置。"
            case 401: description = "API Key 无效或已过期，请重新设置。"
            case 403: description = "账户无权访问该服务或模型。"
            case 404: description = "接口或模型不存在，请检查 Base URL 和模型名称。"
            case 408, 504: description = "模型服务响应超时，请稍后重试。"
            case 429: description = "请求受限或余额不足，请检查账户额度后重试。"
            case 500...599: description = "模型服务暂时不可用，请稍后重试。"
            default: description = "模型服务返回 HTTP \(status)。"
            }
            return message.map { "\(description) 服务提示：\($0)" } ?? description
        }
    }
}

/// Opens the TLS connection to the model service while the user is still talking,
/// so the real request reuses it. The response itself is ignored.
enum LLMConnectionWarmer {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastWarmed: [String: Date] = [:]

    static func warm(_ url: URL?, session: URLSession = .shared) {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "https", let host = url.host else { return }
        let now = Date()
        let shouldWarm = lock.withLock {
            if let last = lastWarmed[host], now.timeIntervalSince(last) < 20 { return false }
            lastWarmed[host] = now
            return true
        }
        guard shouldWarm, let origin = URL(string: "https://\(host)/") else { return }
        var request = URLRequest(url: origin)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 4
        session.dataTask(with: request).resume()
    }
}

enum LLMStreamFormat: Sendable, Equatable {
    case openAI, anthropic, ollama
}

enum LLMHTTPClient {
    static func baseURL(_ value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw LLMProviderError.invalidConfiguration("Base URL 必须是完整的 http:// 或 https:// 地址，且不包含账号、查询参数或空格。")
        }
        components.scheme = scheme
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url else {
            throw LLMProviderError.invalidConfiguration("Base URL 格式无效。")
        }
        return url
    }

    static func model(_ value: String) throws -> String {
        let model = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, model.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
            throw LLMProviderError.invalidConfiguration("请填写有效的模型名称，模型名称不能包含空格或换行。")
        }
        return model
    }

    static func apiKey(_ value: String, required: Bool) throws -> String {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!required || !key.isEmpty), key.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
            throw LLMProviderError.invalidConfiguration("请填写有效的 API Key，密钥不能包含空格或换行。")
        }
        return key
    }

    static func request(url: URL, method: String = "GET", payload: [String: Any]? = nil, headers: [String: String] = [:], timeout: TimeInterval = 60) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        if let payload {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        }
        return request
    }

    static func jsonResponse(for request: URLRequest, session: URLSession) async throws -> [String: Any] {
        let bytes = try await checkedBytes(for: request, session: session)
        defer { bytes.task.cancel() }
        var data = Data()
        try await withTaskCancellationHandler {
            for try await byte in bytes {
                try Task.checkCancellation()
                data.append(byte)
            }
        } onCancel: {
            bytes.task.cancel()
        }
        try Task.checkCancellation()
        let json = try object(from: data)
        if let message = serviceError(in: json) { throw LLMProviderError.streamError(message) }
        return json
    }

    private static func checkedBytes(for request: URLRequest, session: URLSession) async throws -> URLSession.AsyncBytes {
        let (bytes, response) = try await session.bytes(for: request)
        do {
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else {
                throw LLMProviderError.invalidResponse("模型服务没有返回有效的 HTTP 响应。")
            }
            guard (200...299).contains(response.statusCode) else {
                var data = Data()
                // An error body is optional. A stalled or slowly trickling proxy must not
                // delay a known HTTP error indefinitely or replace its status with a timeout.
                let deadline = Task {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    bytes.task.cancel()
                }
                defer {
                    deadline.cancel()
                    bytes.task.cancel()
                }
                do {
                    try await withTaskCancellationHandler {
                        for try await byte in bytes {
                            try Task.checkCancellation()
                            data.append(byte)
                            if data.count >= 65_536 { break }
                        }
                    } onCancel: {
                        bytes.task.cancel()
                    }
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    // Preserve the response status even if its optional body cannot be read.
                }
                try Task.checkCancellation()
                throw LLMProviderError.httpError(statusCode: response.statusCode, message: errorMessage(in: data))
            }
        } catch {
            bytes.task.cancel()
            throw error
        }
        return bytes
    }

    static func stream(for request: URLRequest, session: URLSession, format: LLMStreamFormat) async throws -> AsyncThrowingStream<String, Error> {
        let bytes = try await checkedBytes(for: request, session: session)
        return AsyncThrowingStream { continuation in
            let producer = Task {
                defer { bytes.task.cancel() }
                do {
                    var lines = LLMLineDecoder()
                    var decoder = LLMStreamDecoder(format: format)
                    var reasoning = ReasoningTagFilter()
                    var receivedText = false
                    var completed = false
                    // Returns false once the consumer has stopped listening.
                    func emit(_ text: String?) -> Bool {
                        guard let text, !text.isEmpty else { return true }
                        let visible = reasoning.consume(text)
                        guard !visible.isEmpty else { return true }
                        receivedText = true
                        if case .terminated = continuation.yield(visible) { return false }
                        return true
                    }
                    // Foundation's .lines can omit empty lines, which are SSE event boundaries.
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        guard let line = try lines.consume(byte) else { continue }
                        guard let chunk = try decoder.consume(line) else { continue }
                        guard emit(chunk.text) else { return }
                        if chunk.completed {
                            completed = true
                            break
                        }
                    }
                    if !completed, let line = try lines.finish(), let chunk = try decoder.consume(line) {
                        guard emit(chunk.text) else { return }
                        completed = chunk.completed
                    }
                    if !completed, let chunk = try decoder.finish() {
                        guard emit(chunk.text) else { return }
                        completed = chunk.completed
                    }
                    let tail = reasoning.finish()
                    if !tail.isEmpty {
                        receivedText = true
                        continuation.yield(tail)
                    }
                    try Task.checkCancellation()
                    guard completed else {
                        throw LLMProviderError.invalidResponse("回复连接提前结束，请重试。")
                    }
                    guard receivedText else {
                        throw LLMProviderError.invalidResponse("模型没有返回文本回复，请确认所选模型支持文本对话。")
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                producer.cancel()
                bytes.task.cancel()
            }
        }
    }

    static func object(from data: Data) throws -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: data), let json = value as? [String: Any] else {
            throw LLMProviderError.invalidResponse("模型服务返回了无法解析的数据，请检查接口地址。")
        }
        return json
    }

    static func serviceError(in json: [String: Any]) -> String? {
        if let error = json["error"] as? [String: Any] {
            return concise(error["message"] as? String ?? error["type"] as? String ?? "模型服务返回错误。")
        }
        if let error = json["error"] as? String { return concise(error) }
        if json["type"] as? String == "error" {
            return concise(json["message"] as? String ?? "模型服务返回错误。")
        }
        return nil
    }

    private static func errorMessage(in data: Data) -> String? {
        guard let json = try? object(from: data) else { return nil }
        return serviceError(in: json) ?? (json["message"] as? String).map(concise)
    }

    private static func concise(_ value: String) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
    }
}

/// Some models (MiniMax without reasoning_split, local Qwen3/DeepSeek-R1 builds) put
/// their reasoning inside `<think>` tags in the answer text. That must never be
/// displayed or read aloud, and a tag may be split across stream deltas.
struct ReasoningTagFilter {
    private var pending = ""
    private var insideReasoning = false
    private var emittedVisibleText = false

    mutating func consume(_ text: String) -> String {
        pending += text
        var output = ""
        while true {
            let tag = insideReasoning ? "</think>" : "<think>"
            if let range = pending.range(of: tag) {
                if !insideReasoning { output += pending[..<range.lowerBound] }
                pending = String(pending[range.upperBound...])
                insideReasoning.toggle()
                continue
            }
            let held = Self.partialTagLength(at: pending, tag: tag)
            let end = pending.index(pending.endIndex, offsetBy: -held)
            if !insideReasoning { output += pending[..<end] }
            pending = String(pending[end...])
            return trimLeadingBlankText(output)
        }
    }

    mutating func finish() -> String {
        defer { pending = "" }
        return insideReasoning ? "" : trimLeadingBlankText(pending)
    }

    /// Answers usually start with blank lines after a reasoning block.
    private mutating func trimLeadingBlankText(_ text: String) -> String {
        guard !emittedVisibleText else { return text }
        let trimmed = String(text.drop(while: \.isWhitespace))
        if !trimmed.isEmpty { emittedVisibleText = true }
        return trimmed
    }

    private static func partialTagLength(at text: String, tag: String) -> Int {
        for length in stride(from: min(tag.count - 1, text.count), through: 1, by: -1)
        where text.hasSuffix(tag.prefix(length)) {
            return length
        }
        return 0
    }
}

private struct LLMStreamChunk {
    var text: String?
    var completed = false
}

private struct LLMLineDecoder {
    private var buffer = Data()
    private var previousWasCR = false

    mutating func consume(_ byte: UInt8) throws -> String? {
        if byte == 10 && previousWasCR {
            previousWasCR = false
            return nil
        }
        if byte == 10 || byte == 13 {
            previousWasCR = byte == 13
            return try takeLine()
        }
        previousWasCR = false
        buffer.append(byte)
        guard buffer.count <= 1_048_576 else {
            throw LLMProviderError.invalidResponse("模型服务返回的数据行过长，无法处理。")
        }
        return nil
    }

    mutating func finish() throws -> String? {
        guard !buffer.isEmpty else { return nil }
        return try takeLine()
    }

    private mutating func takeLine() throws -> String {
        guard let line = String(data: buffer, encoding: .utf8) else {
            throw LLMProviderError.invalidResponse("模型服务返回了无效的 UTF-8 文本。")
        }
        buffer.removeAll(keepingCapacity: true)
        return line
    }
}

private struct LLMStreamDecoder {
    let format: LLMStreamFormat
    private var dataLines: [String] = []

    init(format: LLMStreamFormat) { self.format = format }

    mutating func consume(_ line: String) throws -> LLMStreamChunk? {
        if format == .ollama {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return try decode(line)
        }
        if line.isEmpty { return try finish() }
        guard line.hasPrefix("data:") else { return nil }
        var data = String(line.dropFirst(5))
        if data.hasPrefix(" ") { data.removeFirst() }
        dataLines.append(data)
        return nil
    }

    mutating func finish() throws -> LLMStreamChunk? {
        guard !dataLines.isEmpty else { return nil }
        let payload = dataLines.joined(separator: "\n")
        dataLines.removeAll(keepingCapacity: true)
        guard !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return try decode(payload)
    }

    private func decode(_ payload: String) throws -> LLMStreamChunk {
        if format == .openAI && payload.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
            return LLMStreamChunk(completed: true)
        }
        let json = try LLMHTTPClient.object(from: Data(payload.utf8))
        if let message = LLMHTTPClient.serviceError(in: json) { throw LLMProviderError.streamError(message) }
        switch format {
        case .openAI:
            let choice = (json["choices"] as? [[String: Any]])?.first
            let delta = choice?["delta"] as? [String: Any]
            let finishReason = choice?["finish_reason"] as? String
            if finishReason == "length" {
                throw LLMProviderError.invalidResponse("回复达到模型长度上限，请缩短问题后重试。")
            }
            return LLMStreamChunk(text: delta?["content"] as? String ?? delta?["refusal"] as? String, completed: finishReason != nil)
        case .anthropic:
            let type = json["type"] as? String
            if type == "message_stop" { return LLMStreamChunk(completed: true) }
            if type == "message_delta", let delta = json["delta"] as? [String: Any], delta["stop_reason"] as? String == "max_tokens" {
                throw LLMProviderError.invalidResponse("回复达到模型长度上限，请缩短问题后重试。")
            }
            if type == "content_block_start", let content = json["content_block"] as? [String: Any] {
                return LLMStreamChunk(text: content["text"] as? String)
            }
            return LLMStreamChunk(text: (json["delta"] as? [String: Any])?["text"] as? String)
        case .ollama:
            return LLMStreamChunk(text: (json["message"] as? [String: Any])?["content"] as? String, completed: json["done"] as? Bool == true)
        }
    }
}
