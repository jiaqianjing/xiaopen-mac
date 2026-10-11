import Foundation
import AVFoundation
import OSLog

/// Converts microphone buffers to 16 kHz mono PCM16 for cloud recognition and keeps
/// the last few seconds, so a question spoken in the same breath as the wake word
/// ("小喷小喷明天天气怎么样") reaches the cloud from its beginning. Audio leaves this
/// class only while a session is attached, i.e. after a local wake-up.
final class CloudAudioTap: @unchecked Sendable {
    static let shared = CloudAudioTap()
    static let sampleRate: Double = 16_000
    private static let bytesPerSecond = Int(sampleRate) * 2

    private let lock = NSLock()
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: CloudAudioTap.sampleRate,
                                             channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var ring = Data()
    private let ringSeconds = 3
    private var sink: CloudSpeechSession?
    private var enabled = false

    /// Off in local-only mode, so no conversion work or buffering happens at all.
    func setEnabled(_ value: Bool) {
        lock.withLock {
            enabled = value
            if !value { ring.removeAll(); sink = nil }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard lock.withLock({ enabled }), let data = convert(buffer), !data.isEmpty else { return }
        let target: CloudSpeechSession? = lock.withLock {
            ring.append(data)
            let capacity = ringSeconds * Self.bytesPerSecond
            if ring.count > capacity { ring.removeFirst(ring.count - capacity) }
            return sink
        }
        target?.append(data)
    }

    /// Sends up to `prerollSeconds` of recent audio, then streams live audio to `session`.
    func attach(_ session: CloudSpeechSession, prerollSeconds: Double) {
        lock.withLock {
            let bytes = min(ring.count, Int(prerollSeconds * Double(Self.bytesPerSecond)) / 2 * 2)
            if bytes > 0 { session.append(Data(ring.suffix(bytes))) }
            sink = session
        }
    }

    func detach() {
        lock.withLock { sink = nil }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        let inputFormat = buffer.format
        guard buffer.frameLength > 0, inputFormat.sampleRate > 0 else { return nil }
        if converterInputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            converterInputFormat = inputFormat
        }
        guard let converter else { return nil }
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0, let samples = output.int16ChannelData?[0] else { return nil }
        return Data(bytes: samples, count: Int(output.frameLength) * 2)
    }
}

/// One recognition task on Qianwen's real-time ASR (Fun-ASR / Qwen-Audio ASR streaming)
/// over WebSocket: run-task → binary PCM frames → finish-task. Thread-safe: audio
/// arrives from the capture thread, events are delivered on a private queue.
final class CloudSpeechSession: @unchecked Sendable {
    enum Event: Sendable {
        case transcript(String, sentenceEnded: Bool)
        case failed(String)
    }

    static let endpoint = URL(string: "wss://maas.qianwenaiapi.com/api-ws/v1/inference")!
    let id = UUID()

    private let model: String
    private let endpoint: URL
    private let onEvent: @Sendable (Event) -> Void
    private let queue = DispatchQueue(label: "com.jiaqianjing.XiaoPen.cloud-asr")
    private let taskID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private let logger = Logger(subsystem: "com.jiaqianjing.XiaoPen", category: "cloud-asr")
    private let openedAt = ProcessInfo.processInfo.systemUptime

    // Queue-confined state.
    private var socket: URLSessionWebSocketTask?
    private var started = false
    private var pending: [Data] = []
    private var pendingBytes = 0
    private var sentences: [Int: String] = [:]
    private var finishRequested = false
    private var finished = false
    private var finishWaiters: [CheckedContinuation<String, Never>] = []

    init(model: String, endpoint: URL = CloudSpeechSession.endpoint, onEvent: @escaping @Sendable (Event) -> Void) {
        self.model = model
        self.endpoint = endpoint
        self.onEvent = onEvent
    }

    var transcript: String {
        queue.sync { joinedTranscript() }
    }

    /// Audio sent before the connection is ready is buffered (bounded) and flushed on task-started.
    func connect(apiKey: String) {
        queue.async { [self] in
            guard !finished else { return }
            var request = URLRequest(url: endpoint)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 10
            let socket = URLSession.shared.webSocketTask(with: request)
            self.socket = socket
            socket.resume()
            let runTask: [String: Any] = [
                "header": ["action": "run-task", "task_id": taskID, "streaming": "duplex"],
                "payload": [
                    "task_group": "audio", "task": "asr", "function": "recognition", "model": model,
                    "parameters": ["format": "pcm", "sample_rate": Int(CloudAudioTap.sampleRate),
                                   "max_sentence_silence": 800],
                    "input": [String: Any]()
                ]
            ]
            sendJSON(runTask)
            receive()
            // A connection that never starts must not leave the user waiting.
            queue.asyncAfter(deadline: .now() + 4) { [self] in
                if !started, !finished { fail("连接云端语音识别超时") }
            }
        }
    }

    func append(_ data: Data) {
        queue.async { [self] in
            guard !finished, !finishRequested else { return }
            if started {
                socket?.send(.data(data)) { _ in }
            } else if pendingBytes < 20 * 32_000 {
                pending.append(data)
                pendingBytes += data.count
            }
        }
    }

