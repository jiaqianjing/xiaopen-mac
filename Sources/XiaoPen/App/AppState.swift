import Foundation
import Observation
import AVFoundation
import AppKit

public enum SpeakerState: String, Sendable {
    case idle = "待命"
    case listening = "正在倾听..."
    case thinking = "正在思考..."
    case speaking = "正在回复..."
}

@Observable
@MainActor
public final class AppState {
    public static let shared = AppState()
    
    public var state: SpeakerState = .idle
    public var audioLevel: Float = 0.0
    public var currentTranscript: String = ""
    public var currentResponse: String = ""
    public var isHUDVisible: Bool = false {
        didSet {
            FloatingPanelController.shared.setVisible(isHUDVisible)
        }
    }
    public var errorMessage: String? = nil
    
    private var silenceTimer: Timer?
    private var dismissTimer: Timer?
    private var currentTask: Task<Void, Never>?
    
    private init() {
        setupAudioPipeline()
    }
    
    private func setupAudioPipeline() {
        AudioEngineManager.shared.onAudioLevel = { [weak self] level in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.audioLevel = level
                
                // 倾听状态下简易静音检测 (VAD)
                if self.state == .listening && !self.currentTranscript.isEmpty {
                    if level > 0.08 {
                        self.resetSilenceTimer()
                    }
                }
            }
        }
        
        AudioEngineManager.shared.onAudioBuffer = { buffer in
            SpeechRecognizer.shared.appendAudioBuffer(buffer)
        }
        
        SpeechRecognizer.shared.onTranscriptUpdate = { [weak self] transcript, isFinal in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                
                if self.state == .idle {
                    // 处于待命状态时，检测唤醒词
                    let wakeWord = AppPreferences.shared.wakeWord
                    let cleanText = transcript.replacingOccurrences(of: " ", with: "")
                    
                    if cleanText.contains(wakeWord) || cleanText.contains("小喷") {
                        print("[AppState] 捕捉到唤醒词: \(transcript)")
                        
                        // 智能提取可能连着说的问题，例如“小喷小喷，今天星期几”
                        var query = ""
                        if let range = transcript.range(of: wakeWord) {
                            query = String(transcript[range.upperBound...])
                        } else if let range = transcript.range(of: "小喷") {
                            query = String(transcript[range.upperBound...])
                        }
                        query = query.trimmingCharacters(in: CharacterSet(charactersIn: "，。？！,?! "))
                        
                        self.triggerWakeUp(initialQuery: query)
                    }
                } else if self.state == .listening {
                    self.currentTranscript = transcript
                    self.resetSilenceTimer(timeout: 2.0)
                    if isFinal {
                        self.stopListeningAndProcess()
                    }
                }
            }
        }
        
        WakeWordDetector.shared.onWakeWordDetected = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if self.state == .idle {
                    self.triggerWakeUp()
                }
            }
        }
        
        SpeechSynthesizer.shared.onSpeakingStarted = { [weak self] in
            Task { @MainActor [weak self] in
                self?.state = .speaking
            }
        }
        
        SpeechSynthesizer.shared.onSpeakingFinished = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.state = .idle
                self.scheduleAutoDismiss()
            }
        }
    }
    
    public var deviceStatus: String = "正在检测设备..."
    
    public func startEngine() {
        AudioEngineManager.shared.onStatusMessage = { [weak self] msg in
            Task { @MainActor [weak self] in
                self?.deviceStatus = msg
            }
        }
        
        do {
            try AudioEngineManager.shared.start()
            SpeechRecognizer.shared.startRecognition()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            deviceStatus = error.localizedDescription
            print("[AppState] startEngine 提示: \(error.localizedDescription)")
        }
    }
    
    public func triggerWakeUp(initialQuery: String = "") {
        interrupt()
        state = .listening
        currentTranscript = initialQuery
        currentResponse = ""
        isHUDVisible = true
        dismissTimer?.invalidate()
        
        // 播放系统轻快提示音（通过耳机听到清脆的 "叮"）
        NSSound(named: "Tink")?.play()
        
        SpeechRecognizer.shared.startRecognition()
        
        if !initialQuery.isEmpty {
            // 用户一句话带出了问题，等待短暂停顿直接进入思考
            resetSilenceTimer(timeout: 1.8)
        } else {
            // 纯唤醒词，给予充足时间等待用户说话
            resetSilenceTimer(timeout: 6.0)
        }
    }
    
    public func stopListeningAndProcess() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        
        let prompt = currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            state = .idle
            scheduleAutoDismiss(delay: 1.0)
            return
        }
        
        state = .thinking
        processPrompt(prompt)
    }
    
    public func processPrompt(_ userText: String) {
        currentTask?.cancel()
        currentResponse = ""
        
        currentTask = Task {
            let prefs = AppPreferences.shared
            let provider: LLMProviderProtocol
            
            switch prefs.providerType {
            case .ollama:
                provider = OllamaProvider(baseURL: prefs.ollamaBaseURL, model: prefs.ollamaModel)
            case .anthropic:
                provider = AnthropicProvider(apiKey: prefs.anthropicAPIKey, model: prefs.anthropicModel)
            case .openAI:
                provider = OpenAIProvider(baseURL: prefs.openAIBaseURL, apiKey: prefs.openAIAPIKey, model: prefs.openAIModel)
            }
            
            do {
                let stream = try await provider.streamChat(
                    messages: [ChatMessage(role: "user", content: userText)],
                    systemPrompt: prefs.systemPrompt
                )
                
                var fullResponse = ""
                for try await chunk in stream {
                    guard !Task.isCancelled else { break }
                    fullResponse += chunk
                    self.currentResponse = fullResponse
                }
                
                if !fullResponse.isEmpty && !Task.isCancelled {
                    SpeechSynthesizer.shared.speak(text: fullResponse, rate: prefs.ttsVoiceRate)
                } else if !Task.isCancelled {
                    state = .idle
                    scheduleAutoDismiss()
                }
            } catch {
                if !Task.isCancelled {
                    self.errorMessage = "请求失败: \(error.localizedDescription)"
                    self.state = .idle
                    self.scheduleAutoDismiss()
                }
            }
        }
    }
    
    public func interrupt() {
        currentTask?.cancel()
        currentTask = nil
        SpeechSynthesizer.shared.stop()
        silenceTimer?.invalidate()
        silenceTimer = nil
        state = .idle
    }
    
    public func dismissHUD() {
        interrupt()
        isHUDVisible = false
    }
    
    private func resetSilenceTimer(timeout: TimeInterval = 1.8) {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                if self?.state == .listening {
                    self?.stopListeningAndProcess()
                }
            }
        }
    }
    
    private func scheduleAutoDismiss(delay: TimeInterval? = nil) {
        dismissTimer?.invalidate()
        let interval = delay ?? AppPreferences.shared.autoDismissSeconds
        dismissTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                if self?.state == .idle {
                    self?.isHUDVisible = false
                }
            }
        }
    }
}
