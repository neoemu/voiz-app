import AppKit
import SwiftUI

/// Overlay ancorado no notch do MacBook (estilo Droppy/Dynamic Island): mostra o status
/// de gravação de reunião nas "asas" ao lado do notch, toasts de conclusão ("Resumo
/// pronto ✓"), expande no hover com os bullets ao vivo + controles, e apresenta o
/// prompt "reunião detectada — gravar?". Em telas sem notch, vira uma pílula preta.
///
/// Não existe API da Apple pro notch — a técnica é um `NSPanel` borderless preto
/// posicionado exatamente sobre a região do notch, acima da menu bar, que visualmente
/// "estende" o hardware. O vão central nunca recebe conteúdo (ali é o recorte físico).
///
/// Interação: no estado passivo o painel é click-through (não pode roubar cliques da
/// menu bar). Quando expande (hover) ou mostra o prompt, o painel é redimensionado pra
/// exatamente o conteúdo e passa a aceitar mouse; ao recolher, volta a ser fantasma.
@MainActor
final class NotchOverlay {
    static let shared = NotchOverlay()

    /// Controlado pelas configurações (`notchOverlayEnabled`). Opt-in.
    var isEnabled = false

    private let model = NotchOverlayModel()
    private var panel: NSPanel?
    private var hostingView: NSHostingView<NotchOverlayView>?
    private var toastDismissTask: Task<Void, Never>?
    private var promptTimeoutTask: Task<Void, Never>?
    private var pauseBegan: Date?
    private var metrics: NotchMetrics?

    private var onTogglePause: (() -> Void)?
    private var onStop: (() -> Void)?
    private var onPromptRecord: (() -> Void)?
    private var onPromptDismiss: (() -> Void)?
    private var onCalendarRecord: (() -> Void)?
    private var onCalendarDismiss: (() -> Void)?

    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?

