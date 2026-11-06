import AppKit
import SwiftUI

/// Painel flutuante (canto superior direito) com o card "Reunião detectada — Gravar?".
/// Mesmo espírito do RecordingHUD, mas CLICÁVEL (botões Gravar/dispensar) e não-ativante:
/// aparecer não rouba o foco da call.
@MainActor
final class MeetingDetectionPanel {
    static let shared = MeetingDetectionPanel()

    private var panel: NSPanel?
    private var hostingView: NSHostingView<MeetingDetectionCardView>?

    private init() {}

    func show(appName: String, onRecord: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        let card = MeetingDetectionCardView(appName: appName, onRecord: onRecord, onDismiss: onDismiss)

        if panel == nil {
            createPanel()
        }
        guard let panel else { return }

        if let hosting = hostingView {
            hosting.rootView = card
        } else {
            let hosting = NSHostingView(rootView: card)
            hosting.frame = panel.contentView?.bounds ?? .zero
            hosting.autoresizingMask = [.width, .height]
            panel.contentView = hosting
            hostingView = hosting
        }

        position(panel: panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func createPanel() {
        let size = MeetingDetectionCardView.panelSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // sombra desenhada pelo próprio card (SwiftUI)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        self.panel = panel
    }

    private func position(panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let x = frame.maxX - size.width - 16
        let y = frame.maxY - size.height - 12
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: false)
    }
}
