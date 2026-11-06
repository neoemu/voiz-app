import AppKit
import Combine
import SwiftUI

/// Indicador flutuante mostrado enquanto uma reunião está sendo gravada.
/// Confirma visualmente que o Voiz segue captando mesmo quando a janela principal fica atrás
/// do Teams/Meet/Zoom. Pode ser arrastado e oferece controles no clique direito.
@MainActor
final class MeetingRecordingIndicator: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = MeetingRecordingIndicator()

    @Published private(set) var audioLevel: CGFloat = 0
    @Published private(set) var isPaused = false

    private let panelSize = NSSize(width: 36, height: 66)
    private let savedOriginKey = "meetingRecordingIndicatorOrigin"
    private var panel: NSPanel?
    private var assistantPanel: NSPanel?
    private weak var meetingViewModel: MeetingViewModel?
    private var indicatorRequested = false
    private var onTogglePause: (() -> Void)?
    private var onStop: (() -> Void)?

    private override init() {
        super.init()
    }

    func show(
        isPaused: Bool,
        viewModel: MeetingViewModel,
        onTogglePause: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) {
        meetingViewModel = viewModel
        indicatorRequested = true
        audioLevel = 0
        self.isPaused = isPaused
        self.onTogglePause = onTogglePause
        self.onStop = onStop
        if panel == nil {
            createPanel()
        }
        guard let panel else { return }
        restorePositionOrUseDefault(for: panel)
        panel.orderFrontRegardless()
    }

    func update(microphoneLevel: Float, systemAudioLevel: Float) {
        guard panel?.isVisible == true, !isPaused else { return }
        let raw = CGFloat(max(microphoneLevel, systemAudioLevel))
        let target = min(max(raw * 12, 0), 1)
        // Ataque rápido e queda suave: reage à voz sem piscar a cada buffer.
        audioLevel = target >= audioLevel
            ? target
            : max(target, audioLevel * 0.72)
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        if paused {
            audioLevel = 0
        }
    }

    func hide() {
        indicatorRequested = false
        assistantPanel?.orderOut(nil)
        assistantPanel?.contentView = nil
        assistantPanel = nil
        meetingViewModel = nil
        panel?.orderOut(nil)
        audioLevel = 0
        isPaused = false
        onTogglePause = nil
        onStop = nil
    }

    func openAssistant(viewModel: MeetingViewModel) {
        guard viewModel.activeSession != nil else { return }
        meetingViewModel = viewModel
        if let assistantPanel { assistantPanel.makeKeyAndOrderFront(nil); return }
        let assistant = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 540),
                                styleMask: [.titled, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        assistant.title = "Voiz"
        assistant.level = .floating
        assistant.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        assistant.hidesOnDeactivate = false
        assistant.isReleasedWhenClosed = false
        assistant.minSize = NSSize(width: 410, height: 380)
        assistant.contentView = NSHostingView(rootView: MeetingFloatingAssistantView(onCollapse: { [weak self] in
            self?.collapseAssistant()
        }).environmentObject(viewModel))
        if let screen = panel?.screen ?? NSScreen.main {
            let frame = screen.visibleFrame
            assistant.setFrameOrigin(NSPoint(x: frame.maxX - 478, y: max(frame.minY, frame.midY - 270)))
        }
        assistantPanel = assistant
        panel?.orderOut(nil)
        assistant.orderFrontRegardless()
    }

    private func collapseAssistant() {
        assistantPanel?.orderOut(nil)
        assistantPanel?.contentView = nil
        assistantPanel = nil
        if indicatorRequested { panel?.orderFrontRegardless() }
    }

    private func createPanel() {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.delegate = self

        let hosting = DraggableIndicatorHostingView(
            rootView: MeetingRecordingIndicatorView(indicator: self)
        )
        hosting.onActivate = { [weak self] in
            guard let self, let viewModel = self.meetingViewModel else { return }
            self.openAssistant(viewModel: viewModel)
        }
        hosting.contextMenuProvider = { [weak self] in
            self?.makeContextMenu() ?? NSMenu()
        }
        hosting.frame = NSRect(origin: .zero, size: panelSize)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        self.panel = panel
    }

    private func restorePositionOrUseDefault(for panel: NSPanel) {
        if let saved = UserDefaults.standard.array(forKey: savedOriginKey) as? [NSNumber],
           saved.count == 2 {
            let candidate = NSRect(
                x: CGFloat(truncating: saved[0]),
                y: CGFloat(truncating: saved[1]),
                width: panelSize.width,
                height: panelSize.height
            )
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(candidate) }) {
                panel.setFrame(candidate, display: false)
                return
            }
        }

        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }
        let x = visibleFrame.maxX - panelSize.width - 18
        let y = visibleFrame.midY - panelSize.height / 2
        panel.setFrame(
            NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height),
            display: false
        )
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel, notification.object as? NSWindow === panel else { return }
        UserDefaults.standard.set(
            [panel.frame.origin.x, panel.frame.origin.y],
            forKey: savedOriginKey
        )
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()

        let pauseTitle = isPaused ? "Retomar gravação" : "Pausar gravação"
        let pauseItem = NSMenuItem(
            title: pauseTitle,
            action: #selector(togglePauseFromMenu),
            keyEquivalent: ""
        )
        pauseItem.target = self
        pauseItem.image = NSImage(
            systemSymbolName: isPaused ? "play.fill" : "pause.fill",
            accessibilityDescription: pauseTitle
        )
        menu.addItem(pauseItem)

        let stopItem = NSMenuItem(
            title: "Parar e finalizar",
            action: #selector(stopFromMenu),
            keyEquivalent: ""
        )
        stopItem.target = self
        stopItem.image = NSImage(
            systemSymbolName: "stop.fill",
            accessibilityDescription: "Parar e finalizar"
        )
        menu.addItem(stopItem)

        menu.addItem(.separator())

        let openItem = NSMenuItem(
            title: "Abrir Voiz",
            action: #selector(openVoizFromMenu),
            keyEquivalent: ""
        )
        openItem.target = self
        openItem.image = NSImage(
            systemSymbolName: "macwindow",
            accessibilityDescription: "Abrir Voiz"
        )
        menu.addItem(openItem)

        return menu
    }

    @objc private func togglePauseFromMenu() {
        onTogglePause?()
    }

    @objc private func stopFromMenu() {
        onStop?()
    }

    @objc private func openVoizFromMenu() {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeKey }) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }
        NotificationCenter.default.post(
            name: Notification.Name("VoizOpenMeetingsTab"),
            object: nil
        )
    }
}

