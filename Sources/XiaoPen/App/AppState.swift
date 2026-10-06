import Foundation
import Observation
import AVFoundation

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
                    WakeWordDetector.shared.processTranscript(transcript, targetWakeWord: wakeWord)
                } else if self.state == .listening {
                    self.currentTranscript = transcript
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
    
    public func startEngine() {
        do {
            try AudioEngineManager.shared.start()
            SpeechRecognizer.shared.startRecognition()
        } catch {
            errorMessage = "麦克风启动失败: \(error.localizedDescription)"
        }
    }
    
    public func triggerWakeUp() {
        interrupt()
        state = .listening
        currentTranscript = ""
        currentResponse = ""
        isHUDVisible = true
        dismissTimer?.invalidate()
        
        // 播放提示音或轻微语音交互
        SpeechRecognizer.shared.startRecognition()
        resetSilenceTimer(timeout: 4.5)
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