    /// O prompt se auto-dispensa como "agora não" (mesmo snooze do card flutuante).
    private static let promptTimeoutSeconds: UInt64 = 30

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                NotchOverlay.shared.rebuildPanelIfVisible()
            }
        }
    }

    // MARK: - Gravação

    func showRecording(
        onTogglePause: (() -> Void)? = nil,
        onStop: (() -> Void)? = nil
    ) {
        guard isEnabled else { return }
        self.onTogglePause = onTogglePause
        self.onStop = onStop
        model.isRecording = true
        model.isPaused = false
        model.expanded = false
        model.recordingStart = Date()
        model.audioLevel = 0
        model.liveTail = ""
        pauseBegan = nil
        presentPanel()
        applyPassiveLayout()
        startHoverMonitoring()
    }

    func setPaused(_ paused: Bool) {
        guard model.isRecording else { return }
        if paused {
            pauseBegan = Date()
            model.frozenElapsed = Date().timeIntervalSince(model.recordingStart)
            model.audioLevel = 0
        } else if let began = pauseBegan {
            // Empurra o início "virtual" pra frente pra descontar a pausa do cronômetro.
            model.recordingStart += Date().timeIntervalSince(began)
            pauseBegan = nil
        }
        model.isPaused = paused
    }

    func updateLevels(microphoneLevel: Float, systemAudioLevel: Float) {
        guard model.isRecording, !model.isPaused, panel?.isVisible == true else { return }
        let raw = CGFloat(max(microphoneLevel, systemAudioLevel))
        let target = min(max(raw * 12, 0), 1)
        // Ataque rápido e queda suave, igual ao MeetingRecordingIndicator.
        model.audioLevel = target >= model.audioLevel
            ? target
            : max(target, model.audioLevel * 0.72)
    }

    /// Cauda da prévia ao vivo mostrada no painel expandido: a view trunca o início,
    /// então o texto "rola" acompanhando a fala.
    func updateLivePreview(tail: String) {
        guard model.isRecording else { return }
        model.liveTail = tail
    }

    func hideRecording() {
        model.isRecording = false
        model.isPaused = false
        model.expanded = false
        model.liveTail = ""
        pauseBegan = nil
        onTogglePause = nil
        onStop = nil
        if model.prompt == nil {
            applyPassiveLayout()
        }
        stopHoverMonitoringIfUnneeded()
        dismissPanelIfIdle()
    }

    // MARK: - Ditado

    /// Espelha o RecordingHUD do ditado no notch: mic + barras enquanto ouve,
    /// spinner enquanto transcreve. Se uma reunião estiver gravando junto, o ditado
    /// tem precedência visual e a asa volta pro estado da reunião ao terminar.
    func showDictation(_ state: NotchDictationState) {
        guard isEnabled else { return }
        if state == .processing {
            model.audioLevel = 0
        }
        model.dictation = state
        presentPanel()
    }

    func updateDictationLevel(_ level: Float) {
        guard model.dictation == .listening, panel?.isVisible == true else { return }
        let target = min(max(CGFloat(level) * 12, 0), 1)
        model.audioLevel = target >= model.audioLevel
            ? target
            : max(target, model.audioLevel * 0.72)
    }

    func hideDictation() {
        guard model.dictation != nil else { return }
        model.dictation = nil
        if !model.isRecording {
            model.audioLevel = 0
        }
        dismissPanelIfIdle()
    }

    // MARK: - Countdown de calendário

    /// Reunião iminente do calendário: countdown "6m" nas asas (estilo Alcove);
    /// hover expande com título, horário e botão Gravar.
    func showCalendarCountdown(
        id: String,
        title: String,
        startDate: Date,
        isInProgress: Bool,
        onRecord: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        guard isEnabled else { return }
        onCalendarRecord = onRecord
        onCalendarDismiss = onDismiss
        model.calendarEvent = NotchOverlayModel.CalendarCountdown(
            id: id,
            title: title,
            startDate: startDate,
            isInProgress: isInProgress
        )
        presentPanel()
        // O countdown também expande no hover; liga o monitor se a gravação ainda não ligou.
        startHoverMonitoring()
    }

    func hideCalendarCountdown() {
        guard model.calendarEvent != nil else { return }
        model.calendarEvent = nil
        onCalendarRecord = nil
        onCalendarDismiss = nil
        if model.expanded, !model.isRecording {
            model.expanded = false
            applyPassiveLayout()
        }
        if !model.isRecording {
            stopHoverMonitoringIfUnneeded()
        }
        dismissPanelIfIdle()
    }

    // MARK: - Toasts

    /// Toast transitório ("Resumo pronto ✓"). Funciona mesmo sem gravação ativa;
    /// ao expirar, volta pro estado de gravação ou esconde o painel.
    func showToast(
        message: String,
        symbol: String = "checkmark.circle.fill",
        duration: TimeInterval = 3.2
    ) {
        guard isEnabled else { return }
        toastDismissTask?.cancel()
        model.toast = NotchOverlayModel.Toast(id: UUID(), message: message, symbol: symbol)
        presentPanel()
        toastDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.model.toast = nil
            self.dismissPanelIfIdle()
        }
    }

    // MARK: - Prompt "reunião detectada"

    func showMeetingPrompt(
        appName: String,
        onRecord: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        guard isEnabled else { return }
        promptTimeoutTask?.cancel()
        onPromptRecord = onRecord
        onPromptDismiss = onDismiss
        model.expanded = false
        model.prompt = NotchOverlayModel.Prompt(id: UUID(), appName: appName)
        presentPanel()
        applyInteractiveLayout(contentHeight: Self.promptContentHeight)
        promptTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.promptTimeoutSeconds * 1_000_000_000)
            guard let self, !Task.isCancelled, self.model.prompt != nil else { return }
            self.promptDismissTapped()
        }
    }

    func hideMeetingPrompt() {
        guard model.prompt != nil else { return }
        promptTimeoutTask?.cancel()
        promptTimeoutTask = nil
        model.prompt = nil
        onPromptRecord = nil
        onPromptDismiss = nil
        if !model.expanded {
            applyPassiveLayout()
        }
        dismissPanelIfIdle()
    }

    // MARK: - Ações vindas da view

    func togglePauseTapped() { onTogglePause?() }

    func stopTapped() {
        collapse()
        onStop?()
    }

    func promptRecordTapped() {
        let record = onPromptRecord
        hideMeetingPrompt()
        record?()
    }

    func promptDismissTapped() {
        let dismiss = onPromptDismiss
        hideMeetingPrompt()
        dismiss?()
    }

    func calendarRecordTapped() {
        let record = onCalendarRecord
        hideCalendarCountdown()
        record?()
    }

    func calendarDismissTapped() {
        let dismiss = onCalendarDismiss
        hideCalendarCountdown()
        dismiss?()
    }

    // MARK: - Hover (expandir/recolher)

    private func startHoverMonitoring() {
        guard globalMouseMonitor == nil else { return }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor in self?.handleMouseMoved() }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            Task { @MainActor in self?.handleMouseMoved() }
            return event
        }
    }

    /// Remove os monitores de mouse quando nenhum estado "hoverável" está ativo.
    private func stopHoverMonitoringIfUnneeded() {
        guard !model.isRecording, model.calendarEvent == nil else { return }
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMonitor = nil
        }
        if let monitor = localMouseMonitor {
            NSEvent.removeMonitor(monitor)
            localMouseMonitor = nil
        }
    }

    private func handleMouseMoved() {
        guard model.isRecording || model.calendarEvent != nil,
              model.prompt == nil,
              model.dictation == nil
        else { return }
        let location = NSEvent.mouseLocation
        if model.expanded {
            guard let frame = panel?.frame else { return }
            if !frame.insetBy(dx: -12, dy: -12).contains(location) {
                collapse()
            }
        } else if hoverTriggerRect.contains(location) {
            expand()
        }
    }

    /// Asa visível da faixa recolhida (ponto + cronômetro ≈ barras + paddings). A zona
    /// de hover cobre só isso — usar a largura do painel expandido dispararia a
    /// expansão bem antes do mouse chegar perto do notch.
    private static let hoverWingWidth: CGFloat = 95

    /// Faixa do notch + asas que dispara a expansão no hover.
    private var hoverTriggerRect: NSRect {
        guard let metrics else { return .zero }
        let screenFrame = metrics.screen.frame
        let width = metrics.notchGap + 2 * Self.hoverWingWidth
        let height = metrics.barHeight + 2
        return NSRect(
            x: screenFrame.midX - width / 2,
            y: screenFrame.maxY - height,
            width: width,
            height: height
        )
    }

    /// Cauda de 3 linhas + controles + paddings.
    private static let expandedContentHeight: CGFloat = 116
    /// Linha de texto + botões + paddings.
    private static let promptContentHeight: CGFloat = 92
    /// Título + horário + botões + paddings.
    private static let calendarContentHeight: CGFloat = 104

    private func expand() {
        guard !model.expanded else { return }
        applyInteractiveLayout(
            contentHeight: model.isRecording ? Self.expandedContentHeight : Self.calendarContentHeight
        )
        model.expanded = true
    }

    private func collapse() {
        guard model.expanded else { return }
        model.expanded = false
        // Espera a animação de recolhimento antes de voltar ao layout fantasma.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !self.model.expanded, self.model.prompt == nil else { return }
            self.applyPassiveLayout()
        }
    }

    // MARK: - Painel

    private func presentPanel() {
        if panel == nil {
            createPanel()
        }
        panel?.orderFrontRegardless()
    }

    private var hasActiveContent: Bool {
        model.isRecording || model.toast != nil || model.prompt != nil
            || model.dictation != nil || model.calendarEvent != nil
    }

    private func dismissPanelIfIdle() {
        guard !hasActiveContent else { return }
        // Espera a animação de saída da view antes de esconder a janela.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let self, !self.hasActiveContent else { return }
            self.panel?.orderOut(nil)
        }
    }

    private func rebuildPanelIfVisible() {
        guard panel?.isVisible == true else {
            panel = nil
            hostingView = nil
            metrics = nil
            return
        }
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
        metrics = nil
        presentPanel()
        if model.prompt != nil {
            applyInteractiveLayout(contentHeight: Self.promptContentHeight)
        } else if model.expanded {
            applyInteractiveLayout(
                contentHeight: model.isRecording ? Self.expandedContentHeight : Self.calendarContentHeight
            )
        }
    }

    private struct NotchMetrics {
        let screen: NSScreen
        /// Largura do recorte físico; 0 = tela sem notch (modo pílula).
        let notchGap: CGFloat
        let barHeight: CGFloat
    }

    private func currentMetrics() -> NotchMetrics? {
        // Prefere a tela built-in com notch; senão, pílula na tela principal.
        if let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            let gap: CGFloat
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                gap = max(0, right.minX - left.maxX)
            } else {
                gap = 200 // largura típica do notch como fallback
            }
            return NotchMetrics(screen: screen, notchGap: gap, barHeight: screen.safeAreaInsets.top)
        }
        guard let screen = NSScreen.main else { return nil }
        let menuBarHeight = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        return NotchMetrics(screen: screen, notchGap: 0, barHeight: menuBarHeight)
    }

    /// Folga transparente ao redor do conteúdo interativo pra sombra não ser cortada.
    private static let shadowMargin: CGFloat = 24

    /// Layout fantasma: painel largo e click-through; a view só pinta o necessário
    /// (evita redimensionar a janela a cada animação de toast/indicador).
    private func applyPassiveLayout() {
        guard let metrics, let panel else { return }
        let width = min(metrics.notchGap + 560, metrics.screen.frame.width)
        setFrame(width: width, height: metrics.barHeight + 44)
        panel.ignoresMouseEvents = true
    }

    /// Layout interativo: painel do tamanho do conteúdo + folga de sombra (área
    /// transparente maior engoliria cliques de outras janelas) e aceitando mouse.
    private func applyInteractiveLayout(contentHeight: CGFloat) {
        guard let metrics, let panel else { return }
        let width = metrics.notchGap
            + 2 * NotchOverlayView.interactiveWingWidth
            + 2 * NotchOverlayView.topFlareRadius
            + 2 * Self.shadowMargin
        setFrame(width: width, height: metrics.barHeight + contentHeight + Self.shadowMargin)
        panel.ignoresMouseEvents = false
    }

    private func setFrame(width: CGFloat, height: CGFloat) {
        guard let metrics, let panel else { return }
        let frame = NSRect(
            x: metrics.screen.frame.midX - width / 2,
            y: metrics.screen.frame.maxY - height,
            width: width,
            height: height
        )
        panel.setFrame(frame, display: true)
    }

    private func createPanel() {
        guard let metrics = currentMetrics() else { return }
        self.metrics = metrics

        let width = min(metrics.notchGap + 560, metrics.screen.frame.width)
        let height = metrics.barHeight + 44
        let origin = NSPoint(
            x: metrics.screen.frame.midX - width / 2,
            y: metrics.screen.frame.maxY - height
        )

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: NSSize(width: width, height: height)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isMovable = false

        let rootView = NotchOverlayView(
            model: model,
            notchGap: metrics.notchGap,
            barHeight: metrics.barHeight
        )
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = panel.contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        self.hostingView = hosting
        self.panel = panel
    }
}
