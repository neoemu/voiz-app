import Combine
import SwiftUI

/// Estado compartilhado entre o serviço `NotchOverlay` e a view desenhada no painel.
@MainActor
final class NotchOverlayModel: ObservableObject {
    struct Toast: Equatable {
        let id: UUID
        let message: String
        let detail: String?
        let symbol: String
        let tone: NotchToastTone
        let actionLabel: String?
        let isInteractive: Bool
    }

    /// Reunião iminente do calendário (countdown compacto nas asas).
    struct CalendarCountdown: Equatable {
        let id: String
        let title: String
        let startDate: Date
        let isInProgress: Bool
    }

    /// Card "reunião detectada — gravar?" ancorado no notch.
    struct Prompt: Equatable {
        let id: UUID
        let appName: String
    }

    /// Estado contínuo de pós-processamento (diarização → transcrição → resumo).
    struct Processing: Equatable {
        let stage: NotchProcessingStage
        let meetingTitle: String
        var progress: Double?
    }

    /// Controla a abertura/retração horizontal saindo de dentro do recorte físico do notch.
    @Published var isPresented = false
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var recordingTitle = ""
    @Published var livePreviewAvailable = false
    @Published var systemAudioAvailable = true
    /// Início "virtual" da gravação: avança a cada retomada pra descontar as pausas.
    @Published var recordingStart = Date()
    /// Tempo congelado exibido enquanto a gravação está pausada.
    @Published var frozenElapsed: TimeInterval = 0
    /// Ativa largura extra simétrica nas asas quando a gravação cruza 1 hora (`1:00:00`).
    @Published var hasLongTimer = false
    @Published var audioLevel: CGFloat = 0
    @Published var microphoneLevel: CGFloat = 0
    @Published var systemAudioLevel: CGFloat = 0
    @Published var toast: Toast?
    @Published var prompt: Prompt?
    @Published var dictation: NotchDictationState?
    @Published var processing: Processing?
    @Published var calendarEvent: CalendarCountdown?
    /// Painel expandido pelo hover (gravação, pós-processamento ou calendário).
    @Published var expanded = false
    /// Cauda limpa da fala recente mostrada no painel expandido.
    @Published var liveTail: String = ""

    var hasContent: Bool {
        isRecording || toast != nil || prompt != nil || dictation != nil
            || processing != nil || calendarEvent != nil
    }

    var resolvedMode: NotchVisualMode {
        NotchOverlayLayout.resolvedMode(
            hasPrompt: prompt != nil,
            dictation: dictation,
            isRecording: isRecording,
            isProcessing: processing != nil,
            hasCalendar: calendarEvent != nil,
            hasToast: toast != nil
        )
    }
}

/// Conteúdo desenhado colado ao notch (ou como pílula flutuante em telas sem notch).
/// O vão central (`notchGap`) fica sempre vazio e simetricamente centralizado sobre
/// o hardware — o conteúdo nasce horizontalmente de dentro do notch com springs fluidos.
struct NotchOverlayView: View {
    @ObservedObject var model: NotchOverlayModel
    let notchGap: CGFloat
    let barHeight: CGFloat

    private var isNotched: Bool { notchGap > 0 }
    private var mode: NotchVisualMode { model.resolvedMode }
    private var isVisuallyOpen: Bool { model.isPresented && model.hasContent }

    private var showsPromptTray: Bool {
        isVisuallyOpen && mode == .prompt
    }

    private var showsExpandedTray: Bool {
        isVisuallyOpen && model.expanded && (mode == .recording || mode == .processing || mode == .calendar)
    }

    private var showsToastTray: Bool {
        isVisuallyOpen && model.toast != nil && !showsPromptTray && !showsExpandedTray && model.dictation == nil
    }

    private var hasTray: Bool {
        showsPromptTray || showsExpandedTray || showsToastTray
    }

    /// Largura alvo do corpo: quando oculto, retrai até exatamente `notchGap` (escondido sob o hardware).
    private var contentWidth: CGFloat {
        guard isVisuallyOpen else {
            return isNotched ? notchGap : 120
        }
        return NotchOverlayLayout.contentWidth(
            notchGap: notchGap,
            mode: mode,
            isExpanded: showsExpandedTray,
            hasToastTray: showsToastTray,
            hasLongTimer: model.hasLongTimer
        )
    }

