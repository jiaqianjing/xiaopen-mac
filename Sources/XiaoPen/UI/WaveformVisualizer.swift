import SwiftUI

public struct WaveformVisualizer: View {
    public let level: Float
    public let isSpeaking: Bool
    
    @State private var phase: Double = 0.0
    
    public init(level: Float, isSpeaking: Bool) {
        self.level = level
        self.isSpeaking = isSpeaking
    }
    
    public var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let width = size.width
                let height = size.height
                let midY = height / 2.0
                let currentLevel = CGFloat(max(level, 0.05))
                
                let time = timeline.date.timeIntervalSinceReferenceDate
                let dynamicPhase = time * (isSpeaking ? 5.0 : 3.0)
                
                var path = Path()
                path.move(to: CGPoint(x: 0, y: midY))
                
                let waveCount = 50
                for i in 0...waveCount {
                    let progress = CGFloat(i) / CGFloat(waveCount)
                    let x = progress * width
                    
                    // 渐弱窗口 (两头低，中间高)
                    let envelope = sin(progress * .pi)
                    let yOffset = sin(progress * 4.0 * .pi + dynamicPhase) * currentLevel * (height * 0.4) * envelope
                    
                    path.addLine(to: CGPoint(x: x, y: midY + yOffset))
                }
                
                let gradient = Gradient(colors: [
                    Color.cyan.opacity(0.8),
                    Color.blue.opacity(0.9),
                    Color.purple.opacity(0.8)
                ])
                
                context.stroke(
                    path,
                    with: .linearGradient(gradient, startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: width, y: 0)),
                    lineWidth: 3.5
                )
            }
        }
        .frame(height: 48)
    }
}
