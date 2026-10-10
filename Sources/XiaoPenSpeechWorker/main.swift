import Darwin
import Dispatch
import Foundation
import MLX
import MLXAudioCore
import MLXAudioTTS

private struct SpeechRequest: Decodable {
    let id: String
    let text: String
    let voice: String
    let style: String
}

private struct SpeechEvent: Encodable {
    let type: String
    var id: String? = nil
    var sampleRate: Int? = nil
    var pcm: String? = nil
    var message: String? = nil
}

private enum WorkerFailure: Error {
    case invalidInput
    case incompleteModel
    case incompleteResources
    case invalidAudio
}

/// A private pipe carries protocol output. MLX and tokenizer diagnostics use
/// ordinary stdout, which is redirected to stderr before either is initialized.
private final class ProtocolOutput {
    private let handle: FileHandle
    private let encoder = JSONEncoder()

    init() {
        let descriptor = dup(STDOUT_FILENO)
        guard descriptor >= 0 else { exit(70) }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else { exit(70) }
        signal(SIGPIPE, SIG_IGN)
    }

    func send(_ event: SpeechEvent) throws {
        var data = try encoder.encode(event)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }
}

private final class RequestLines {
    private let input = FileHandle.standardInput
    private var pending = Data()
    private let maximumLineBytes = 65_536

    func next() throws -> Data? {
        while true {
            if let newline = pending.firstIndex(of: 0x0A) {
                guard newline <= maximumLineBytes else { throw WorkerFailure.invalidInput }
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                if !line.isEmpty { return line }
                continue
            }
            guard pending.count <= maximumLineBytes else { throw WorkerFailure.invalidInput }
            // Foundation's read(upToCount:) can wait to fill that length on a
            // persistent pipe. POSIX read returns the available request bytes.
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = bytes.withUnsafeMutableBytes {
                Darwin.read(input.fileDescriptor, $0.baseAddress, $0.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw WorkerFailure.invalidInput
            }
            guard count > 0 else {
                if pending.isEmpty { return nil }
                let line = pending
                pending.removeAll(keepingCapacity: true)
                return line
            }
            pending.append(contentsOf: bytes.prefix(count))
        }
    }
}

private enum SpeechWorker {
    static let speakers: Set<String> = [
        "vivian", "serena", "uncle_fu", "dylan", "eric", "ryan", "aiden", "ono_anna", "sohee"
    ]

    static func run() async {
        let output = ProtocolOutput()
        // The Swift package's bundled Metal kernels use the default fence path.
        // Do not inherit an opt-in for experimental kernels absent from it.
        setenv("MLX_METAL_FAST_SYNCH", "0", 1)
        // EOF is sufficient while idle, but synthesis can outlive the input
        // reader. A parent disappearing must also stop GPU work promptly.
        let parentPID = getppid()
        let parentMonitor = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        parentMonitor.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        parentMonitor.setEventHandler {
            if getppid() != parentPID { exit(0) }
        }
        parentMonitor.resume()
        defer { parentMonitor.cancel() }
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 2, arguments[0] == "--model-dir", !arguments[1].isEmpty else {
            try? output.send(SpeechEvent(type: "error", message: "Invalid worker arguments."))
            exit(64)
        }

        let model: Qwen3TTSModel
        do {
            try configureMetalLibrary()
            let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
            try validateModelDirectory(directory)
            // This loads only local files. It does not call the Hub downloader.
            model = try await Qwen3TTSModel.fromModelDirectory(directory)
            guard model.sampleRate > 0, model.sampleRate <= 192_000 else {
                throw WorkerFailure.incompleteModel
            }
            try await warmModel(model)
            try output.send(SpeechEvent(type: "ready", sampleRate: model.sampleRate))
        } catch {
            try? output.send(SpeechEvent(type: "error", message: "Could not load the local speech model."))
            exit(78)
        }

        let lines = RequestLines()
        let decoder = JSONDecoder()
        while true {
            let data: Data
            do {
                guard let next = try lines.next() else { return }
                data = next
            } catch {
                try? output.send(SpeechEvent(type: "error", message: "Invalid speech request framing."))
                exit(65)
            }

            let request: SpeechRequest
            do {
                request = try decoder.decode(SpeechRequest.self, from: data)
                guard UUID(uuidString: request.id) != nil,
                      !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      request.text.count <= 1000,
                      request.style.count <= 300,
                      speakers.contains(request.voice.lowercased()) else {
                    throw WorkerFailure.invalidInput
                }
            } catch {
                try? output.send(SpeechEvent(type: "error", message: "Invalid speech request."))
                exit(65)
            }

            do {
                let voice = request.style.isEmpty
                    ? request.voice : "\(request.voice), \(request.style)"
                var emittedAudio = false
                var generatedSignal = false
                // Finish one stream before accepting another request: the model
                // and its streaming decoder keep mutable generation state.
                for try await event in model.generateStream(
                    text: request.text,
                    voice: voice,
                    refAudio: nil,
                    refText: nil,
                    language: "Chinese",
                    generationParameters: .init(
                        maxTokens: 2048,
                        temperature: 0.8,
                        topP: 0.95,
                        repetitionPenalty: 1.1
                    ),
                    streamingInterval: 0.32
                ) {
                    guard case .audio(let chunk) = event else { continue }
                    let samples = chunk.asArray(Float.self)
                    if samples.isEmpty { continue }
                    guard samples.allSatisfy(\.isFinite) else { throw WorkerFailure.invalidAudio }
                    generatedSignal = generatedSignal || samples.contains { abs($0) > 0.000_01 }
                    let bits = samples.map { min(1, max(-1, $0)).bitPattern.littleEndian }
                    let pcm = bits.withUnsafeBufferPointer { Data(buffer: $0) }
                    try output.send(SpeechEvent(
                        type: "audio", id: request.id,
                        sampleRate: model.sampleRate, pcm: pcm.base64EncodedString()
                    ))
                    emittedAudio = true
                }
                guard emittedAudio, generatedSignal else { throw WorkerFailure.invalidAudio }
                try output.send(SpeechEvent(type: "done", id: request.id))
            } catch {
                // Exit on generation failure to discard the decoder state and
                // any producer work still in flight. No request text is logged.
                try? output.send(SpeechEvent(
                    type: "error", id: request.id,
                    message: "Local speech generation failed."
                ))
                exit(70)
            }
        }
    }

