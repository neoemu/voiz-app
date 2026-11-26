import AppKit
import SwiftUI

/// Overlay ancorado no notch do MacBook (estilo Dynamic Island): mostra status de
/// gravação de reunião, pós-processamento contínuo, ditado, countdown de calendário,
/// toasts compactos abaixo do notch (inclusive clicáveis) e prompt "reunião detectada".
/// Em Macs sem notch físico, renderiza como pílula flutuante limpa abaixo da menu bar.
///
/// Fluidez:
/// - O `NSPanel` usa um canvas fixo dimensionado uma única vez por tela: nunca chama
///   `setFrame` durante entradas, expansões ou recolhimentos, permitindo springs nativos
///   a 120Hz sem saltos de janela.
/// - No estado passivo o painel é `ignoresMouseEvents = true` (100% click-through).
///   Quando interativo (expandido, prompt ou toast acionável), a janela transparente do
///   macOS repassa cliques fora do corpo preto automaticamente por alpha hit-testing.
@MainActor
final class NotchOverlay {
    static let shared = NotchOverlay()

    /// Controlado pelas configurações (`notchOverlayEnabled`). Opt-in.
    /// Desligar limpa imediatamente qualquer overlay ou monitor ativo.
    var isEnabled = false {
        didSet {
            if !isEnabled {
                resetAndHideImmediately()
            }
        }
    }

    private let model = NotchOverlayModel()
    private var panel: NSPanel?
    private var hostingView: NSHostingView<NotchOverlayView>?
    private var toastDismissTask: Task<Void, Never>?
    private var promptTimeoutTask: Task<Void, Never>?
    private var hoverOpenTask: Task<Void, Never>?
    private var hoverCloseTask: Task<Void, Never>?
    private var interactiveReturnTask: Task<Void, Never>?
    private var idleDismissTask: Task<Void, Never>?
    private var longTimerCheckTask: Task<Void, Never>?
    private var pauseBegan: Date?
    private var metrics: NotchMetrics?

