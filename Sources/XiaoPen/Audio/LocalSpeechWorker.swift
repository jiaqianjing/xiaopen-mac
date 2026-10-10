import Foundation
import Darwin

enum LocalSpeechEvent: Sendable {
    case audio(samples: [Float], sampleRate: Int)
}

enum LocalSpeechError: LocalizedError, Sendable, Equatable {
    case missingModel
    case missingWorker
    case startupTimeout
    case workerStopped
    case invalidAudio
    case busy
    case generationFailed
    case generationTimeout
    case outputChanged
    case systemInterrupted

    var errorDescription: String? {
        switch self {
        case .missingModel: return "本机语音模型尚未安装，请先运行项目的语音模型安装脚本。"
        case .missingWorker: return "应用缺少本机语音组件，请安装完整的 XiaoPen 安装包。"
        case .startupTimeout: return "本机语音模型加载超时，请重新准备本机语音。"
        case .workerStopped: return "本机语音组件已停止，请重新准备本机语音。"
        case .invalidAudio: return "本机语音组件返回了无效音频。"
        case .busy: return "本机语音组件仍在处理上一段语音。"
        case .generationFailed: return "本机语音生成失败，请重新准备本机语音。"
        case .generationTimeout: return "本机语音生成暂时没有响应，请重新准备本机语音。"
        case .outputChanged: return "语音输出设备发生变化，请连接好耳机或扬声器后重试。"
        case .systemInterrupted: return "系统朗读意外中断，请重试。"
        }
    }
}

