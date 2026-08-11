import AppKit
import SwiftUI

/// Owns the floating co-pilot panel: a small always-on-top card that stays
/// visible over the meeting window (all Spaces, full-screen apps included),
/// showing recording status and live suggestions without the main window.
@MainActor
final class OverlayController: ObservableObject {
    @Published private(set) var isShown = false

    private var panel: NSPanel?

    func toggle(state: AppState, mcp: MCPConnectionManager) {
        isShown ? hide() : show(state: state, mcp: mcp)
    }

    func show(state: AppState, mcp: MCPConnectionManager) {
        if panel == nil {
            panel = makePanel(state: state, mcp: mcp)
        }
        panel?.orderFrontRegardless()
        isShown = true
    }

    func hide() {
        panel?.orderOut(nil)
        isShown = false
    }

    private func makePanel(state: AppState, mcp: MCPConnectionManager) -> NSPanel {
        // Non-activating so clicking the overlay never steals focus from the call.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 10),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        let root = OverlayView(onClose: { [weak self] in self?.hide() })
            .environmentObject(state)
            .environmentObject(mcp)
        let hosting = NSHostingView(rootView: root)
        // Let SwiftUI drive the panel's size as content (suggestions) changes.
        hosting.setFrameSize(hosting.fittingSize)
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)

        // Top-right of the main screen, under the menu bar.
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameTopLeftPoint(NSPoint(
                x: frame.maxX - size.width - 16,
                y: frame.maxY - 8))
        }
        return panel
    }
}
