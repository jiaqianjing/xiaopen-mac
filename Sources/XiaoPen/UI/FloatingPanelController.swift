import AppKit
import SwiftUI

public final class FloatingPanelController: @unchecked Sendable {
    public static let shared = FloatingPanelController()
    
    private var panel: NSPanel?
    
    private init() {}
    
    @MainActor
    public func setup() {
        guard panel == nil else { return }
        
        let contentView = FloatingHUDView()
        let hostingView = NSHostingView(rootView: contentView)
        
        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        
        newPanel.level = .floating
        newPanel.isFloatingPanel = true
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = false
        newPanel.contentView = hostingView
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        self.panel = newPanel
        positionPanel()
    }
    
    @MainActor
    public func setVisible(_ visible: Bool) {
        setup()
        guard let panel = panel else { return }
        
        if visible {
            positionPanel()
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }
    
    @MainActor
    private func positionPanel() {
        guard let panel = panel, let screen = NSScreen.main else { return }
        let screenRect = screen.visibleFrame
        
        // 放置在屏幕右上方偏中位置 (类似通知中心或右上角灵动岛)
        let x = screenRect.maxX - 380 - 24
        let y = screenRect.maxY - 280 - 24
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
