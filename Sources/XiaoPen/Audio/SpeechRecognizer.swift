import Foundation
import Speech
import AVFoundation

public final class SpeechRecognizer: @unchecked Sendable {
    public static let shared = SpeechRecognizer()
    
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    
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
        stopRecognition()
        
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        
        self.recognitionRequest = request
        self.recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                let text = result.bestTranscription.formattedString
                let isFinal = result.isFinal
                self.onTranscriptUpdate?(text, isFinal)
            }
            if error != nil {
                self.stopRecognition()
            }
        }
    }
    
    public func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        recognitionRequest?.append(buffer)
    }
    
    public func stopRecognition() {
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
    }
}
