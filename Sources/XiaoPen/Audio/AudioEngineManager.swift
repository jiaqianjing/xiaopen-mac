import Foundation
import AVFoundation
import CoreAudio

public enum AudioEngineError: LocalizedError {
    case noInputDeviceAvailable
    case microphonePermissionDenied
    case microphonePermissionNotDetermined
    case formatMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .noInputDeviceAvailable:
            return "未检测到麦克风输入设备，请连接 USB 麦克风、摄像头麦克风或蓝牙耳机。"
        case .microphonePermissionDenied:
            return "麦克风访问未获授权，请在系统设置的隐私与安全性中允许此应用使用麦克风。"
        case .microphonePermissionNotDetermined:
            return "请先授予麦克风权限，再启动语音采集。"
        case .formatMismatch(let detail):
            return "音频格式不匹配：\(detail)"
        }
    }
}

@MainActor
public final class AudioEngineManager {
    public static let shared = AudioEngineManager()

    private let audioEngine = AVAudioEngine()
    private var tapInstalled = false
    private var shouldKeepRunning = false
    private var observers: [NSObjectProtocol] = []
    private var inputDeviceListener: AudioObjectPropertyListenerBlock?
    private var observationID: UUID?
    private var recoveryTask: Task<Void, Never>?
    private var recoveryBackoff = AudioRecoveryBackoff(initialDelay: 2)

    public var isRunning: Bool { audioEngine.isRunning }
    public private(set) var statusMessage = "麦克风未启动。"
    public var onAudioLevel: (@Sendable (Float) -> Void)?
    public var onAudioBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    public var onStatusMessage: (@Sendable (String) -> Void)?
    public var onCaptureAvailabilityChanged: (@Sendable (Bool) -> Void)?
    public var onCaptureError: (@Sendable (String) -> Void)?

    private init() {}

    private func installObservers() {
        guard observers.isEmpty else { return }
        let identifier = UUID()
        observationID = identifier
        var address = defaultInputAddress
        let listener: AudioObjectPropertyListenerBlock = { @Sendable [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.handleHardwareChange(observationID: identifier)
            }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener) == noErr {
            inputDeviceListener = listener
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleHardwareChange(observationID: identifier)
            }
        })
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard (notification.object as? AVCaptureDevice)?.hasMediaType(.audio) != false else { return }
                Task { @MainActor [weak self] in
                    self?.handleHardwareChange(observationID: identifier)
                }
            })
        }
    }

    private func removeObservers() {
        observationID = nil
        if let listener = inputDeviceListener {
            var address = defaultInputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
            inputDeviceListener = nil
        }
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func handleHardwareChange(observationID identifier: UUID) {
        guard shouldKeepRunning, observationID == identifier else { return }
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryBackoff.reset()
        stopCapture(notifyUnavailable: true)
        do {
            try start()
        } catch {
            // start() reports the failure and schedules the next recovery attempt.
        }
    }

    public func start() throws {
        if !shouldKeepRunning { recoveryBackoff.reset() }
        shouldKeepRunning = true
        recoveryTask?.cancel()
        recoveryTask = nil
        guard !audioEngine.isRunning else { return }

        do {
            try checkMicrophonePermission()
            installObservers()
            guard hasDefaultInputDevice() else { throw AudioEngineError.noInputDeviceAvailable }

            let inputNode = audioEngine.inputNode
            let inputFormat = inputNode.inputFormat(forBus: 0)
            guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
                throw AudioEngineError.noInputDeviceAvailable
            }

            // Capturing pauses during model replies and playback. Avoid a VoiceProcessingIO
            // aggregate device, which can retain a disconnected Bluetooth input on macOS.
            if inputNode.isVoiceProcessingEnabled {
                try inputNode.setVoiceProcessingEnabled(false)
            }
            // Taps consume node output; voice processing may change the hardware input format.
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            guard recordingFormat.channelCount > 0, recordingFormat.sampleRate > 0 else {
                throw AudioEngineError.formatMismatch("麦克风输出格式没有有效声道或采样率")
            }

            if tapInstalled {
                inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            // Snapshot callbacks on the main actor, so the render callback never reads mutable actor state.
            let levelHandler = onAudioLevel
            let bufferHandler = onAudioBuffer
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { @Sendable buffer, _ in
                if let channelData = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                    let frameLength = Int(buffer.frameLength)
                    var sum: Float = 0
                    for index in 0..<frameLength {
                        sum += channelData[index] * channelData[index]
                    }
                    let rms = sqrt(sum / Float(frameLength))
                    levelHandler?(min(max(rms * 8, 0), 1))
                }
                bufferHandler?(buffer)
            }
            tapInstalled = true
            audioEngine.prepare()
            try audioEngine.start()
            recoveryBackoff.reset()
            setStatus("麦克风正在采集 · 回复时自动暂停。")
            onCaptureAvailabilityChanged?(true)
        } catch {
            stopCapture(notifyUnavailable: true)
            let message = error.localizedDescription
            setStatus(message)
            onCaptureError?(message)
            if let audioError = error as? AudioEngineError {
                switch audioError {
                case .microphonePermissionDenied, .microphonePermissionNotDetermined:
                    shouldKeepRunning = false
                    removeObservers()
                default:
                    break
                }
            }
            if shouldKeepRunning { scheduleRecovery() }
            throw error
        }
    }

    private func checkMicrophonePermission() throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            throw AudioEngineError.microphonePermissionNotDetermined
        case .denied, .restricted:
            throw AudioEngineError.microphonePermissionDenied
        @unknown default:
            throw AudioEngineError.microphonePermissionDenied
        }
    }

    private var defaultInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func hasDefaultInputDevice() -> Bool {
        var address = defaultInputAddress
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        return status == noErr && deviceID != kAudioObjectUnknown
    }

    private func scheduleRecovery() {
        recoveryTask?.cancel()
        let delay = recoveryBackoff.nextDelay()
        recoveryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.shouldKeepRunning else { return }
            self.recoveryTask = nil
            do {
                try self.start()
            } catch {
                // start() retains the recovery intent and advances the bounded backoff.
            }
        }
    }

    private func stopCapture(notifyUnavailable: Bool) {
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        audioEngine.stop()
        if notifyUnavailable { onCaptureAvailabilityChanged?(false) }
    }

    private func setStatus(_ message: String) {
        statusMessage = message
        onStatusMessage?(message)
    }

    public func stop() {
        shouldKeepRunning = false
        recoveryTask?.cancel()
        recoveryTask = nil
        removeObservers()
        // Deliberate stops must not masquerade as hardware loss in a newer app session.
        stopCapture(notifyUnavailable: false)
        statusMessage = "麦克风已停止采集。"
    }
}