    private var onTogglePause: (() -> Void)?
    private var onStop: (() -> Void)?
    private var onOpenAssistant: (() -> Void)?
    private var onOpenApp: (() -> Void)?
    private var onPromptRecord: (() -> Void)?
    private var onPromptDismiss: (() -> Void)?
    private var onCalendarRecord: (() -> Void)?
    private var onCalendarDismiss: (() -> Void)?
    private var onToastTap: (() -> Void)?
    private var onProcessingOpenApp: (() -> Void)?
    private var isHoveringToast = false

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
        title: String = "",
        initialElapsed: TimeInterval = 0,
        livePreviewAvailable: Bool = false,
        systemAudioAvailable: Bool = true,
        onTogglePause: (() -> Void)? = nil,
        onStop: (() -> Void)? = nil,
        onOpenAssistant: (() -> Void)? = nil,
        onOpenApp: (() -> Void)? = nil
    ) {
        guard isEnabled else { return }
        cancelHoverTimers()
        idleDismissTask?.cancel()
        self.onTogglePause = onTogglePause
        self.onStop = onStop
        self.onOpenAssistant = onOpenAssistant
        self.onOpenApp = onOpenApp

        let elapsed = max(0, initialElapsed)
        let wasVisible = panel?.isVisible == true && model.isPresented
        presentPanel(startingCollapsed: !wasVisible)

        model.isRecording = true
        model.isPaused = false
        model.expanded = false
        model.recordingTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        model.livePreviewAvailable = livePreviewAvailable
        model.systemAudioAvailable = systemAudioAvailable
        model.recordingStart = Date().addingTimeInterval(-elapsed)
        model.frozenElapsed = elapsed
        model.hasLongTimer = elapsed >= 3600
        model.audioLevel = 0
        model.microphoneLevel = 0
        model.systemAudioLevel = 0
        model.liveTail = ""
        pauseBegan = nil

        if wasVisible {
            model.isPresented = true
            syncMouseInteractivity()
        } else {
            animatePresentation()
        }

        startHoverMonitoring()
        scheduleLongTimerCheck()
    }

    func updateRecordingTitle(_ title: String) {
        guard model.isRecording else { return }
        model.recordingTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func setPaused(_ paused: Bool) {
        guard model.isRecording else { return }
        if paused {
            pauseBegan = Date()
            model.frozenElapsed = Date().timeIntervalSince(model.recordingStart)
            model.audioLevel = 0
            model.microphoneLevel = 0
            model.systemAudioLevel = 0
        } else if let began = pauseBegan {
            // Empurra o início "virtual" pra frente pra descontar a pausa do cronômetro.
            model.recordingStart += Date().timeIntervalSince(began)
            pauseBegan = nil
        }
        model.isPaused = paused
        scheduleLongTimerCheck()
    }

    func updateLevels(microphoneLevel: Float, systemAudioLevel: Float) {
        guard model.isRecording, !model.isPaused, panel?.isVisible == true else { return }
        model.microphoneLevel = NotchOverlayLayout.smoothedAudioLevel(
            raw: microphoneLevel,
            current: model.microphoneLevel
        )
        model.systemAudioLevel = NotchOverlayLayout.smoothedAudioLevel(
            raw: systemAudioLevel,
            current: model.systemAudioLevel
        )
        model.audioLevel = max(model.microphoneLevel, model.systemAudioLevel)
    }

    /// Cauda da prévia ao vivo mostrada no painel expandido.
    func updateLivePreview(tail: String) {
        guard model.isRecording else { return }
        model.liveTail = NotchOverlayLayout.cleanLiveTail(tail)
    }

    func hideRecording() {
        cancelHoverTimers()
        longTimerCheckTask?.cancel()
        longTimerCheckTask = nil
        model.isRecording = false
        model.isPaused = false
        model.expanded = false
        model.recordingTitle = ""
        model.liveTail = ""
        model.hasLongTimer = false
        model.audioLevel = 0
        model.microphoneLevel = 0
        model.systemAudioLevel = 0
        pauseBegan = nil
        onTogglePause = nil
        onStop = nil
        onOpenAssistant = nil
        onOpenApp = nil

        syncMouseInteractivity()
        stopHoverMonitoringIfUnneeded()
        dismissPanelIfIdle()
    }

    // MARK: - Pós-processamento contínuo

    /// Mantém feedback discreto no notch entre o fim da gravação e a entrega do resumo.
    func showProcessing(
        stage: NotchProcessingStage,
        meetingTitle: String = "",
        progress: Double? = nil,
        onOpenApp: (() -> Void)? = nil
    ) {
        guard isEnabled else { return }
        idleDismissTask?.cancel()
        if let onOpenApp {
            self.onProcessingOpenApp = onOpenApp
        }
        let wasVisible = panel?.isVisible == true && model.isPresented
        presentPanel(startingCollapsed: !wasVisible)

        let cleanedTitle = meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        model.processing = NotchOverlayModel.Processing(
            stage: stage,
            meetingTitle: cleanedTitle.isEmpty ? (model.processing?.meetingTitle ?? "") : cleanedTitle,
            progress: progress.map { min(max($0, 0), 1) }
        )
        if wasVisible {
            model.isPresented = true
            syncMouseInteractivity()
        } else {
            animatePresentation()
        }
        startHoverMonitoring()
    }

    func updateProcessingProgress(_ progress: Double?) {
        guard var current = model.processing else { return }
        current.progress = progress.map { min(max($0, 0), 1) }
        model.processing = current
    }

    func hideProcessing() {
        guard model.processing != nil else { return }
        model.processing = nil
        onProcessingOpenApp = nil
        if model.expanded, !model.isRecording, model.calendarEvent == nil {
            model.expanded = false
        }
        syncMouseInteractivity()
        stopHoverMonitoringIfUnneeded()
        dismissPanelIfIdle()
    }

    // MARK: - Ditado

    /// Espelha o RecordingHUD do ditado no notch: mic + barras orgânicas enquanto ouve,
    /// spinner enquanto transcreve. Se uma reunião estiver gravando junto, o ditado
    /// tem precedência visual e a asa volta pro estado da reunião ao terminar.
    func showDictation(_ state: NotchDictationState) {
        guard isEnabled else { return }
        idleDismissTask?.cancel()
        let wasVisible = panel?.isVisible == true && model.isPresented
        presentPanel(startingCollapsed: !wasVisible)

        if state == .processing {
            model.audioLevel = 0
        }
        if model.expanded {
            model.expanded = false
        }
        model.dictation = state
        if wasVisible {
            model.isPresented = true
            syncMouseInteractivity()
        } else {
            animatePresentation()
        }
    }

    func updateDictationLevel(_ level: Float) {
        guard model.dictation == .listening, panel?.isVisible == true else { return }
        model.audioLevel = NotchOverlayLayout.smoothedAudioLevel(
            raw: level,
            current: model.audioLevel
        )
    }

    func hideDictation() {
        guard model.dictation != nil else { return }
        model.dictation = nil
        if !model.isRecording {
            model.audioLevel = 0
        }
        syncMouseInteractivity()
        dismissPanelIfIdle()
    }

    // MARK: - Countdown de calendário

    /// Reunião iminente do calendário: countdown "6m" nas asas; hover expande com
    /// título, horário e botão Gravar.
    func showCalendarCountdown(
        id: String,
        title: String,
        startDate: Date,
        isInProgress: Bool,
        onRecord: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        guard isEnabled else { return }
        idleDismissTask?.cancel()
        onCalendarRecord = onRecord
        onCalendarDismiss = onDismiss

        let wasVisible = panel?.isVisible == true && model.isPresented
        presentPanel(startingCollapsed: !wasVisible)

        model.calendarEvent = NotchOverlayModel.CalendarCountdown(
            id: id,
            title: title,
            startDate: startDate,
            isInProgress: isInProgress
        )
        if wasVisible {
            model.isPresented = true
            syncMouseInteractivity()
        } else {
            animatePresentation()
        }
        startHoverMonitoring()
    }

    func hideCalendarCountdown() {
        guard model.calendarEvent != nil else { return }
        model.calendarEvent = nil
        onCalendarRecord = nil
        onCalendarDismiss = nil
        if model.expanded, !model.isRecording, model.processing == nil {
            model.expanded = false
        }
        syncMouseInteractivity()
        stopHoverMonitoringIfUnneeded()
        dismissPanelIfIdle()
    }

    // MARK: - Toasts

    /// Toast transitório exibido na bandeja compacta logo abaixo do notch (sem esticar a menu bar).
    /// Quando `onTap` é fornecido, o toast aceita clique e pausa o auto-dismiss durante o hover.
    func showToast(
        message: String,
        detail: String? = nil,
        symbol: String = "checkmark.circle.fill",
        tone: NotchToastTone? = nil,
        actionLabel: String? = nil,
        duration: TimeInterval = 3.4,
        onTap: (() -> Void)? = nil
    ) {
        guard isEnabled else { return }
        idleDismissTask?.cancel()
        toastDismissTask?.cancel()
        isHoveringToast = false
        onToastTap = onTap

        let wasVisible = panel?.isVisible == true && model.isPresented
        presentPanel(startingCollapsed: !wasVisible)

        let resolvedTone = tone ?? Self.inferredTone(for: symbol)
        let cleanedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        model.toast = NotchOverlayModel.Toast(
            id: UUID(),
            message: message,
            detail: cleanedDetail?.isEmpty == true ? nil : cleanedDetail,
            symbol: symbol,
            tone: resolvedTone,
            actionLabel: onTap != nil ? (actionLabel ?? String(localized: "Abrir")) : nil,
            isInteractive: onTap != nil
        )
        if wasVisible {
            model.isPresented = true
            syncMouseInteractivity()
        } else {
            animatePresentation()
        }
        scheduleToastDismiss(after: duration)
    }

    func dismissToast() {
        toastDismissTask?.cancel()
        toastDismissTask = nil
        isHoveringToast = false
        onToastTap = nil
        guard model.toast != nil else { return }
        model.toast = nil
        scheduleInteractiveReturnOrSync()
        dismissPanelIfIdle()
    }

    func toastTapped() {
        let action = onToastTap
        dismissToast()
        action?()
    }

    func toastHoverChanged(_ hovering: Bool) {
        guard model.toast?.isInteractive == true else { return }
        isHoveringToast = hovering
        if hovering {
            toastDismissTask?.cancel()
        } else {
            scheduleToastDismiss(after: NotchOverlayLayout.toastResumeAfterHoverDuration)
        }
    }

    private func scheduleToastDismiss(after duration: TimeInterval) {
        toastDismissTask?.cancel()
        toastDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.2, duration) * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.isHoveringToast else { return }
            self.dismissToast()
        }
    }

    private static func inferredTone(for symbol: String) -> NotchToastTone {
        if symbol.contains("exclamationmark") || symbol.contains("xmark") {
            return .warning
        }
        if symbol.contains("checkmark") {
            return .success
        }
        if symbol.contains("clipboard") || symbol.contains("sparkles") {
            return .accent
        }
        return .neutral
    }

    // MARK: - Prompt "reunião detectada"

    func showMeetingPrompt(
        appName: String,
        onRecord: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        guard isEnabled else { return }
        idleDismissTask?.cancel()
        cancelHoverTimers()
        promptTimeoutTask?.cancel()
        onPromptRecord = onRecord
        onPromptDismiss = onDismiss

        let wasVisible = panel?.isVisible == true && model.isPresented
        presentPanel(startingCollapsed: !wasVisible)

        model.expanded = false
        model.prompt = NotchOverlayModel.Prompt(id: UUID(), appName: appName)
        if wasVisible {
            model.isPresented = true
            syncMouseInteractivity()
        } else {
            animatePresentation()
        }

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
        scheduleInteractiveReturnOrSync()
        dismissPanelIfIdle()
    }

    // MARK: - Ações vindas da view

    func togglePauseTapped() { onTogglePause?() }

    func stopTapped() {
        collapseImmediately()
        onStop?()
    }

    func openAssistantTapped() {
        collapseImmediately()
        onOpenAssistant?()
    }

    func openAppTapped() {
        collapseImmediately()
        if model.isRecording {
            onOpenApp?()
        } else {
            onProcessingOpenApp?()
        }
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

    // MARK: - Hover (expandir/recolher com intenção e graça de saída)

    private var canExpandOnHover: Bool {
        guard model.prompt == nil, model.dictation == nil else { return false }
        return model.isRecording || model.processing != nil || model.calendarEvent != nil
    }

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
        guard !model.isRecording, model.processing == nil, model.calendarEvent == nil else { return }
        cancelHoverTimers()
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMonitor = nil
        }
        if let monitor = localMouseMonitor {
            NSEvent.removeMonitor(monitor)
            localMouseMonitor = nil
        }
    }

    private func cancelHoverTimers() {
        hoverOpenTask?.cancel()
        hoverOpenTask = nil
        hoverCloseTask?.cancel()
        hoverCloseTask = nil
    }

    private func handleMouseMoved() {
        guard canExpandOnHover else {
            cancelHoverTimers()
            return
        }
        let location = NSEvent.mouseLocation
        if model.expanded {
            // Usa o retângulo real do conteúdo expandido (não o canvas fixo do NSPanel).
            let safeZone = currentExpandedRect.insetBy(dx: -10, dy: -10)
            if safeZone.contains(location) || currentHoverTriggerRect.contains(location) {
                hoverCloseTask?.cancel()
                hoverCloseTask = nil
            } else if hoverCloseTask == nil {
                hoverCloseTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: NotchOverlayLayout.hoverCloseDelayNanoseconds)
                    guard let self, !Task.isCancelled, self.model.expanded else { return }
                    self.collapse()
                }
            }
        } else {
            // Nunca expande enquanto o usuário está arrastando janela ou selecionando texto.
            guard NSEvent.pressedMouseButtons == 0 else {
                hoverOpenTask?.cancel()
                hoverOpenTask = nil
                return
            }
            if currentHoverTriggerRect.contains(location) {
                if hoverOpenTask == nil {
                    hoverOpenTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: NotchOverlayLayout.hoverOpenDelayNanoseconds)
                        guard let self, !Task.isCancelled,
                              !self.model.expanded,
                              self.canExpandOnHover,
                              NSEvent.pressedMouseButtons == 0,
                              self.currentHoverTriggerRect.contains(NSEvent.mouseLocation)
                        else { return }
                        self.hoverOpenTask = nil
                        self.expand()
                    }
                }
            } else {
                hoverOpenTask?.cancel()
                hoverOpenTask = nil
            }
        }
    }

    private var currentHoverTriggerRect: NSRect {
        guard let metrics else { return .zero }
        let wing = NotchOverlayLayout.symmetricWingWidth(
            for: model.resolvedMode,
            isExpanded: false,
            hasLongTimer: model.hasLongTimer
        )
        return NotchOverlayLayout.hoverTriggerRect(
            screenFrame: metrics.screen.frame,
            notchGap: metrics.notchGap,
            barHeight: metrics.barHeight,
            wingWidth: wing
        )
    }

    private var currentExpandedRect: NSRect {
        guard let metrics else { return .zero }
        return NotchOverlayLayout.expandedContentRect(
            screenFrame: metrics.screen.frame,
            notchGap: metrics.notchGap,
            barHeight: metrics.barHeight,
            mode: model.resolvedMode
        )
    }

    private func expand() {
        guard !model.expanded else { return }
        interactiveReturnTask?.cancel()
        hoverCloseTask?.cancel()
        hoverCloseTask = nil
        model.expanded = true
        syncMouseInteractivity()
    }

    private func collapse() {
        guard model.expanded else { return }
        cancelHoverTimers()
        model.expanded = false
        scheduleInteractiveReturnOrSync()
    }

    private func collapseImmediately() {
        cancelHoverTimers()
        guard model.expanded else { return }
        model.expanded = false
        scheduleInteractiveReturnOrSync()
    }

    private func scheduleInteractiveReturnOrSync() {
        interactiveReturnTask?.cancel()
        if needsInteractivePanel {
            syncMouseInteractivity()
            return
        }
        // Libera click-through imediatamente ao recolher (o painel nunca redimensiona).
        syncMouseInteractivity()
    }

    /// Atualiza `hasLongTimer` automaticamente quando a gravação cruza 1h (mantém asas simétricas).
    private func scheduleLongTimerCheck() {
        longTimerCheckTask?.cancel()
        guard model.isRecording, !model.isPaused else { return }
        let elapsed = Date().timeIntervalSince(model.recordingStart)
        if elapsed >= 3600 {
            model.hasLongTimer = true
            return
        }
        let remaining = max(1, 3600 - elapsed)
        longTimerCheckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            guard let self, !Task.isCancelled, self.model.isRecording else { return }
            self.model.hasLongTimer = true
        }
    }

    // MARK: - Painel (canvas fixo para springs 120Hz sem saltos)

    private var needsInteractivePanel: Bool {
        if model.prompt != nil { return true }
        if model.expanded && (model.isRecording || model.processing != nil || model.calendarEvent != nil) {
            return true
        }
        if model.toast?.isInteractive == true && model.dictation == nil {
            return true
        }
        return false
    }

    private func presentPanel(startingCollapsed: Bool) {
        idleDismissTask?.cancel()
        if panel == nil {
            createPanel()
        }
        if startingCollapsed {
            model.isPresented = false
        }
        panel?.orderFrontRegardless()
    }

    /// Dispara a abertura horizontal suave saindo de dentro do recorte físico do notch.
    private func animatePresentation() {
        syncMouseInteractivity()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.model.hasContent else { return }
            self.model.isPresented = true
            self.syncMouseInteractivity()
        }
    }

    private func syncMouseInteractivity() {
        panel?.ignoresMouseEvents = !needsInteractivePanel
    }

    private func dismissPanelIfIdle() {
        guard !model.hasContent else { return }
        model.isPresented = false
        syncMouseInteractivity()
        idleDismissTask?.cancel()
        idleDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: NotchOverlayLayout.idleHideDelayNanoseconds)
            guard let self, !Task.isCancelled, !self.model.hasContent else { return }
            self.panel?.orderOut(nil)
        }
    }

    private func resetAndHideImmediately() {
        cancelHoverTimers()
        toastDismissTask?.cancel()
        promptTimeoutTask?.cancel()
        interactiveReturnTask?.cancel()
        idleDismissTask?.cancel()
        longTimerCheckTask?.cancel()
        isHoveringToast = false

        model.isPresented = false
        model.isRecording = false
        model.isPaused = false
        model.expanded = false
        model.recordingTitle = ""
        model.liveTail = ""
        model.hasLongTimer = false
        model.audioLevel = 0
        model.microphoneLevel = 0
        model.systemAudioLevel = 0
        model.dictation = nil
        model.processing = nil
        model.calendarEvent = nil
        model.toast = nil
        model.prompt = nil

        onTogglePause = nil
        onStop = nil
        onOpenAssistant = nil
        onOpenApp = nil
        onPromptRecord = nil
        onPromptDismiss = nil
        onCalendarRecord = nil
        onCalendarDismiss = nil
        onToastTap = nil
        onProcessingOpenApp = nil

        stopHoverMonitoringIfUnneeded()
        panel?.ignoresMouseEvents = true
        panel?.orderOut(nil)
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
        presentPanel(startingCollapsed: false)
        model.isPresented = model.hasContent
        syncMouseInteractivity()
    }

    private struct NotchMetrics {
        let screen: NSScreen
        /// Largura do recorte físico; 0 = tela sem notch (modo pílula flutuante).
        let notchGap: CGFloat
        let barHeight: CGFloat
    }

    private func currentMetrics() -> NotchMetrics? {
        // Por enquanto ancora sempre na tela built-in com notch do MacBook.
        // TODO: Futuramente suportar seguir a tela ativa em setups com monitor externo (modo pílula).
        if let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            let gap: CGFloat
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                gap = max(0, right.minX - left.maxX)
            } else {
                gap = 185 // largura típica do notch como fallback
            }
            let menuBarHeight = max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY)
            let stripHeight = NotchOverlayLayout.notchedStripHeight(
                safeAreaTop: screen.safeAreaInsets.top,
                menuBarHeight: menuBarHeight
            )
            return NotchMetrics(screen: screen, notchGap: gap, barHeight: stripHeight)
        }
        guard let screen = NSScreen.main else { return nil }
        let menuBarHeight = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        return NotchMetrics(screen: screen, notchGap: 0, barHeight: menuBarHeight)
    }

    private func createPanel() {
        guard let metrics = currentMetrics() else { return }
        self.metrics = metrics

        let width = NotchOverlayLayout.panelCanvasWidth(
            notchGap: metrics.notchGap,
            screenWidth: metrics.screen.frame.width
        )
        let height = NotchOverlayLayout.panelCanvasHeight(
            notchGap: metrics.notchGap,
            barHeight: metrics.barHeight
        )
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
