import Foundation
import AVFoundation

public final class SpeechSynthesizer: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    public static let shared = SpeechSynthesizer()
    
    private let synthesizer = AVSpeechSynthesizer()
    public var onSpeakingStarted: (@Sendable () -> Void)?
    public var onSpeakingFinished: (@Sendable () -> Void)?
    
    private override init() {
        super.init()
        synthesizer.delegate = self
    }
    
    public func speak(text: String, rate: Float = 0.52) {
        stop()
        
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = rate
        utterance.pitchMultiplier = 1.05
        utterance.volume = 1.0
        
        synthesizer.speak(utterance)
    }
    
    public func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }
    
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        onSpeakingStarted?()
    }
    
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onSpeakingFinished?()
    }
    
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onSpeakingFinished?()
    }
}