    /// Ends the audio and waits (bounded) for the final sentence results.
    func finish(timeout: TimeInterval = 1.5) async -> String {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if finished {
                    continuation.resume(returning: joinedTranscript())
                    return
                }
                finishWaiters.append(continuation)
                if !finishRequested {
                    finishRequested = true
                    if started { sendFinishTask() }
                }
                queue.asyncAfter(deadline: .now() + timeout) { [self] in
                    complete()
                }
            }
        }
    }

    func cancel() {
        queue.async { [self] in
            finished = true
            socket?.cancel(with: .normalClosure, reason: nil)
            socket = nil
            resumeWaiters()
        }
    }

    // MARK: - Queue-confined helpers

    private func sendFinishTask() {
        sendJSON(["header": ["action": "finish-task", "task_id": taskID, "streaming": "duplex"],
                  "payload": ["input": [String: Any]()]])
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        socket?.send(.string(text)) { _ in }
    }

    private func receive() {
        socket?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard !self.finished else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message { self.handle(text) }
                    if !self.finished { self.receive() }
                case .failure(let error):
                    self.fail("云端语音识别连接中断：\(error.localizedDescription)")
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = json["header"] as? [String: Any],
              let event = header["event"] as? String else { return }
        switch event {
        case "task-started":
            started = true
            logger.notice("云端识别已连接：model=\(self.model, privacy: .public), seconds=\(ProcessInfo.processInfo.systemUptime - self.openedAt)")
            for chunk in pending { socket?.send(.data(chunk)) { _ in } }
            pending.removeAll()
            if finishRequested { sendFinishTask() }
        case "result-generated":
            guard let payload = json["payload"] as? [String: Any],
                  let output = payload["output"] as? [String: Any],
                  let sentence = output["sentence"] as? [String: Any],
                  sentence["heartbeat"] as? Bool != true else { return }
            let id = sentence["sentence_id"] as? Int ?? 0
            sentences[id] = sentence["text"] as? String ?? ""
            onEvent(.transcript(joinedTranscript(), sentenceEnded: sentence["sentence_end"] as? Bool == true))
        case "task-finished":
            complete()
        case "task-failed":
            let code = header["error_code"] as? String ?? ""
            let message = header["error_message"] as? String ?? "未知错误"
            fail("云端语音识别失败：\(code) \(message)")
        default:
            break
        }
    }

    private func joinedTranscript() -> String {
        sentences.keys.sorted().compactMap { sentences[$0] }.joined()
    }

    private func fail(_ message: String) {
        guard !finished else { return }
        logger.error("\(message, privacy: .public)")
        finished = true
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        onEvent(.failed(message))
        resumeWaiters()
    }

    private func complete() {
        guard !finished else {
            resumeWaiters()
            return
        }
        finished = true
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        resumeWaiters()
    }

    private func resumeWaiters() {
        let text = joinedTranscript()
        let waiters = finishWaiters
        finishWaiters.removeAll()
        waiters.forEach { $0.resume(returning: text) }
    }
}

/// Settings self-test: synthesizes a known sentence with the system voice, streams it
/// through a real cloud session, and returns what the service heard.
@MainActor
enum CloudSpeechSelfTest {
    static let phrase = "明天北京会下雨吗"

    static func run(apiKey: String, model: String) async -> Result<String, Error> {
        let pcm = await synthesize(phrase)
        guard !pcm.isEmpty else { return .failure(CloudSpeechTestError.message("系统语音合成失败")) }
        let failure = FailureBox()
        let session = CloudSpeechSession(model: model) { event in
            if case .failed(let message) = event { failure.set(message) }
        }
        session.connect(apiKey: apiKey)
        // Real-time pacing is not required by the service; 100 ms chunks keep frames small.
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + 3200, pcm.count)
            session.append(pcm.subdata(in: offset..<end))
            offset = end
        }
        let text = await session.finish(timeout: 6)
        if let message = failure.value, text.isEmpty { return .failure(CloudSpeechTestError.message(message)) }
        return .success(text)
    }

    private static func synthesize(_ text: String) async -> Data {
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: CloudAudioTap.sampleRate,
                                   channels: 1, interleaved: true)!
        return await withCheckedContinuation { continuation in
            var data = Data()
            var converter: AVAudioConverter?
            var resumed = false
            let finish = {
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: data)
            }
            // The end of synthesis is an empty buffer; a timeout guards voices that never send one.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { finish() }
            synthesizer.write(utterance) { buffer in
                _ = synthesizer // keep the synthesizer alive until it has written everything
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    DispatchQueue.main.async { finish() }
                    return
                }
                if converter == nil { converter = AVAudioConverter(from: pcm.format, to: output) }
                let capacity = AVAudioFrameCount(Double(pcm.frameLength) * output.sampleRate / pcm.format.sampleRate) + 32
                guard let converter, let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return }
                var supplied = false
                converter.convert(to: converted, error: nil) { _, status in
                    if supplied { status.pointee = .noDataNow; return nil }
                    supplied = true
                    status.pointee = .haveData
                    return pcm
                }
                if let samples = converted.int16ChannelData?[0] {
                    let chunk = Data(bytes: samples, count: Int(converted.frameLength) * 2)
                    // Collected on the main queue, the same queue that finishes, so order is kept.
                    DispatchQueue.main.async { data.append(chunk) }
                }
            }
        }
    }
}

enum CloudSpeechTestError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

private final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var message: String?
    var value: String? { lock.withLock { message } }
    func set(_ value: String) { lock.withLock { message = value } }
}
