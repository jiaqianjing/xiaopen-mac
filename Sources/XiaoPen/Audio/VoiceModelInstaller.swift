import Foundation
import CryptoKit
import Observation
import OSLog

/// Downloads the pinned Qwen3-TTS model inside the app, replacing the Python setup
/// script. Every file is verified against the bundled manifest before it is moved
/// into place, partial downloads resume, and an unverified file is never installed.
@Observable
@MainActor
public final class VoiceModelInstaller {
    public static let shared = VoiceModelInstaller()

    public enum Phase: Equatable {
        case idle
        case checking
        case downloading(received: Int64, total: Int64)
        case verifying
        case installed
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "com.jiaqianjing.XiaoPen", category: "voice-model")

    struct Manifest: Decodable {
        struct Entry: Decodable {
            let path: String
            let size: Int64
            let hash: String
            let algorithm: String
        }
        let repository: String
        let revision: String
        let files: [Entry]
    }

    public var totalBytes: Int64 { (try? Self.manifest().files.reduce(0) { $0 + $1.size }) ?? 0 }
    public var isRunning: Bool { task != nil }

    static func manifest() throws -> Manifest {
        guard let url = Bundle.module.url(forResource: "voice-model-manifest", withExtension: "json") else {
            throw InstallError.message("安装包缺少模型清单。")
        }
        return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
    }

    public func install() {
        guard task == nil else { return }
        phase = .checking
        task = Task { [weak self] in
            do {
                let manifest = try Self.manifest()
                let directory = LocalSpeechWorker.modelDirectory
                try await Self.run(manifest: manifest, directory: directory) { received, total in
                    Task { @MainActor in VoiceModelInstaller.shared.phase = .downloading(received: received, total: total) }
                } verifying: {
                    Task { @MainActor in VoiceModelInstaller.shared.phase = .verifying }
                }
                await MainActor.run { [weak self] in
                    self?.phase = .installed
                    self?.task = nil
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    self?.phase = .idle
                    self?.task = nil
                }
            } catch {
                let message = (error as? InstallError)?.description ?? error.localizedDescription
                await MainActor.run { [weak self] in
                    self?.logger.error("语音模型下载失败：\(message, privacy: .public)")
                    self?.phase = .failed(message)
                    self?.task = nil
                }
            }
        }
    }

    public func cancel() {
        task?.cancel()
    }

    // MARK: - Work (off the main actor)

    enum InstallError: Error, CustomStringConvertible {
        case message(String)
        var description: String { if case .message(let text) = self { return text }; return "" }
    }

    private nonisolated static func run(manifest: Manifest, directory: URL,
                                        progress: @escaping @Sendable (Int64, Int64) -> Void,
                                        verifying: @escaping @Sendable () -> Void) async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let total = manifest.files.reduce(0) { $0 + $1.size }
        var completed: Int64 = 0
        for entry in manifest.files {
            try Task.checkCancellation()
            guard !entry.path.hasPrefix("/"), !entry.path.split(separator: "/").contains("..") else {
                throw InstallError.message("模型清单包含无效路径。")
            }
            let target = directory.appendingPathComponent(entry.path)
            if try await verified(target, entry) {
                completed += entry.size
                progress(completed, total)
                continue
            }
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let staging = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).download")
            var lastError: Error?
            let base = completed
            for source in sources(manifest: manifest, path: entry.path) {
                do {
                    try await download(source, to: staging, expectedSize: entry.size) { received in
                        progress(base + received, total)
                    }
                    lastError = nil
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                }
            }
            if let lastError { throw lastError }
            verifying()
            guard try await verified(staging, entry) else {
                try? fileManager.removeItem(at: staging)
                throw InstallError.message("\(entry.path) 校验失败，已删除，请重试。")
            }
            if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
            try fileManager.moveItem(at: staging, to: target)
            completed += entry.size
            progress(completed, total)
        }
    }

    /// ModelScope is usually much faster in mainland China; Hugging Face is the fallback.
    nonisolated static func sources(manifest: Manifest, path: String) -> [URL] {
        let quoted = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let modelScope = URL(string: "https://modelscope.cn/models/\(manifest.repository)/resolve/master/\(quoted)")
        let huggingFace = URL(string: "https://huggingface.co/\(manifest.repository)/resolve/\(manifest.revision)/\(quoted)")
        return [modelScope, huggingFace].compactMap { $0 }
    }

    private nonisolated static func download(_ url: URL, to staging: URL, expectedSize: Int64,
                                             progress: @escaping @Sendable (Int64) -> Void) async throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: staging.path) { fileManager.createFile(atPath: staging.path, contents: nil) }
        var existing = (try? fileManager.attributesOfItem(atPath: staging.path)[.size] as? Int64) ?? 0
        if existing > expectedSize {
            try Data().write(to: staging)
            existing = 0
        }
        guard existing < expectedSize else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        if existing > 0 { request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, [200, 206].contains(http.statusCode) else {
            throw InstallError.message("下载失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）：\(url.host ?? "")")
        }
        let handle = try FileHandle(forWritingTo: staging)
        defer { try? handle.close() }
        if http.statusCode == 206 {
            try handle.seekToEnd()
        } else {
            try handle.truncate(atOffset: 0)
            existing = 0
        }
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var received = existing
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try Task.checkCancellation()
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                progress(received)
            }
        }
        try handle.write(contentsOf: buffer)
        received += Int64(buffer.count)
        progress(received)
    }

    nonisolated static func verified(_ url: URL, _ entry: Manifest.Entry) async throws -> Bool {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard values?.isSymbolicLink != true, Int64(values?.fileSize ?? -1) == entry.size,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        switch entry.algorithm {
        case "sha256":
            var hasher = SHA256()
            while let block = try handle.read(upToCount: 8 << 20), !block.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: block)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined() == entry.hash
        case "git-sha1":
            var hasher = Insecure.SHA1()
            hasher.update(data: Data("blob \(entry.size)\0".utf8))
            while let block = try handle.read(upToCount: 8 << 20), !block.isEmpty {
                hasher.update(data: block)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined() == entry.hash
        default:
            return false
        }
    }
}