    private static func configureMetalLibrary() throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let binaryDirectory = executable.deletingLastPathComponent()
        let contentsDirectory = binaryDirectory.deletingLastPathComponent()
        guard binaryDirectory.lastPathComponent == "MacOS",
              contentsDirectory.lastPathComponent == "Contents" else {
            // A developer's CLI build uses MLX's automatically compiled bundle.
            return
        }
        let library = contentsDirectory.appendingPathComponent("Resources/mlx.metallib")
        let values = try library.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
            throw WorkerFailure.incompleteResources
        }
        // Set this before creating any MLX arrays or initializing the GPU. The
        // loader override avoids relying on Foundation's helper bundle lookup.
        GPU.metallib = library
    }

    private static func warmModel(_ model: Qwen3TTSModel) async throws {
        // Materialize one muted utterance so model, codec and GPU kernels are
        // ready before the first conversation. This fixed text is never played.
        var generatedSignal = false
        for try await event in model.generateStream(
            text: "你好，我是小喷。",
            voice: "Serena, 用自然、轻松、温暖的语气聊天，不要播音腔。",
            refAudio: nil,
            refText: nil,
            language: "Chinese",
            generationParameters: .init(
                maxTokens: 256,
                temperature: 0.8,
                topP: 0.95,
                repetitionPenalty: 1.1
            ),
            streamingInterval: 0.32
        ) {
            guard case .audio(let chunk) = event else { continue }
            let samples = chunk.asArray(Float.self)
            guard samples.allSatisfy(\.isFinite) else { throw WorkerFailure.invalidAudio }
            generatedSignal = generatedSignal || samples.contains { abs($0) > 0.000_01 }
        }
        guard generatedSignal else { throw WorkerFailure.invalidAudio }
    }

    private static func validateModelDirectory(_ directory: URL) throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw WorkerFailure.incompleteModel }
        // In particular, reject a file named speech_tokenizer before invoking
        // the upstream loader, whose stale-cache recovery removes its directory.
        let speechDirectory = directory.appendingPathComponent("speech_tokenizer", isDirectory: true)
        guard manager.fileExists(atPath: speechDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw WorkerFailure.incompleteModel }
        let required = [
            "config.json", "model.safetensors", "tokenizer_config.json",
            "speech_tokenizer/config.json", "speech_tokenizer/model.safetensors"
        ]
        for path in required {
            let url = directory.appendingPathComponent(path)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
                throw WorkerFailure.incompleteModel
            }
        }
        if !manager.fileExists(atPath: directory.appendingPathComponent("tokenizer.json").path) {
            guard manager.fileExists(atPath: directory.appendingPathComponent("vocab.json").path),
                  manager.fileExists(atPath: directory.appendingPathComponent("merges.txt").path) else {
                throw WorkerFailure.incompleteModel
            }
        }
    }
}

await SpeechWorker.run()
