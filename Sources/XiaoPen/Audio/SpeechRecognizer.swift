import Foundation
import Speech
import AVFoundation

public final class SpeechRecognizer: @unchecked Sendable {
    public static let shared = SpeechRecognizer()
    
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var currentTaskID: UUID?
    
    public var onTranscriptUpdate: (@Sendable (String, Bool) -> Void)?
    
    private init() {
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    }
    
    public static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
    
    public func startRecognition() {
        let taskID = UUID()
        self.currentTaskID = taskID
        
        cleanupCurrentTask()
        
        guard let recognizer = recognizer, recognizer.isAvailable else {
            print("[SpeechRecognizer] 识别引擎不可用")
            return
        }
        
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        
        self.recognitionRequest = request
        self.recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            
            // 关键保护：忽略被取消的旧任务回调，避免新任务被误杀
            guard self.currentTaskID == taskID else { return }
            
            if let result = result {
                let text = result.bestTranscription.formattedString
                let isFinal = result.isFinal
                self.onTranscriptUpdate?(text, isFinal)
            }
            if error != nil {
                if self.currentTaskID == taskID {
                    self.cleanupCurrentTask()
                }
            }
        }
        print("[SpeechRecognizer] 新一轮语音识别已启动 [\(taskID.uuidString.prefix(6))]")
    }
    
    public func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        recognitionRequest?.append(buffer)
    }
    
    private func cleanupCurrentTask() {
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
    }
    
    public func stopRecognition() {
        currentTaskID = nil
        cleanupCurrentTask()
    }
}