/// O painel não ativa o Voiz ao ser clicado; ele usa o primeiro clique apenas para seguir
/// o cursor, como o indicador do Granola.
private final class DraggableIndicatorHostingView<Content: View>: NSHostingView<Content> {
    var contextMenuProvider: (() -> NSMenu)?
    var onActivate: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        let start = NSEvent.mouseLocation
        window?.performDrag(with: event)
        let end = NSEvent.mouseLocation
        if hypot(start.x - end.x, start.y - end.y) < 4 { onActivate?() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?()
    }
}

private struct MeetingRecordingIndicatorView: View {
    @ObservedObject var indicator: MeetingRecordingIndicator

    private let barScale: [CGFloat] = [0.72, 1, 0.82]

    var body: some View {
        VStack(spacing: 5) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 15, height: 15)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            Capsule()
                .fill(Color.white.opacity(0.10))
                .frame(width: 14, height: 0.5)

            HStack(alignment: .center, spacing: 2.5) {
                ForEach(barScale.indices, id: \.self) { index in
                    Capsule()
                        .fill(indicator.isPaused ? Color.orange.opacity(0.82) : VoizTheme.accent)
                        .frame(
                            width: 2,
                            height: indicator.isPaused
                                ? 4
                                : 4 + 11 * max(0.12, indicator.audioLevel) * barScale[index]
                        )
                }
            }
            .frame(height: 14)
            .animation(.easeOut(duration: 0.10), value: indicator.audioLevel)
            .animation(.easeOut(duration: 0.15), value: indicator.isPaused)
        }
        .frame(width: 32, height: 62)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color(red: 0.08, green: 0.08, blue: 0.09).opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color.white.opacity(0.11), lineWidth: 0.5)
        )
        .padding(2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(indicator.isPaused
                            ? "Gravação do Voiz pausada"
                            : "Voiz está gravando a reunião")
    }
}
