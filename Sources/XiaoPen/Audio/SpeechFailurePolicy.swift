import Foundation

public enum SpeechFailureAction: Sendable, Equatable {
    case enableDictation
    case installLanguageAssets
    case grantSpeechRecognition
    case unsupportedLocale
    case localRecognitionUnavailable
    case retryRecognition
    case retry
    case resumeListening
    case none
}

/// A value snapshot of an SDK error; no NSError or transcript crosses callback queues.
public struct SpeechRecognitionFailure: Sendable, Equatable {
    public let domain: String
    public let code: Int
    public let message: String
    public let actionNeed: SpeechFailureAction

    public init(domain: String, code: Int, message: String) {
        self.domain = domain
        self.code = code
        self.message = message
        switch (domain, code) {
        // These mappings are documented by SFSpeechRecognitionTask.error.
        case ("kLSRErrorDomain", 201):
            actionNeed = .enableDictation
        case ("kLSRErrorDomain", 102):
            actionNeed = .installLanguageAssets
        case ("kAFAssistantErrorDomain", 1700):
            actionNeed = .grantSpeechRecognition
        case ("kAFAssistantErrorDomain", 1110):
            actionNeed = .resumeListening
        case ("kLSRErrorDomain", 301), (NSURLErrorDomain, NSURLErrorCancelled):
            actionNeed = .none
        default:
            // Unknown Apple errors are never classified as permanent from their English text.
            actionNeed = .retry
        }
    }

    private init(domain: String, code: Int, message: String, actionNeed: SpeechFailureAction) {
        self.domain = domain
        self.code = code
        self.message = message
        self.actionNeed = actionNeed
    }

    public var isBlocking: Bool {
        switch actionNeed {
        case .enableDictation, .installLanguageAssets, .grantSpeechRecognition, .unsupportedLocale,
             .localRecognitionUnavailable, .retryRecognition:
            return true
        case .retry, .resumeListening, .none:
            return false
        }
    }

    public var shouldRetry: Bool {
        actionNeed == .retry || actionNeed == .resumeListening
    }

    public var recoveryMessage: String {
        switch actionNeed {
        case .enableDictation:
            return "系统听写或 Siri 尚未启用。请在系统设置 → 键盘 → 听写中开启听写，再点“重新检测”。"
        case .installLanguageAssets:
            return "中文语音识别资源尚未安装。请在系统设置 → 键盘 → 听写中添加中文（中国大陆），联网等待语言资源准备完成，再点“重新检测”。"
        case .grantSpeechRecognition:
            return "语音识别未获授权。请在系统设置 → 隐私与安全性 → 语音识别中允许此应用，再点“重新检测”。"
        case .unsupportedLocale:
            return "此系统无法创建中文语音识别器。请检查系统听写语言是否支持中文（中国大陆），再点“重新检测”。"
        case .localRecognitionUnavailable:
            return "此系统不支持本机中文语音识别，语音采集已停止。可使用文字对话；应用不会自动改用联网识别。"
        case .retryRecognition:
            return "\(message)已连续检测到 3 次异常，请检查麦克风输入设备和系统中文听写，准备好后点“重新检测”；也可使用文字对话。"
        case .retry:
            return "语音识别中断：\(message)"
        case .resumeListening:
            return "未检测到语音，继续等待下一段语音。"
        case .none:
            return "语音识别已取消。"
        }
    }

    public static func snapshot(_ error: any Error) -> SpeechRecognitionFailure {
        let primary = error as NSError
        let original = SpeechRecognitionFailure(domain: primary.domain, code: primary.code, message: primary.localizedDescription)
        var current = primary
        var expectedInterruption: SpeechRecognitionFailure?
        // Some framework failures wrap the actionable cause in NSUnderlyingErrorKey.
        // Bound traversal even if a malformed error contains a cycle.
        for _ in 0..<4 {
            let failure = SpeechRecognitionFailure(domain: current.domain, code: current.code, message: current.localizedDescription)
            if failure.isBlocking { return failure }
            if failure.actionNeed != .retry, expectedInterruption == nil {
                expectedInterruption = failure
            }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
        return expectedInterruption ?? original
    }

    static func unsupportedLocale(_ identifier: String) -> SpeechRecognitionFailure {
        SpeechRecognitionFailure(domain: "XiaoPen.SpeechConfiguration", code: 1,
                                 message: "Unsupported recognition locale: \(identifier)", actionNeed: .unsupportedLocale)
    }

    static func localRecognitionUnavailable() -> SpeechRecognitionFailure {
        SpeechRecognitionFailure(domain: "XiaoPen.SpeechConfiguration", code: 2,
                                 message: "On-device recognition is unavailable", actionNeed: .localRecognitionUnavailable)
    }

    static func inputStalled(_ stall: SpeechInputStall) -> SpeechRecognitionFailure {
        let code: Int
        switch stall {
        case .noBuffers: code = 1
        case .inputStopped: code = 2
        case .noTranscription: code = 3
        }
        return SpeechRecognitionFailure(domain: "XiaoPen.SpeechInputHealth", code: code,
                                        message: stall.userMessage, actionNeed: .retryRecognition)
    }
}