/// The helper owns MLX and keeps one model resident. Killing an interrupted helper
/// prevents an old unstructured model producer from overlapping a replacement.
actor LocalSpeechWorker {
    static let modelName = "Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit"
    static var modelDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/XiaoPen/Models", isDirectory: true)
            .appendingPathComponent(modelName, isDirectory: true)
    }

    static var isModelInstalled: Bool {
        isModelInstalled(in: modelDirectory)
    }

    private static func isModelInstalled(in directory: URL) -> Bool {
        ["config.json", "model.safetensors", "speech_tokenizer/config.json", "speech_tokenizer/model.safetensors",
         "vocab.json", "merges.txt"].allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    private struct Request: Encodable {
        let id: String
        let text: String
        let voice: String
        let style: String
    }

    private struct Packet: Decodable {
        let type: String
        let id: String?
        let sampleRate: Int?
        let pcm: String?
    }

    private let executableURL: URL
    private let modelURL: URL
    private var process: Process?
    private var processToken: UUID?
    private var input: FileHandle?
    private var output: FileHandle?
    private var diagnostics: FileHandle?
    private var outputReader: Task<Void, Never>?
    private var diagnosticReader: Task<Void, Never>?
    private var generationWatchdog: Task<Void, Never>?
    private var ready = false
    private var lastError: LocalSpeechError?
    private var ownerSession: UUID?
    private var requestID: UUID?
    private var continuation: AsyncThrowingStream<LocalSpeechEvent, Error>.Continuation?

    init(executableURL: URL? = nil, modelDirectory: URL = LocalSpeechWorker.modelDirectory) {
        self.modelURL = modelDirectory
        self.executableURL = executableURL ?? (Bundle.main.executableURL?
            .deletingLastPathComponent().appendingPathComponent("XiaoPenSpeechWorker")
            ?? URL(fileURLWithPath: "/Applications/XiaoPen.app/Contents/MacOS/XiaoPenSpeechWorker"))
    }

    func prepare() async throws {
        try Task.checkCancellation()
        let token = try launchIfNeeded()
        try await waitUntilReady(token: token)
    }

    func generate(text: String, voice: String, style: String, sessionID: UUID, utteranceID: UUID) async throws
        -> AsyncThrowingStream<LocalSpeechEvent, Error> {
        try Task.checkCancellation()
        if let ownerSession, ownerSession != sessionID, continuation != nil {
            stopProcess()
        }
        guard continuation == nil else { throw LocalSpeechError.busy }
        let token = try launchIfNeeded()
        ownerSession = sessionID
        try await waitUntilReady(token: token)
        try Task.checkCancellation()
        guard processToken == token, ownerSession == sessionID else { throw CancellationError() }

        let (stream, newContinuation) = AsyncThrowingStream<LocalSpeechEvent, Error>.makeStream()
        continuation = newContinuation
        requestID = utteranceID
        newContinuation.onTermination = { @Sendable [weak self] reason in
            guard case .cancelled = reason else { return }
            Task { await self?.cancelRequest(utteranceID: utteranceID, token: token) }
        }
        do {
            var data = try JSONEncoder().encode(Request(id: utteranceID.uuidString, text: text, voice: voice, style: style))
            data.append(0x0A)
            guard let input else { throw LocalSpeechError.workerStopped }
            try input.write(contentsOf: data)
            scheduleGenerationWatchdog(token: token, utteranceID: utteranceID)
        } catch {
            fail(.workerStopped, token: token)
            throw error
        }
        return stream
    }

    func stop(sessionID: UUID) {
        guard ownerSession == sessionID else { return }
        stopProcess()
    }

    func shutdown() { stopProcess() }

    private func cancelRequest(utteranceID: UUID, token: UUID) {
        guard processToken == token, requestID == utteranceID else { return }
        stopProcess()
    }

    private func launchIfNeeded() throws -> UUID {
        if let processToken, process?.isRunning == true { return processToken }
        stopProcess()
        guard Self.isModelInstalled(in: modelURL) else { throw LocalSpeechError.missingModel }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else { throw LocalSpeechError.missingWorker }

        let worker = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let diagnosticPipe = Pipe()
        let token = UUID()
        worker.executableURL = executableURL
        worker.arguments = ["--model-dir", modelURL.path]
        worker.standardInput = inputPipe
        worker.standardOutput = outputPipe
        worker.standardError = diagnosticPipe
        try worker.run()
        try? inputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
        try? diagnosticPipe.fileHandleForWriting.close()
        process = worker
        processToken = token
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
        diagnostics = diagnosticPipe.fileHandleForReading
        ready = false
        lastError = nil

        let reader = outputPipe.fileHandleForReading
        outputReader = Task.detached { [weak self] in
            defer { try? reader.close() }
            var buffered = Data()
            let descriptor = reader.fileDescriptor
            var bytes = [UInt8](repeating: 0, count: 16_384)
            do {
                while !Task.isCancelled {
                    let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { break }
                    buffered.append(contentsOf: bytes.prefix(count))
                    while let newline = buffered.firstIndex(of: 0x0A) {
                        let line = Data(buffered[..<newline])
                        buffered.removeSubrange(...newline)
                        guard line.count <= 1_048_576 else {
                            await self?.fail(.invalidAudio, token: token)
                            return
                        }
                        await self?.receive(line, token: token)
                    }
                    guard buffered.count <= 1_048_576 else {
                        await self?.fail(.invalidAudio, token: token)
                        return
                    }
                }
            }
            await self?.didReachEOF(token: token)
        }
        // Upstream model diagnostics must be drained, but never include them in
        // application logs; speech text and audio are private to this process pair.
        let diagnosticHandle = diagnosticPipe.fileHandleForReading
        diagnosticReader = Task.detached {
            defer { try? diagnosticHandle.close() }
            let descriptor = diagnosticHandle.fileDescriptor
            var bytes = [UInt8](repeating: 0, count: 16_384)
            while !Task.isCancelled {
                let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
            }
        }
        return token
    }

    private func waitUntilReady(token: UUID) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(45))
        while !ready {
            try Task.checkCancellation()
            if let lastError { throw lastError }
            guard processToken == token else { throw CancellationError() }
            guard ContinuousClock.now < deadline else {
                fail(.startupTimeout, token: token)
                throw LocalSpeechError.startupTimeout
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard processToken == token else { throw CancellationError() }
    }

    private func receive(_ data: Data, token: UUID) {
        guard processToken == token else { return }
        guard let packet = try? JSONDecoder().decode(Packet.self, from: data) else {
            fail(.invalidAudio, token: token)
            return
        }
        switch packet.type {
        case "ready":
            guard packet.sampleRate == 24_000 else { fail(.invalidAudio, token: token); return }
            ready = true
        case "audio":
            guard packet.id == requestID?.uuidString, let continuation else { return }
            guard packet.sampleRate == 24_000, let encoded = packet.pcm,
                  let pcm = Data(base64Encoded: encoded), !pcm.isEmpty,
                  pcm.count.isMultiple(of: 4), pcm.count <= 768_000 else {
                fail(.invalidAudio, token: token)
                return
            }
            let samples = pcm.withUnsafeBytes { bytes in
                stride(from: 0, to: pcm.count, by: 4).map { index in
                    Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: index, as: UInt32.self)))
                }
            }
            guard samples.allSatisfy(\.isFinite) else { fail(.invalidAudio, token: token); return }
            continuation.yield(.audio(samples: samples, sampleRate: 24_000))
            if let requestID { scheduleGenerationWatchdog(token: token, utteranceID: requestID) }
        case "done":
            guard packet.id == requestID?.uuidString else { return }
            let completed = continuation
            continuation = nil
            requestID = nil
            generationWatchdog?.cancel()
            generationWatchdog = nil
            completed?.finish()
        case "error":
            guard packet.id == nil || packet.id == requestID?.uuidString else { return }
            fail(.generationFailed, token: token)
        default:
            fail(.invalidAudio, token: token)
        }
    }

    private func didReachEOF(token: UUID) {
        guard processToken == token else { return }
        fail(.workerStopped, token: token)
    }

    private func scheduleGenerationWatchdog(token: UUID, utteranceID: UUID) {
        generationWatchdog?.cancel()
        generationWatchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            await self?.generationTimedOut(token: token, utteranceID: utteranceID)
        }
    }

    private func generationTimedOut(token: UUID, utteranceID: UUID) {
        guard processToken == token, requestID == utteranceID else { return }
        fail(.generationTimeout, token: token)
    }

    private func fail(_ error: LocalSpeechError, token: UUID) {
        guard processToken == token else { return }
        let failed = continuation
        continuation = nil
        stopProcess()
        lastError = error
        failed?.finish(throwing: error)
    }

    private func stopProcess() {
        processToken = nil
        ready = false
        ownerSession = nil
        requestID = nil
        let cancelled = continuation
        continuation = nil
        cancelled?.finish(throwing: CancellationError())
        try? input?.close()
        input = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        outputReader?.cancel()
        diagnosticReader?.cancel()
        generationWatchdog?.cancel()
        generationWatchdog = nil
        // Reader tasks retain these handles until EOF after termination; closing
        // a descriptor here could let an old reader consume a newly reused FD.
        output = nil
        diagnostics = nil
        outputReader = nil
        diagnosticReader = nil
    }
}