    /// Largura exata de cada asa na faixa superior (sempre simétrica quando há notch).
    private var resolvedWingWidth: CGFloat {
        isNotched ? max(0, (contentWidth - notchGap) / 2) : 0
    }

    /// Rente à borda inferior do notch físico; pílula compacta em telas sem notch.
    private var stripHeight: CGFloat {
        isNotched ? barHeight : 32
    }

    /// Spring fluido estilo Dynamic Island: suave, orgânico e sem overshoots bruscos.
    private var morphSpring: Animation {
        .spring(response: 0.40, dampingFraction: 0.86, blendDuration: 0.14)
    }

    var body: some View {
        let bottomRadius: CGFloat = hasTray ? 20 : (isNotched ? 10 : 16)
        let topFlare: CGFloat = isNotched ? (isVisuallyOpen ? NotchOverlayLayout.topFlareRadius : 0) : 0
        let shellShape = NotchShellShape(
            isNotched: isNotched,
            topRadius: topFlare,
            bottomRadius: bottomRadius
        )

        VStack(spacing: 0) {
            VStack(spacing: 0) {
                strip
                    .opacity(isVisuallyOpen ? 1 : 0)
                    .clipped()

                if showsPromptTray {
                    promptSection
                        .transition(.opacity.combined(with: .offset(y: -4)))
                } else if showsExpandedTray {
                    expandedBody
                        .transition(.opacity.combined(with: .offset(y: -4)))
                } else if showsToastTray, let toast = model.toast {
                    toastTray(toast)
                        .transition(.opacity.combined(with: .offset(y: -4)))
                }
            }
            .frame(width: contentWidth)
            .padding(.horizontal, topFlare)
            .background(
                shellShape.fill(
                    isNotched
                        ? Color.black
                        : Color(red: 0.05, green: 0.05, blue: 0.06).opacity(0.96)
                )
            )
            .clipShape(shellShape)
            .overlay(
                shellRimOverlay(topFlare: topFlare, bottomRadius: bottomRadius)
            )
            .shadow(
                color: .black.opacity(hasTray ? 0.46 : (isNotched ? 0 : 0.24)),
                radius: hasTray ? 18 : (isNotched ? 0 : 8),
                y: hasTray ? 8 : (isNotched ? 0 : 5)
            )
            .padding(.top, isNotched ? 0 : NotchOverlayLayout.pillTopMargin)
            .opacity(isNotched ? (isVisuallyOpen ? 1 : 0.001) : (isVisuallyOpen ? 1 : 0))
            .scaleEffect(isNotched ? 1 : (isVisuallyOpen ? 1 : 0.92), anchor: .top)
            .allowsHitTesting(isVisuallyOpen)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .animation(morphSpring, value: isVisuallyOpen)
        .animation(morphSpring, value: mode)
        .animation(morphSpring, value: model.expanded)
        .animation(morphSpring, value: model.toast)
        .animation(morphSpring, value: model.prompt)
        .animation(morphSpring, value: model.isPaused)
        .animation(morphSpring, value: model.processing)
        .animation(morphSpring, value: model.hasLongTimer)
    }

    /// Borda hairline sutil: invisível no estado recolhido (para fundir 100% com o hardware
    /// preto do notch) e acende suavemente apenas nas curvas externas quando uma bandeja abre.
    @ViewBuilder
    private func shellRimOverlay(topFlare: CGFloat, bottomRadius: CGFloat) -> some View {
        if isNotched {
            NotchRimShape(topRadius: topFlare, bottomRadius: bottomRadius)
                .stroke(
                    Color.white.opacity(hasTray ? 0.12 : 0),
                    style: StrokeStyle(lineWidth: 0.75, lineCap: .round, lineJoin: .round)
                )
        } else {
            RoundedRectangle(cornerRadius: bottomRadius, style: .continuous)
                .stroke(Color.white.opacity(hasTray ? 0.14 : 0.10), lineWidth: 0.75)
        }
    }

    // MARK: - Faixa superior (asas simétricas abraçando o notch)

    private var strip: some View {
        HStack(spacing: 0) {
            if isNotched {
                // No estado compacto, abraça o recorte físico do notch; ao expandir, desliza para os cantos.
                leftWing
                    .padding(.leading, hasTray ? 16 : 6)
                    .padding(.trailing, hasTray ? 6 : 8)
                    .frame(
                        width: resolvedWingWidth,
                        alignment: hasTray ? .leading : .trailing
                    )
                Color.clear
                    .frame(width: notchGap, height: 1)
                rightWing
                    .padding(.leading, hasTray ? 6 : 8)
                    .padding(.trailing, hasTray ? 16 : 6)
                    .frame(
                        width: resolvedWingWidth,
                        alignment: hasTray ? .trailing : .leading
                    )
            } else {
                leftWing
                    .padding(.leading, 14)
                Spacer(minLength: 10)
                rightWing
                    .padding(.trailing, 14)
            }
        }
        .frame(height: stripHeight)
    }

    @ViewBuilder
    private var leftWing: some View {
        switch mode {
        case .prompt:
            HStack(spacing: 5) {
                Image(systemName: "person.2.wave.2.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(VoizTheme.accent)
                if !isNotched {
                    Text("Reunião detectada")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
            }

        case .dictation(let dictation):
            HStack(spacing: 5) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(dictation == .listening ? Color.red : VoizTheme.accent)
                    .scaleEffect(dictation == .listening ? 1.0 : 0.92)
                if !isNotched {
                    Text(dictation == .listening ? String(localized: "Ouvindo") : String(localized: "Processando"))
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1)
                }
            }

        case .recording:
            HStack(spacing: 5) {
                RecordingDot(paused: model.isPaused)
                elapsedText
            }

        case .processing:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.60)
                    .tint(.white)
                    .frame(width: 14, height: 14)
                if !isNotched, let processing = model.processing {
                    Text(processing.stage.localizedTitle)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
            }

        case .calendar:
            HStack(spacing: 5) {
                Image(systemName: "calendar")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.green)
                if !isNotched, let event = model.calendarEvent {
                    Text(event.title)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
            }

        case .toastOnly:
            if let toast = model.toast {
                Image(systemName: toast.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(toastAccentColor(toast.tone))
            }

        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var rightWing: some View {
        switch mode {
        case .prompt:
            if isNotched {
                Text("Reunião")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
            } else {
                Text("Voiz")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }

        case .dictation(let dictation):
            if dictation == .listening {
                OrganicAudioBars(
                    level: model.audioLevel,
                    tint: .white.opacity(0.92),
                    paused: false
                )
            } else {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.60)
                    .tint(.white)
                    .frame(width: 14, height: 14)
            }

        case .recording:
            HStack(spacing: 5) {
                if !model.systemAudioAvailable && !model.isPaused {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .help(String(localized: "Gravando somente o microfone"))
                }
                OrganicAudioBars(
                    level: model.isPaused ? 0 : model.audioLevel,
                    tint: model.isPaused ? .orange.opacity(0.75) : .white.opacity(0.92),
                    paused: model.isPaused
                )
            }

        case .processing:
            if let processing = model.processing {
                if let progress = processing.progress {
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.88))
                } else {
                    Image(systemName: processing.stage.symbolName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(VoizTheme.accent)
                }
            }

        case .calendar:
            if let event = model.calendarEvent {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(
                        NotchOverlayLayout.countdownLabel(
                            to: event.startDate,
                            inProgress: event.isInProgress,
                            now: context.date
                        )
                    )
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.green)
                }
            }

        case .toastOnly:
            if let toast = model.toast {
                Circle()
                    .fill(toastAccentColor(toast.tone).opacity(0.9))
                    .frame(width: 6, height: 6)
            }

        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var elapsedText: some View {
        Group {
            if model.isPaused {
                Text(NotchOverlayLayout.formatDuration(model.frozenElapsed))
            } else {
                Text(model.recordingStart, style: .timer)
            }
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(model.isPaused ? .orange.opacity(0.92) : .white.opacity(0.94))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - Bandeja expandida (hover)

    @ViewBuilder
    private var expandedBody: some View {
        switch mode {
        case .recording:
            expandedRecordingSection
        case .processing:
            expandedProcessingSection
        case .calendar:
            calendarSection
        default:
            EmptyView()
        }
    }

    private var expandedRecordingSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Cabeçalho: título da reunião + indicadores de canal (Mic e Chamada)
            HStack(spacing: 8) {
                Text(model.recordingTitle.isEmpty ? String(localized: "Reunião em andamento") : model.recordingTitle)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer(minLength: 4)

                HStack(spacing: 6) {
                    ChannelStatusBadge(
                        label: String(localized: "Mic"),
                        level: model.isPaused ? 0 : model.microphoneLevel,
                        activeColor: .green,
                        warning: false
                    )
                    ChannelStatusBadge(
                        label: model.systemAudioAvailable
                            ? String(localized: "Chamada")
                            : String(localized: "Só mic"),
                        level: model.isPaused ? 0 : model.systemAudioLevel,
                        activeColor: .cyan,
                        warning: !model.systemAudioAvailable
                    )
                }
            }

            // Corpo: fala recente (quando há prévia) ou status claro do modo de alta precisão
            Group {
                if !model.liveTail.isEmpty {
                    Text(model.liveTail)
                        .foregroundStyle(.white.opacity(0.84))
                } else if model.isPaused {
                    Text("Gravação pausada")
                        .foregroundStyle(.orange.opacity(0.85))
                } else if model.livePreviewAvailable {
                    Text("Aguardando fala…")
                        .foregroundStyle(.white.opacity(0.45))
                } else {
                    Text("Capturando áudio em alta precisão · transcrição ao encerrar")
                        .foregroundStyle(.white.opacity(0.56))
                }
            }
            .font(.system(size: 11, design: .rounded))
            .lineLimit(2)
            .lineSpacing(2)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)

            // Controles principais + atalhos de produtividade (Notas/Assistente e Abrir Voiz)
            HStack(spacing: 7) {
                NotchPillButton(
                    title: model.isPaused ? String(localized: "Retomar") : String(localized: "Pausar"),
                    symbol: model.isPaused ? "play.fill" : "pause.fill",
                    tint: .white.opacity(0.14)
                ) {
                    NotchOverlay.shared.togglePauseTapped()
                }
                NotchPillButton(
                    title: String(localized: "Parar"),
                    symbol: "stop.fill",
                    tint: .red.opacity(0.86)
                ) {
                    NotchOverlay.shared.stopTapped()
                }

                Spacer(minLength: 0)

                NotchPillButton(
                    title: String(localized: "Notas"),
                    symbol: "note.text",
                    tint: VoizTheme.accent.opacity(0.32)
                ) {
                    NotchOverlay.shared.openAssistantTapped()
                }
                NotchIconButton(
                    symbol: "arrow.up.forward.app",
                    help: String(localized: "Abrir Voiz")
                ) {
                    NotchOverlay.shared.openAppTapped()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var expandedProcessingSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let processing = model.processing {
                HStack(spacing: 8) {
                    Image(systemName: processing.stage.symbolName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(VoizTheme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(processing.stage.localizedTitle)
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if !processing.meetingTitle.isEmpty {
                            Text(processing.meetingTitle)
                                .font(.system(size: 10.5, design: .rounded))
                                .foregroundStyle(.white.opacity(0.58))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    if let progress = processing.progress {
                        Text("\(Int((progress * 100).rounded()))%")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }

                // Barra de progresso fina
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.12))
                        if let progress = processing.progress {
                            Capsule()
                                .fill(VoizTheme.accent)
                                .frame(width: max(8, proxy.size.width * CGFloat(progress)))
                        } else {
                            Capsule()
                                .fill(VoizTheme.accent.opacity(0.75))
                                .frame(width: proxy.size.width * 0.35)
                        }
                    }
                }
                .frame(height: 3.5)

                HStack {
                    NotchPillButton(
                        title: String(localized: "Abrir Voiz"),
                        symbol: "arrow.up.forward.app",
                        tint: .white.opacity(0.14)
                    ) {
                        NotchOverlay.shared.openAppTapped()
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Bandeja de Toast (compacta, abaixo do notch, clicável se houver ação)

    @ViewBuilder
    private func toastTray(_ toast: NotchOverlayModel.Toast) -> some View {
        let row = HStack(spacing: 10) {
            if mode != .toastOnly {
                Image(systemName: toast.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(toastAccentColor(toast.tone))
                    .frame(width: 22, height: 22)
                    .background(
                        Circle().fill(toastAccentColor(toast.tone).opacity(0.18))
                    )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(toast.message)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let detail = toast.detail {
                    Text(detail)
                        .font(.system(size: 10.5, design: .rounded))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            if toast.isInteractive, let label = toast.actionLabel {
                HStack(spacing: 3) {
                    Text(label)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8.5, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4.5)
                .background(Capsule().fill(toastAccentColor(toast.tone).opacity(0.85)))
            }
        }
        .padding(.horizontal, 15)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())

        if toast.isInteractive {
            Button {
                NotchOverlay.shared.toastTapped()
            } label: {
                row
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                NotchOverlay.shared.toastHoverChanged(hovering)
            }
        } else {
            row
        }
    }

    // MARK: - Prompt "reunião detectada"

    @ViewBuilder
    private var promptSection: some View {
        if let prompt = model.prompt {
            VStack(alignment: .leading, spacing: 9) {
                Text("\(prompt.appName) em chamada · gravar com o Voiz?")
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.86))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    NotchPillButton(
                        title: String(localized: "Gravar"),
                        symbol: "record.circle",
                        tint: VoizTheme.accent
                    ) {
                        NotchOverlay.shared.promptRecordTapped()
                    }
                    NotchPillButton(
                        title: String(localized: "Agora não"),
                        symbol: nil,
                        tint: .white.opacity(0.14)
                    ) {
                        NotchOverlay.shared.promptDismissTapped()
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Bloco expandido do calendário (hover no countdown)

    @ViewBuilder
    private var calendarSection: some View {
        if let event = model.calendarEvent {
            VStack(alignment: .leading, spacing: 8) {
                Text(event.title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Image(systemName: "clock")
                        .font(.system(size: 9.5))
                    Text(event.startDate, style: .time)
                }
                .font(.system(size: 10.5, design: .rounded))
                .foregroundStyle(.white.opacity(0.62))

                HStack(spacing: 8) {
                    NotchPillButton(
                        title: String(localized: "Gravar"),
                        symbol: "record.circle",
                        tint: VoizTheme.accent
                    ) {
                        NotchOverlay.shared.calendarRecordTapped()
                    }
                    NotchPillButton(
                        title: String(localized: "Agora não"),
                        symbol: nil,
                        tint: .white.opacity(0.14)
                    ) {
                        NotchOverlay.shared.calendarDismissTapped()
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func toastAccentColor(_ tone: NotchToastTone) -> Color {
        switch tone {
        case .neutral: return .white
        case .success: return .green
        case .warning: return .orange
        case .accent: return VoizTheme.accent
        }
    }
}

/// Contorno animável de "extensão do notch" (ou pílula arredondada em telas sem notch).
/// Mantém `Animatable` direto sem type-erasure para interpolar raios a 120Hz.
private struct NotchShellShape: Shape {
    let isNotched: Bool
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        guard isNotched else {
            return RoundedRectangle(cornerRadius: bottomRadius, style: .continuous).path(in: rect)
        }
        let tr = max(0, min(topRadius, rect.width / 4, rect.height / 2))
        let br = max(0, min(bottomRadius, (rect.width - 2 * tr) / 2, rect.height - tr))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + tr, y: rect.minY + tr),
            control: CGPoint(x: rect.minX + tr, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + tr, y: rect.maxY - br))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + tr + br, y: rect.maxY),
            control: CGPoint(x: rect.minX + tr, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - tr - br, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - tr, y: rect.maxY - br),
            control: CGPoint(x: rect.maxX - tr, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY + tr))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - tr, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

/// Traço aberto que acompanha apenas o contorno externo (laterais e base) do `NotchShape`,
/// sem desenhar linha branca no topo encostado na moldura física do MacBook.
private struct NotchRimShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let tr = max(0, min(topRadius, rect.width / 4, rect.height / 2))
        let br = max(0, min(bottomRadius, (rect.width - 2 * tr) / 2, rect.height - tr))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + tr, y: rect.minY + tr),
            control: CGPoint(x: rect.minX + tr, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + tr, y: rect.maxY - br))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + tr + br, y: rect.maxY),
            control: CGPoint(x: rect.minX + tr, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - tr - br, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - tr, y: rect.maxY - br),
            control: CGPoint(x: rect.maxX - tr, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY + tr))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - tr, y: rect.minY)
        )
        return path
    }
}

/// Micro-badge de atividade de canal (`Mic` / `Chamada`) no cabeçalho expandido.
private struct ChannelStatusBadge: View {
    let label: String
    let level: CGFloat
    let activeColor: Color
    let warning: Bool

    var body: some View {
        let isSpeaking = !warning && level > 0.08
        HStack(spacing: 4) {
            Circle()
                .fill(warning ? Color.orange : (isSpeaking ? activeColor : Color.white.opacity(0.3)))
                .frame(width: 5.5, height: 5.5)
                .scaleEffect(isSpeaking ? 1.18 : 1.0)
            Text(label)
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(warning ? Color.orange.opacity(0.95) : .white.opacity(isSpeaking ? 0.92 : 0.56))
        }
        .padding(.horizontal, 6.5)
        .padding(.vertical, 2.5)
        .background(
            Capsule().fill(
                warning
                    ? Color.orange.opacity(0.16)
                    : Color.white.opacity(isSpeaking ? 0.12 : 0.06)
            )
        )
        .animation(.easeOut(duration: 0.12), value: isSpeaking)
    }
}

/// Botão-pílula pro fundo preto do notch.
private struct NotchPillButton: View {
    let title: String
    let symbol: String?
    let tint: Color
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4.5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 9, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10.5)
            .padding(.vertical, 5.5)
            .background(Capsule().fill(tint.opacity(hovering ? 1.0 : 0.92)))
            .overlay(Capsule().stroke(.white.opacity(hovering ? 0.34 : 0.08), lineWidth: 0.8))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Botão circular compacto para ações secundárias (ex.: Abrir Voiz).
private struct NotchIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.82))
                .frame(width: 25, height: 23)
                .background(Capsule().fill(Color.white.opacity(hovering ? 0.22 : 0.12)))
                .overlay(Capsule().stroke(.white.opacity(hovering ? 0.32 : 0.08), lineWidth: 0.8))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// Ponto vermelho pulsante; âmbar e estático quando pausado.
private struct RecordingDot: View {
    let paused: Bool
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(paused ? Color.orange : Color.red)
            .frame(width: 6.5, height: 6.5)
            .opacity(paused ? 0.92 : (pulsing ? 0.38 : 1))
            .animation(
                paused ? .default : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                value: pulsing
            )
            .onAppear { pulsing = true }
    }
}

/// Mini-visualizador orgânico: 5 barras com defasagem natural por pulso de áudio,
/// sem timer ocioso quando o canal está em silêncio.
private struct OrganicAudioBars: View {
    let level: CGFloat
    let tint: Color
    let paused: Bool

    @State private var tick: Int = 0
    private let barCount = 5

    var body: some View {
        HStack(alignment: .center, spacing: 2.2) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(tint)
                    .frame(width: 2.3, height: barHeight(for: index))
            }
        }
        .frame(height: 15)
        .animation(.easeOut(duration: 0.11), value: level)
        .animation(.easeOut(duration: 0.14), value: paused)
        .onChange(of: level) { _, newValue in
            if newValue > 0.03 {
                tick &+= 1
            }
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        guard !paused else { return 3 }
        let baseProfile: [CGFloat] = [0.46, 0.78, 1.0, 0.82, 0.50]
        let phase = Double(tick) * 0.9 + Double(index) * 1.25
        let organicWave = CGFloat(0.74 + 0.26 * sin(phase))
        let base: CGFloat = 3
        let maxExtra: CGFloat = 11.5
        return base + maxExtra * level * baseProfile[index % baseProfile.count] * organicWave
    }
}
