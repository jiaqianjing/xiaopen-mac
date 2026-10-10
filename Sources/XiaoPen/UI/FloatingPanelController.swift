import AppKit
import SwiftUI

/// A non-activating panel near the top-right corner. Its height follows the
/// SwiftUI content while the top edge stays put; the user can drag it elsewhere.
@MainActor
public final class FloatingPanelController {
    public static let shared = FloatingPanelController()

    private var panel: NSPanel?
    private var hasPosition = false

    private init() {}

    public func setup() {
        guard panel == nil else { return }
        let hostingView = NSHostingView(rootView: FloatingHUDView())
        let newPanel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: HUDMetrics.width, height: 160),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        newPanel.level = .floating
        newPanel.isFloatingPanel = true
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.isMovableByWindowBackground = true
        newPanel.contentView = hostingView
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel = newPanel
    }

    public func setVisible(_ visible: Bool) {
        setup()
        guard let panel else { return }
        if visible {
            if !hasPosition || !isOnScreen(panel.frame) { placeTopRight() }
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    /// Keeps the top edge fixed while the card grows or shrinks.
    func updateHeight(_ height: CGFloat) {
        guard let panel, height > 0, abs(panel.frame.height - height) > 0.5 else { return }
        var frame = panel.frame
        let top = frame.maxY
        frame.size = NSSize(width: HUDMetrics.width, height: ceil(height))
        frame.origin.y = top - frame.height
        panel.setFrame(frame, display: true, animate: false)
    }

    private func placeTopRight() {
        guard let panel, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 16,
                                     y: visible.maxY - panel.frame.height - 12))
        hasPosition = true
    }

    private func isOnScreen(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
    }
}

private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
