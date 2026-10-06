import Foundation
import AVFoundation

public final class AudioEngineManager: @unchecked Sendable {
    public static let shared = AudioEngineManager()
    
    private let audioEngine = AVAudioEngine()
    private var isRunning = false
    
    public var onAudioLevel: (@Sendable (Float) -> Void)?
    public var onAudioBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    
    private init() {}
    
    public func start() throws {
        guard !isRunning else { return }
        
        let inputNode = audioEngine.inputNode
        
        // 开启系统级硬件/驱动回声消除 (AEC) 与语音增强
        do {
            try inputNode.setVoiceProcessingEnabled(true)
        } catch {
            print("[AudioEngine] VoiceProcessingIO enable failed, continuing with standard mode: \(error)")
        }
        
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
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
    }
    
    public func stop() {
        guard isRunning else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isRunning = false
    }
}
