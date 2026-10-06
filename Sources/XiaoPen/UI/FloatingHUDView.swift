import SwiftUI

public struct FloatingHUDView: View {
    @Bindable var appState = AppState.shared
    
    public init() {}
    
    public var body: some View {
        VStack(spacing: 16) {
            // 顶部发光球与状态指示
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.cyan.opacity(0.8), Color.purple.opacity(0.4), Color.clear],
                                center: .center,
                                startRadius: 2,
                                endRadius: 22
                            )
                        )
                        .frame(width: 36, height: 36)
                        .scaleEffect(1.0 + CGFloat(appState.audioLevel) * 0.4)
                        .animation(.easeInOut(duration: 0.15), value: appState.audioLevel)
                    
                    Circle()
                        .strokeBorder(Color.white.opacity(0.8), lineWidth: 1.5)
                        .frame(width: 14, height: 14)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("小喷")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                    Text(appState.state.rawValue)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button(action: {
                    appState.dismissHUD()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .imageScale(.medium)
                }
                .buttonStyle(.plain)
            }
            
            // 动态声波可视化
            WaveformVisualizer(
                level: appState.audioLevel,
                isSpeaking: appState.state == .speaking || appState.state == .listening
            )
            
            // 用户转写文字
            if !appState.currentTranscript.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("您说:")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text(appState.currentTranscript)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(.primary)
                        .lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.white.opacity(0.06))
                .cornerRadius(10)
            }
            
            // 回复文字
            if !appState.currentResponse.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("回答:")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.cyan)
                    Text(appState.currentResponse)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.cyan.opacity(0.08))
                .cornerRadius(10)
            }
        }
        .padding(18)
        .frame(width: 360)
        .background(.ultraThinMaterial)
        .cornerRadius(20)
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.25), radius: 24, x: 0, y: 12)
    }
}
