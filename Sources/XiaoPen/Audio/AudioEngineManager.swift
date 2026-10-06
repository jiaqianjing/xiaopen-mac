import Foundation
import AVFoundation

public enum AudioEngineError: LocalizedError {
    case noInputDeviceAvailable
    case formatMismatch(String)
    
    public var errorDescription: String? {
        switch self {
        case .noInputDeviceAvailable:
            return "未检测到麦克风输入设备（Mac mini 需外接 USB 麦克风、摄像头麦克风或蓝牙耳机）"
        case .formatMismatch(let detail):
            return "音频格式不匹配: \(detail)"
        }
    }
}

public final class AudioEngineManager: @unchecked Sendable {
    public static let shared = AudioEngineManager()
    
    private let audioEngine = AVAudioEngine()
    private var isRunning = false
    private var configChangeObserver: NSObjectProtocol?
    
    public var onAudioLevel: (@Sendable (Float) -> Void)?
    public var onAudioBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    public var onStatusMessage: (@Sendable (String) -> Void)?
    
    private init() {
        setupConfigurationObserver()
    }
    
    deinit {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    private func setupConfigurationObserver() {
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            print("[AudioEngine] 音频硬件配置发生变化，尝试重新初始化...")
            guard let self = self else { return }
            if self.isRunning {
                self.stop()
                try? self.start()
            }
        }
    }
    
    public func start() throws {
        guard !isRunning else { return }
        
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        
        // 关键防御：检查系统是否真的存在可用的麦克风输入通道
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            let msg = "未检测到音频输入设备。Mac mini 机身无内置麦克风，请连接 USB 麦克风、摄像头或蓝牙耳机。"
            print("[AudioEngine] \(msg)")
            onStatusMessage?(msg)
            throw AudioEngineError.noInputDeviceAvailable
        }
        
        // 尝试开启回声消除 (AEC)，若外接设备不支持则平滑降级
        do {
            try inputNode.setVoiceProcessingEnabled(true)
            print("[AudioEngine] VoiceProcessingIO 硬件回声消除已启用")
        } catch {
            print("[AudioEngine] VoiceProcessingIO 启用失败，降级为普通采集模式: \(error)")
        }
        
        // 关键修复：获取当前输入硬件真实的格式，并安全安装 Tap
        let recordingFormat = inputNode.inputFormat(forBus: 0)
        
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            
            // 计算音频实时音量振幅 (用于可视化动效与简易 VAD)
            if let channelData = buffer.floatChannelData?[0] {
                let frameLength = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<frameLength {
                    sum += channelData[i] * channelData[i]
                }
                let rms = sqrt(sum / Float(frameLength))
                let normalized = min(max(rms * 8.0, 0.0), 1.0)
                self.onAudioLevel?(normalized)
            }
            
            self.onAudioBuffer?(buffer)
        }
        
        audioEngine.prepare()
        try audioEngine.start()
        isRunning = true
        onStatusMessage?("麦克风正常运行中")
        print("[AudioEngine] 音频引擎成功启动，采样率: \(recordingFormat.sampleRate)Hz, 声道: \(recordingFormat.channelCount)")
    }
    
    public func stop() {
        guard isRunning else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isRunning = false
    }
}
