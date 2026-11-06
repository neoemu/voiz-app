import SwiftUI
import AppKit

enum RecordingHUDState {
    case listening
    case processing
}

final class RecordingHUD {
    static let shared = RecordingHUD()
    
    private var panel: NSPanel?
    private var hostingView: NSHostingView<RecordingHUDView>?
    private var currentState: RecordingHUDState?
    var isEnabled: Bool = true  // Controlado pelas configurações
    var showInTranslationMode: Bool = false  // NÃO mostrar na tab de tradução por padrão
    
    private init() {}
    
    func update(state: RecordingHUDState) {
        // Não mostra se desabilitado nas configurações
        guard isEnabled else { return }
        
        DispatchQueue.main.async {
            if self.panel == nil {
                self.createPanel()
            }
            
            guard let panel = self.panel else { return }
            
            self.currentState = state
            let rootView = RecordingHUDView(state: state)
            if let hosting = self.hostingView {
                hosting.rootView = rootView
            } else {
                let hosting = NSHostingView(rootView: rootView)
                hosting.frame = panel.contentView?.bounds ?? .zero
                hosting.autoresizingMask = [.width, .height]
                panel.contentView = hosting
                self.hostingView = hosting
            }
            
            panel.orderFrontRegardless()
        }
    }
    
    func hide() {
        DispatchQueue.main.async {
            self.panel?.orderOut(nil)
            self.currentState = nil
        }
    }
    
    private func createPanel() {
        // Tamanho menor e mais fino (como WhisperFlow)
        let size = NSSize(width: 120, height: 50)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = true
        
        position(panel: panel, size: size)
        
        self.panel = panel
    }
    
    private func position(panel: NSPanel, size: NSSize) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - size.width / 2
        let y = screenFrame.minY + 120
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: false)
    }
}
