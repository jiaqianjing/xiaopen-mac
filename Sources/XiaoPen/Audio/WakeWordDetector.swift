import Foundation

public final class WakeWordDetector: @unchecked Sendable {
    public static let shared = WakeWordDetector()
    
    public var onWakeWordDetected: (@Sendable () -> Void)?
    
    private init() {}
    
    public func processTranscript(_ text: String, targetWakeWord: String) {
        let cleanText = text.replacingOccurrences(of: " ", with: "").lowercased()
        let cleanWakeWord = targetWakeWord.replacingOccurrences(of: " ", with: "").lowercased()
        
        if cleanText.contains(cleanWakeWord) || cleanText.contains("小喷") {
            onWakeWordDetected?()
        }
    }
}
