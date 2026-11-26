import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Indicador discreto para as listas mestre de reuniões. Mantém o `NSScrollView` nativo (incluindo
/// trackpad, roda e arraste), mas reduz visualmente o knob e remove a trilha larga do sistema.
private final class MeetingSlimScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override class func scrollerWidth(
        for controlSize: NSControl.ControlSize,
        scrollerStyle: NSScroller.Style
    ) -> CGFloat {
        10
    }

    override func drawKnob() {
        let knobRect = rect(for: .knob).insetBy(dx: 3, dy: 1)
        NSColor.controlTextColor.withAlphaComponent(0.42).setFill()
        NSBezierPath(roundedRect: knobRect, xRadius: 2, yRadius: 2).fill()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
}

/// Resolve o `NSScrollView` criado pelo SwiftUI a partir de uma view dentro do conteúdo.
private struct MeetingSlimScrollConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        configureScrollView(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configureScrollView(from: nsView)
    }

    private func configureScrollView(from view: NSView) {
        DispatchQueue.main.async {
            var ancestor = view.superview
            while let candidate = ancestor {
                if let scrollView = candidate as? NSScrollView {
                    scrollView.scrollerStyle = .overlay
                    scrollView.autohidesScrollers = true

                    if !(scrollView.verticalScroller is MeetingSlimScroller) {
                        let scroller = MeetingSlimScroller(frame: .zero)
                        scroller.controlSize = .mini
                        scrollView.verticalScroller = scroller
                    }
                    return
                }
                ancestor = candidate.superview
            }
        }
    }
}

struct MeetingView: View {
    @EnvironmentObject var viewModel: MeetingViewModel
    @EnvironmentObject var navigation: VoizNavigation
    @State private var viewingSessionID: UUID?

    private var reviewSession: MeetingSession? {
        guard let id = viewingSessionID else { return nil }
        return viewModel.sessions.first(where: { $0.id == id })
    }

    private var viewingFolder: MeetingFolder? {
        guard let id = viewModel.viewingFolderId else { return nil }
        return viewModel.folders.first(where: { $0.id == id })
    }

    var body: some View {
        Group {
            if let event = navigation.calendarEvent {
                MeetingScheduledView(event: event)
                    .id(event.id)
            } else if let active = viewModel.activeSession {
                MeetingLiveView(session: active)
            } else if let session = reviewSession {
                // Voltar da revisão cai na pasta quando a sessão foi aberta por ela.
                MeetingReviewView(session: session, onBack: { viewingSessionID = nil })
            } else if let folder = viewingFolder {
                MeetingFolderView(
                    folder: folder,
                    onBack: { viewModel.viewingFolderId = nil },
                    onOpen: openSession
                )
            } else {
                MeetingStartView(onOpen: openSession, onOpenFolder: { viewModel.viewingFolderId = $0 })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: viewModel.activeSession?.id) { previous, current in
            // Quando a gravação termina, cai direto na revisão da sessão recém-finalizada.
            if previous != nil && current == nil {
                viewingSessionID = viewModel.selectedSession?.id
            }
        }
        .onChange(of: viewModel.state) { _, current in
            if current == .listening { navigation.calendarEvent = nil }
        }
        // Navegação vinda da sidebar: trocar de pasta fecha a revisão aberta.
        .onChange(of: viewModel.viewingFolderId) { _, current in
            if current != nil {
                viewingSessionID = nil
                navigation.calendarEvent = nil
            }
        }
        // Resultado escolhido na busca global (⌘K).
        .onAppear(perform: consumePendingOpen)
        .onChange(of: navigation.pendingOpen, initial: false) { _, _ in consumePendingOpen() }
    }

    private func consumePendingOpen() {
        guard let id = navigation.pending(.meeting) else { return }
        openSession(id)
        navigation.clear()
    }

    private func openSession(_ id: UUID) {
        if let session = viewModel.sessions.first(where: { $0.id == id }) {
            viewModel.selectSession(session)
        }
        viewingSessionID = id
    }
}

// MARK: - Layout helpers

private enum MeetingLayout {
    static let maxWidth: CGFloat = 900
    static let startMaxWidth: CGFloat = 1_180
    static let horizontalPadding: CGFloat = 56
    static let liveHorizontalPadding: CGFloat = 32
    static let companionInlineMinWidth = MeetingReviewCompanionPresentation.dockedMinimumWidth

    static func masterDetailHorizontalPadding(for width: CGFloat) -> CGFloat {
        width < 900 ? 22 : horizontalPadding
    }

    static func masterDetailSpacing(for width: CGFloat) -> CGFloat {
        width < 900 ? 14 : 18
    }

    static func previewWidth(for width: CGFloat) -> CGFloat {
        width < 820 ? 248 : (width < 980 ? 270 : 300)
    }

    static func previewHeight(for viewport: CGSize, reservedHeight: CGFloat = 190) -> CGFloat {
        min(max(viewport.height - reservedHeight, 390), 560)
    }
}

private func meetingDurationLabel(_ duration: TimeInterval) -> String {
    let total = max(0, Int(duration))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%02d:%02d", minutes, seconds)
}

/// Cor estável por falante: microfone sempre azul; participantes recebem uma cor
/// determinística a partir do id do cluster (consistente entre relançamentos).
private func meetingSpeakerColor(source: MeetingCaptureSource, speakerId: String?) -> Color {
    if source == .microphone { return .blue }
    let palette: [Color] = [VoizTheme.accent, .purple, .teal, .orange, .pink, .green]
    guard let id = speakerId else { return VoizTheme.accent }
    let seed = id.unicodeScalars.reduce(0) { $0 + Int($1.value) }
    return palette[seed % palette.count]
}

// MARK: - Start

struct MeetingStartView: View {
    @EnvironmentObject var viewModel: MeetingViewModel
    let onOpen: (UUID) -> Void
    let onOpenFolder: (UUID) -> Void
    @State private var previewSessionID: UUID?

    private var previewSession: MeetingSession? {
        if let previewSessionID,
           let selected = viewModel.sessions.first(where: { $0.id == previewSessionID }) {
            return selected
        }
        return viewModel.sessions.first
    }

    var body: some View {
        GeometryReader { viewport in
            VStack(alignment: .leading, spacing: 22) {
                MeetingStartHeader(templateStore: viewModel.templateStore)
                    .frame(maxWidth: MeetingLayout.startMaxWidth)
                    .padding(.horizontal, MeetingLayout.masterDetailHorizontalPadding(for: viewport.size.width))
                    .padding(.top, 16)
                    .frame(maxWidth: .infinity)

                // Somente a coluna mestre rola. A prévia ocupa a altura visível e permanece ao
                // lado da reunião sob o ponteiro, mesmo depois de expandir dezenas de itens.
                HStack(alignment: .top, spacing: MeetingLayout.masterDetailSpacing(for: viewport.size.width)) {
                    ScrollView {
                        primaryColumn
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(.bottom, 40)
                            .background(MeetingSlimScrollConfigurator())
                    }
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)

                    if viewport.size.width >= 840 {
                        MeetingPreviewPanel(session: previewSession)
                            .frame(
                                width: MeetingLayout.previewWidth(for: viewport.size.width),
                                height: MeetingLayout.previewHeight(for: viewport.size),
                                alignment: .top
                            )
                    }
                }
                .frame(maxWidth: MeetingLayout.startMaxWidth)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, MeetingLayout.masterDetailHorizontalPadding(for: viewport.size.width))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { viewModel.refreshCalendarSuggestion() }
        .onChange(of: viewModel.sessions.map(\.id)) { _, ids in
            if let previewSessionID, !ids.contains(previewSessionID) {
                self.previewSessionID = ids.first
            }
        }
    }

    @ViewBuilder
    private var primaryColumn: some View {
        VStack(alignment: .leading, spacing: 28) {
            if viewModel.calendarSuggestionsEnabled {
                MeetingCalendarSuggestionCard()
                MeetingUpcomingCard()
            }

            MeetingScreenRecordingCard()

            MeetingFoldersSection(onOpenFolder: onOpenFolder)

            MeetingRecentsList(
                selectedSessionID: previewSession?.id,
                onPreview: { previewSessionID = $0 },
                onOpen: onOpen
            )
        }
    }

}

/// Pede a permissão de **Gravação de Tela** quando ela falta — é o que habilita a captura do
/// **áudio do sistema** (a faixa "Outros"). Sem ela, a voz dos participantes não é gravada e tudo
/// cai no microfone. Some assim que concedida. Reavalia ao reativar a janela (volta dos Ajustes).
struct MeetingScreenRecordingCard: View {
    @State private var granted = ScreenRecordingPermissionService.shared.isGranted

    var body: some View {
        if !granted {
            card
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    granted = ScreenRecordingPermissionService.shared.isGranted
                }
        }
    }

    private var card: some View {
        HStack(spacing: 14) {
            icon

            VStack(alignment: .leading, spacing: 3) {
                Text("Áudio do sistema")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(VoizTheme.primaryText)
                Text("Permita Gravação de Tela para gravar a voz dos participantes. Só o áudio é usado.")
                    .font(.system(size: 12))
                    .foregroundColor(VoizTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            VStack(spacing: 6) {
                Button("Conceder acesso") {
                    ScreenRecordingPermissionService.shared.requestAccess()
                    ScreenRecordingPermissionService.shared.openScreenRecordingSettings()
                }
                .buttonStyle(GranolaPillButtonStyle(accented: true))

                Button("Mostrar app") {
                    ScreenRecordingPermissionService.shared.revealAppInFinder()
                }
                .buttonStyle(GranolaPillButtonStyle())
            }
        }
        .padding(16)
        .background(VoizTheme.surfaceBackground)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(VoizTheme.border))
        .cornerRadius(12)
    }

    private var icon: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(VoizTheme.accent.opacity(0.22))
            .frame(width: 42, height: 42)
            .overlay(
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(VoizTheme.accent)
            )
    }
}

/// Onda 3 — sugestão de calendário (EventKit, on-device). Quando o toggle está ligado mas o acesso
/// não foi concedido, mostra o pedido de permissão; quando há reunião em curso/iminente, oferece
/// gravar já com o título do evento. Sem rede, sem OAuth — só lê o calendário local do Mac.
struct MeetingCalendarSuggestionCard: View {
    @EnvironmentObject var viewModel: MeetingViewModel

    var body: some View {
        if !viewModel.calendarAuthorized {
            permissionCard
        } else if let meeting = viewModel.detectedMeeting {
            suggestionCard(meeting)
        }
    }

    private var permissionCard: some View {
        HStack(spacing: 14) {
            calendarIcon

            VStack(alignment: .leading, spacing: 3) {
                Text("Sugestões de calendário")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(VoizTheme.primaryText)
                Text(viewModel.calendarAccessBlocked
                     ? "Acesso negado. Permita o Calendário para o Voiz nos Ajustes do Sistema."
                     : "Sugira gravações a partir da sua agenda.")
                    .font(.system(size: 12))
                    .foregroundColor(VoizTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if viewModel.calendarAccessBlocked {
                Button("Abrir Ajustes do Sistema") {
                    viewModel.openCalendarSettings()
                }
                .buttonStyle(GranolaPillButtonStyle(accented: true))
            } else {
                Button("Conceder acesso") {
                    Task { await viewModel.requestCalendarAccess() }
                }
                .buttonStyle(GranolaPillButtonStyle(accented: true))
            }
        }
        .padding(16)
        .background(VoizTheme.surfaceBackground)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(VoizTheme.border))
        .cornerRadius(12)
    }

    private func suggestionCard(_ meeting: DetectedMeeting) -> some View {
        HStack(spacing: 14) {
            calendarIcon

            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(VoizTheme.primaryText)
                    .lineLimit(1)
                Text(subtitle(for: meeting))
                    .font(.system(size: 12))
                    .foregroundColor(VoizTheme.mutedText)
            }

            Spacer(minLength: 8)

            Button(action: viewModel.recordDetectedMeeting) {
                Label("Gravar agora", systemImage: "record.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(GranolaPillButtonStyle(accented: true))
            .disabled(viewModel.state == .processing)

            Button(action: viewModel.dismissCalendarSuggestion) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(VoizTheme.mutedText)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(VoizTheme.accent.opacity(0.10))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(VoizTheme.accent.opacity(0.5)))
        .cornerRadius(12)
    }

    private var calendarIcon: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(VoizTheme.accent.opacity(0.22))
            .frame(width: 42, height: 42)
            .overlay(
                Image(systemName: "calendar")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(VoizTheme.accent)
            )
    }

    private func subtitle(for meeting: DetectedMeeting) -> String {
        if meeting.isInProgress {
            return String(localized: "Acontecendo agora")
        }
        let mins = meeting.minutesUntilStart
        return mins <= 1 ? String(localized: "Começa em instantes") : String(localized: "Começa em \(mins) min")
    }
}

/// Agenda local: abrir uma linha leva ao espaço da reunião, sem iniciar a captura.
struct MeetingUpcomingCard: View {
    @EnvironmentObject var viewModel: MeetingViewModel
    @EnvironmentObject var navigation: VoizNavigation
    @State private var page = 0
    private let pageSize = 5

    private var pageCount: Int { max(1, (viewModel.upcomingEvents.count + pageSize - 1) / pageSize) }

    var body: some View {
        if viewModel.calendarAuthorized {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    HomeSectionTitle("Em breve")
                    Spacer()
                    Button("Calendários") {
                        NotificationCenter.default.post(name: Notification.Name("OpenVoizSettings"), object: nil)
                    }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(VoizTheme.accent)
                    if pageCount > 1 {
                        Button { page = max(0, page - 1) } label: {
                            Image(systemName: "chevron.left")
                        }
                        .disabled(page == 0).help("Eventos anteriores")
                        .accessibilityLabel("Eventos anteriores")
                        Text("\(page + 1) / \(pageCount)")
                            .font(.caption.monospacedDigit()).foregroundStyle(VoizTheme.mutedText)
                        Button { page = min(pageCount - 1, page + 1) } label: {
                            Image(systemName: "chevron.right")
                        }
                        .disabled(page >= pageCount - 1).help("Próximos eventos")
                        .accessibilityLabel("Próximos eventos")
                    }
                }

                VStack(spacing: 0) {
                    if viewModel.upcomingEvents.isEmpty {
                        Text("Nenhum evento nos próximos 7 dias.")
                            .font(.system(size: 13)).foregroundStyle(VoizTheme.mutedText)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    }
                    ForEach(groupedDays, id: \.key) { group in
                        if group.key != groupedDays.first?.key {
                            Divider()
                        }
                        dayHeader(group.key)
                        ForEach(group.events) { event in
                            MeetingCalendarEventRow(event: event) { navigation.open(event) }
                                .padding(.horizontal, 6)
                        }
                    }
                }
                .background(VoizTheme.surfaceBackground)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(VoizTheme.border))
                .cornerRadius(12)
            }
            .onChange(of: viewModel.upcomingEvents.map(\.id)) { _, _ in
                page = min(page, pageCount - 1)
            }
        }
    }

    private func dayHeader(_ day: Date) -> some View {
        Text(Self.dayLabel(day))
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(VoizTheme.mutedText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 2)
    }

    private var groupedDays: [(key: Date, events: [CalendarEvent])] {
        let cal = Calendar.current
        let visibleEvents = viewModel.upcomingEvents.dropFirst(min(page, pageCount - 1) * pageSize).prefix(pageSize)
        let groups = Dictionary(grouping: visibleEvents) {
            cal.startOfDay(for: $0.startDate)
        }
        return groups.keys.sorted().map { key in
            (key: key, events: groups[key]!.sorted { $0.startDate < $1.startDate })
        }
    }

    private static func dayLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return String(localized: "Hoje") }
        if cal.isDateInTomorrow(date) { return String(localized: "Amanhã") }
        let f = DateFormatter()
        f.locale = .voizInterface
        f.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return f.string(from: date).capitalized
    }

}

/// Cabeçalho leve da home de reuniões. A gravação continua sendo a ação primária, mas os seletores
/// ficam num popover: a tela abre espaço para o conteúdo e para a prévia da reunião selecionada.
struct MeetingStartHeader: View {
    @EnvironmentObject var viewModel: MeetingViewModel
    @ObservedObject var templateStore: MeetingTemplateStore
    @Environment(\.voizWindowSize) private var windowSize
    @State private var showRecordingOptions = false
    @State private var showTemplateEditor = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 24) {
                titleBlock
                Spacer(minLength: 24)
                actions
            }

            VStack(alignment: .leading, spacing: 16) {
                titleBlock
                actions
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showTemplateEditor) {
            // A folha não passa da borda da janela (mínimo 640 × 560): encolhe até 600 × 500.
            MeetingTemplateEditorView(store: templateStore, size: CGSize(
                width: min(880, max(600, windowSize.width - 40)),
                height: min(620, max(500, windowSize.height - 40))
            ))
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Reuniões")
                .font(.system(size: 34, weight: .regular, design: .serif))
                .foregroundColor(VoizTheme.primaryText)
        }
    }

    private var actions: some View {
        HStack(spacing: 9) {
            Button(action: { showRecordingOptions = true }) {
                Label(configurationLabel, systemImage: "slider.horizontal.3")
                    .lineLimit(1)
            }
            .buttonStyle(GranolaPillButtonStyle())
            .popover(isPresented: $showRecordingOptions, arrowEdge: .top) {
                MeetingRecordingOptionsPopover(
                    templateStore: templateStore,
                    onManageTemplates: {
                        showRecordingOptions = false
                        showTemplateEditor = true
                    }
                )
            }
            .help("Modo e modelo da reunião")

            Button(action: viewModel.toggleRecording) {
                Label("Iniciar gravação", systemImage: "record.circle.fill")
            }
            .buttonStyle(GranolaPillButtonStyle(accented: true))
            .disabled(viewModel.state == .processing)
        }
    }

    private var configurationLabel: String {
        let template = templateStore.templates.first(where: { $0.id == viewModel.selectedTemplateId })?.menuLabel
            ?? String(localized: "Modelo")
        return "\(viewModel.meetingMode.menuLabel) · \(template)"
    }
}

/// Popover de configuração acessível pelo cabeçalho. Mantém todas as opções do cartão antigo sem
/// fazê-las competir visualmente com as pastas, a lista e a ação de iniciar a gravação.
struct MeetingRecordingOptionsPopover: View {
    @EnvironmentObject var viewModel: MeetingViewModel
    @ObservedObject var templateStore: MeetingTemplateStore
    let onManageTemplates: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Configurar gravação")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(VoizTheme.primaryText)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Modo", systemImage: "waveform.path.badge.plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(VoizTheme.mutedText)

                SettingsDropdown(
                    options: AppSettings.MeetingMode.allCases.map { (value: $0, label: $0.menuLabel) },
                    selection: $viewModel.meetingMode
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Modelo de notas", systemImage: "doc.text")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(VoizTheme.mutedText)

                SettingsDropdown(
                    options: templateStore.templates.map { (value: $0.id, label: $0.menuLabel) },
                    selection: $viewModel.selectedTemplateId
                )
            }

            Divider()

            Button(action: onManageTemplates) {
                Label("Gerenciar modelos", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(GranolaPillButtonStyle())
        }
        .padding(18)
        .frame(width: 300)
        .background(VoizTheme.sidebarBackground)
    }
}

struct MeetingSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(VoizTheme.mutedText)
            TextField("Buscar nas reuniões", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(VoizTheme.mutedText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(VoizTheme.appBackground.opacity(0.6))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(VoizTheme.border))
        .cornerRadius(8)
    }
}

/// Prévia contextual inspirada no painel lateral do Wispr Flow: o hover numa linha recente troca o
/// conteúdo aqui; o clique na própria linha abre a reunião completa.
struct MeetingPreviewPanel: View {
    @EnvironmentObject var viewModel: MeetingViewModel
    let session: MeetingSession?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let session {
                preview(session)
            } else {
                emptyPreview
            }
        }
        .frame(maxWidth: .infinity, minHeight: 390, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: [VoizTheme.accent.opacity(0.11), VoizTheme.surfaceBackground],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(VoizTheme.border)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func preview(_ session: MeetingSession) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Prévia", systemImage: "doc.text.magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(VoizTheme.mutedText)
                    .textCase(.uppercase)

                Spacer()

                if viewModel.isProcessing(session) {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(session.title)
                    .font(.system(size: 25, weight: .regular, design: .serif))
                    .foregroundColor(VoizTheme.primaryText)
                    .lineLimit(3)

                HStack(spacing: 7) {
                    Text(session.formattedDate)
                    Text("•")
                    Text(meetingDurationLabel(session.duration))
                }
                .font(.system(size: 11))
                .foregroundColor(VoizTheme.mutedText)

                if let folder = viewModel.folderName(for: session) {
                    Label(folder, systemImage: "folder.fill")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(VoizTheme.accentBright)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(VoizTheme.accent.opacity(0.12))
                        .clipShape(Capsule())
                }
            }

            Divider()

            if viewModel.isProcessing(session) {
                previewMessage(
                    icon: "sparkles",
                    title: String(localized: "Preparando as notas"),
                    body: String(localized: "A prévia será atualizada assim que o processamento terminar.")
                )
            } else if let content = previewContent(for: session) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(content.heading)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(VoizTheme.primaryText)
                    Text(content.body)
                        .font(.system(size: 13))
                        .foregroundColor(VoizTheme.mutedText)
                        .lineSpacing(4)
                        .lineLimit(10)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                previewMessage(
                    icon: "text.alignleft",
                    title: String(localized: "Sem prévia ainda"),
                    body: String(localized: "Abra a reunião para ver os detalhes e adicionar notas.")
                )
            }

            Spacer(minLength: 0)

            if !session.turns.isEmpty || (session.summary?.actionItemCount ?? 0) > 0 {
                HStack(spacing: 14) {
                    if !session.turns.isEmpty {
                        Label("\(session.turns.count) falas", systemImage: "quote.bubble")
                    }
                    let actions = session.summary?.actionItemCount ?? 0
                    if actions > 0 {
                        Label("\(actions) ações", systemImage: "checkmark.circle")
                    }
                }
                .font(.system(size: 10.5))
                .foregroundColor(VoizTheme.mutedText)
            }
        }
        .padding(20)
    }

    private var emptyPreview: some View {
        VStack(alignment: .leading, spacing: 14) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(VoizTheme.accent.opacity(0.14))
                .frame(width: 46, height: 46)
                .overlay(
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(VoizTheme.accentBright)
                )

            Text("Prévia da reunião")
                .font(.system(size: 21, weight: .regular, design: .serif))
                .foregroundColor(VoizTheme.primaryText)

            Text("Passe o cursor sobre uma reunião para ver o resumo.")
                .font(.system(size: 13))
                .foregroundColor(VoizTheme.mutedText)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }

    private func previewMessage(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(VoizTheme.accentBright)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(VoizTheme.primaryText)
                Text(body)
                    .font(.system(size: 12))
                    .foregroundColor(VoizTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func previewContent(for session: MeetingSession) -> (heading: String, body: String)? {
        if let summary = session.summary {
            if !summary.overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (String(localized: "Visão geral"), summary.overview)
            }

            if let section = summary.sections.first(where: { !$0.isEmpty }) {
                switch section.kind {
                case .paragraph:
                    return (section.title, section.paragraph)
                case .bullets:
                    return (section.title, section.bullets.prefix(4).map { "• \($0)" }.joined(separator: "\n"))
                case .actionItems:
                    return (section.title, section.actionItems.prefix(4).map { "• \($0.text)" }.joined(separator: "\n"))
                }
            }
        }

        let notes = session.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            return (String(localized: "Notas"), notes)
        }

        if !session.turns.isEmpty {
            let excerpt = session.turns.prefix(3)
                .map { "\($0.speakerName): \($0.text)" }
                .joined(separator: "\n")
            return (String(localized: "Trecho da conversa"), excerpt)
        }

        return nil
    }
}

// MARK: - Pastas (estilo Granola)

/// Grade de pastas na home de Reuniões: criar, renomear, apagar e abrir (a pasta filtra as
/// sessões dela). Apagar a pasta só desassocia as reuniões — nada é perdido.
struct MeetingFoldersSection: View {
    @EnvironmentObject var viewModel: MeetingViewModel
    let onOpenFolder: (UUID) -> Void
    @State private var showCreateSheet = false
    @State private var folderToEdit: MeetingFolder?

    private let columns = [GridItem(.adaptive(minimum: 240), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HomeSectionTitle("Pastas")
                Spacer()
                Button(action: { showCreateSheet = true }) {
                    Label("Nova pasta", systemImage: "folder.badge.plus")
                }
                .buttonStyle(GranolaPillButtonStyle())
            }

            if viewModel.folders.isEmpty {
                Text("Crie pastas para organizar suas reuniões por projeto, cliente ou time.")
                    .font(.system(size: 12))
                    .foregroundColor(VoizTheme.mutedText)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(viewModel.folders) { folder in
                        MeetingFolderCard(
                            folder: folder,
                            count: viewModel.sessions(inFolder: folder.id).count,
                            onOpen: { onOpenFolder(folder.id) },
                            onEdit: { folderToEdit = folder },
                            onDelete: { viewModel.deleteFolder(folder) }
                        )
                    }
                }
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            MeetingFolderSheet(
                heading: "Criar pasta",
                confirmLabel: "Criar",
                onCancel: { showCreateSheet = false },
                onSave: { name, details, expected in
                    viewModel.createFolder(name: name, details: details, expectedParticipants: expected)
                    showCreateSheet = false
                }
            )
        }
        .sheet(item: $folderToEdit) { folder in
            MeetingFolderSheet(
                heading: "Editar pasta",
                confirmLabel: "Salvar",
                initialName: folder.name,
                initialDetails: folder.details,
                initialExpectedParticipants: folder.expectedParticipants ?? [],
                onCancel: { folderToEdit = nil },
                onSave: { name, details, expected in
                    viewModel.updateFolder(folder, name: name, details: details, expectedParticipants: expected)
                    folderToEdit = nil
                }
            )
        }
    }
}

struct MeetingFolderCard: View {
    let folder: MeetingFolder
    let count: Int
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 9)
                    .fill(VoizTheme.accent.opacity(0.18))
                    .frame(width: 38, height: 38)
                    .overlay(
                        Image(systemName: "folder.fill")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(VoizTheme.accent)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(VoizTheme.primaryText)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(VoizTheme.mutedText)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if isHovering {
                    Menu {
                        Button(action: onEdit) {
                            Label("Renomear / editar", systemImage: "pencil")
                        }
                        Divider()
                        Button(role: .destructive, action: onDelete) {
                            Label("Apagar pasta", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(VoizTheme.mutedText)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(VoizTheme.mutedText)
                }
            }
            .padding(12)
            .background(isHovering ? VoizTheme.hoverBackground : VoizTheme.surfaceBackground)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(VoizTheme.border))
            .cornerRadius(12)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var subtitle: String {
        let countLabel = String(localized: "\(count) reuniões")
        if folder.details.isEmpty { return countLabel }
        return "\(countLabel) · \(folder.details)"
    }
}

/// Folha de criar/editar pasta (título + descrição + participantes frequentes), no mesmo estilo do RenameSheet.
struct MeetingFolderSheet: View {
    /// São sempre rótulos do app. Como `String`, `Text(heading)` e `Button(confirmLabel)` os
    /// exibiam literalmente e a folha escapava da localização.
    let heading: LocalizedStringKey
    let confirmLabel: LocalizedStringKey
    var initialName: String = ""
    var initialDetails: String = ""
    var initialExpectedParticipants: [String] = []
    let onCancel: () -> Void
    let onSave: (String, String, [String]) -> Void

    @State private var name = ""
    @State private var details = ""
    @State private var expectedParticipantsDraft = ""
    @FocusState private var nameFocused: Bool

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill.badge.plus")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(VoizTheme.accent)
                Text(heading)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(VoizTheme.primaryText)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Nome")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(VoizTheme.mutedText)
                TextField("Ex.: Projeto X, 1:1s, Clientes", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundColor(VoizTheme.primaryText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(VoizTheme.elevatedBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(nameFocused ? VoizTheme.accent.opacity(0.6) : VoizTheme.border,
                                    lineWidth: nameFocused ? 1.5 : 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .focused($nameFocused)
                    .onSubmit {
                        if canSave {
                            onSave(name, details, MeetingParticipantMemory.parseExpectedParticipants(from: expectedParticipantsDraft))
                        }
                    }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Descrição")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(VoizTheme.mutedText)
                TextEditor(text: $details)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .frame(height: 64)
                    .padding(8)
                    .background(VoizTheme.elevatedBackground)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(VoizTheme.border))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Participantes frequentes (opcional)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(VoizTheme.mutedText)
                TextEditor(text: $expectedParticipantsDraft)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .frame(height: 82)
                    .padding(8)
                    .background(VoizTheme.elevatedBackground)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(VoizTheme.border))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Text("Um por linha — você pode colar direto do Teams ou Outlook.")
                    .font(.system(size: 11))
                    .foregroundColor(VoizTheme.mutedText)
            }

            HStack(spacing: 10) {
                Spacer()
                Button("Cancelar", action: onCancel)
                    .buttonStyle(GranolaPillButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(confirmLabel) {
                    onSave(name, details, MeetingParticipantMemory.parseExpectedParticipants(from: expectedParticipantsDraft))
                }
                .buttonStyle(VoizPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.5)
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(VoizTheme.surfaceBackground)
        .onAppear {
            name = initialName
            details = initialDetails
            expectedParticipantsDraft = initialExpectedParticipants.joined(separator: "\n")
            nameFocused = true
        }
    }
}

/// Tela de uma pasta: filtra automaticamente as reuniões dela, com busca local e as mesmas
/// ações das linhas de Recentes (abrir, renomear, mover, apagar).
struct MeetingFolderView: View {
    @EnvironmentObject var viewModel: MeetingViewModel
    let folder: MeetingFolder
    let onBack: () -> Void
    let onOpen: (UUID) -> Void

    @State private var searchText = ""
    @State private var sessionToRename: MeetingSession?
    @State private var renameDraft = ""
    @State private var folderToEdit: MeetingFolder?
    @State private var previewSessionID: UUID?

    private var folderSessions: [MeetingSession] {
        viewModel.sessions(inFolder: folder.id)
    }

    private var filteredSessions: [MeetingSession] {
        folderSessions.filter { $0.matches(searchText) }
    }

    private var previewSession: MeetingSession? {
        if let previewSessionID,
           let selected = folderSessions.first(where: { $0.id == previewSessionID }) {
            return selected
        }
        return filteredSessions.first ?? folderSessions.first
    }

    var body: some View {
        GeometryReader { viewport in
            VStack(alignment: .leading, spacing: 22) {
                folderHeader
                    .frame(maxWidth: MeetingLayout.startMaxWidth)
                    .padding(.horizontal, MeetingLayout.masterDetailHorizontalPadding(for: viewport.size.width))
                    .frame(maxWidth: .infinity)

                HStack(alignment: .top, spacing: MeetingLayout.masterDetailSpacing(for: viewport.size.width)) {
                    ScrollView {
                        folderList
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(.bottom, 40)
                            .background(MeetingSlimScrollConfigurator())
                    }
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)

                    if viewport.size.width >= 840 {
                        MeetingPreviewPanel(session: previewSession)
                            .frame(
                                width: MeetingLayout.previewWidth(for: viewport.size.width),
                                height: MeetingLayout.previewHeight(
                                    for: viewport.size,
                                    reservedHeight: 230
                                ),
                                alignment: .top
                            )
                    }
                }
                .frame(maxWidth: MeetingLayout.startMaxWidth)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, MeetingLayout.masterDetailHorizontalPadding(for: viewport.size.width))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: renameBinding) {
            RenameSheet(
                title: "Renomear reunião",
                text: $renameDraft,
                onCancel: { sessionToRename = nil },
                onSave: {
                    if let session = sessionToRename {
                        viewModel.renameSession(session, to: renameDraft)
                    }
                    sessionToRename = nil
                }
            )
        }
        .sheet(item: $folderToEdit) { original in
            MeetingFolderSheet(
                heading: "Editar pasta",
                confirmLabel: "Salvar",
                initialName: original.name,
                initialDetails: original.details,
                initialExpectedParticipants: original.expectedParticipants ?? [],
                onCancel: { folderToEdit = nil },
                onSave: { name, details, expected in
                    viewModel.updateFolder(original, name: name, details: details, expectedParticipants: expected)
                    folderToEdit = nil
                }
            )
        }
        .onChange(of: folderSessions.map(\.id)) { _, ids in
            if let previewSessionID, !ids.contains(previewSessionID) {
                self.previewSessionID = ids.first
            }
        }
    }

    private var folderHeader: some View {
        VStack(alignment: .leading, spacing: 22) {
            VoizBackButton(title: "Reuniões", action: onBack)
                .padding(.top, 16)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(VoizTheme.accent)
                    Text(folder.name)
                        .font(.system(size: 34, weight: .regular, design: .serif))
                        .foregroundColor(VoizTheme.primaryText)
                }
                Text(headerSubtitle)
                    .font(.system(size: 13))
                    .foregroundColor(VoizTheme.mutedText)
            }

            HStack(spacing: 8) {
                Button(action: { folderToEdit = folder }) {
                    Label("Editar pasta", systemImage: "pencil")
                }
                .buttonStyle(GranolaPillButtonStyle())

                Button(action: {
                    viewModel.deleteFolder(folder)
                    onBack()
                }) {
                    Label("Apagar pasta", systemImage: "trash")
                }
                .buttonStyle(GranolaPillButtonStyle(destructive: true))

                Spacer()

                if !folderSessions.isEmpty {
                    MeetingSearchField(text: $searchText)
                        .frame(maxWidth: 260)
                }
            }
        }
    }

    @ViewBuilder
    private var folderList: some View {
        if folderSessions.isEmpty {
            HomeRecentRow(
                icon: "folder",
                title: String(localized: "Pasta vazia"),
                subtitle: String(localized: "Mova reuniões para cá pelo menu de cada uma."),
                detail: ""
            )
        } else if filteredSessions.isEmpty {
            HomeRecentRow(
                icon: "magnifyingglass",
                title: String(localized: "Nenhuma reunião encontrada"),
                subtitle: String(localized: "Tente outro termo de busca"),
                detail: ""
            )
        } else {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(filteredSessions) { session in
                    MeetingSessionRow(
                        session: session,
                        showFolder: false,
                        isSelected: previewSession?.id == session.id,
                        onOpen: onOpen,
                        onPreview: { previewSessionID = $0 },
                        onRename: {
                            sessionToRename = session
                            renameDraft = session.title
                        }
                    )
                }
            }
        }
    }

    private var headerSubtitle: String {
        let countLabel = String(localized: "\(folderSessions.count) reuniões")
        if folder.details.isEmpty { return countLabel }
        return "\(folder.details) • \(countLabel)"
    }

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { sessionToRename != nil },
            set: { if !$0 { sessionToRename = nil } }
        )
    }
}

/// Submenu "Mover para pasta" usado no menu "…" das linhas de reunião.
struct MeetingMoveToFolderMenu: View {
    @EnvironmentObject var viewModel: MeetingViewModel
    let session: MeetingSession

    var body: some View {
        if !viewModel.folders.isEmpty {
            Menu {
                if session.folderId != nil {
                    Button(action: { viewModel.moveSession(session, toFolderId: nil) }) {
                        Label("Sem pasta", systemImage: "tray")
                    }
                    Divider()
                }
                ForEach(viewModel.folders) { folder in
                    Button(action: { viewModel.moveSession(session, toFolderId: folder.id) }) {
                        HStack {
                            Text(folder.name)
                            if session.folderId == folder.id { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                Label("Mover para pasta", systemImage: "folder")
            }
        }
    }
}

/// Linha de reunião compartilhada por Recentes e pela tela de pasta: abre, renomeia, move
/// entre pastas e apaga. Em Recentes o subtítulo mostra a pasta (grupo) da sessão.
struct MeetingSessionRow: View {
    @EnvironmentObject var viewModel: MeetingViewModel
    let session: MeetingSession
    /// Mostra o nome da pasta no subtítulo (usado em Recentes; a tela da pasta esconde).
    var showFolder = true
    var isSelected = false
    let onOpen: (UUID) -> Void
    var onPreview: ((UUID) -> Void)? = nil
    let onRename: () -> Void

    var body: some View {
        HomeRecentRow(
            icon: session.sessionType == .interview ? "person.text.rectangle" : "doc.text",
            title: session.title,
            subtitle: subtitle,
            detail: session.formattedDate,
            action: { onOpen(session.id) },
            isSelected: isSelected,
            onRename: onRename,
            onDelete: { viewModel.deleteSession(session) },
            extraMenu: { AnyView(MeetingMoveToFolderMenu(session: session)) },
            onHoverChange: { hovering in
                if hovering { onPreview?(session.id) }
            }
        )
    }

    private var subtitle: String {
        var parts: [String] = []
        if showFolder, let folderName = viewModel.folderName(for: session) {
            parts.append(folderName)
        }
        parts.append(baseSubtitle)
        return parts.joined(separator: " · ")
    }

    private var baseSubtitle: String {
        if viewModel.isProcessing(session) {
            return String(localized: "Processando…")
        }
        if let summary = session.summary, summary.hasContent {
            let actions = summary.actionItemCount
            return actions > 0 ? String(localized: "\(actions) ações") : String(localized: "Resumo disponível")
        }
        if !session.turns.isEmpty {
            return String(localized: "\(session.turns.count) falas")
        }
        return session.sessionType.displayName
    }
}

struct MeetingRecentsList: View {
    @EnvironmentObject var viewModel: MeetingViewModel
    let selectedSessionID: UUID?
    let onPreview: (UUID) -> Void
    let onOpen: (UUID) -> Void
    @State private var sessionToRename: MeetingSession?
    @State private var renameDraft = ""
    @State private var searchText = ""
    @State private var showAll = false

    /// Quantas reuniões aparecem antes do "Mostrar todas".
    private static let collapsedLimit = 8

    private var filteredSessions: [MeetingSession] {
        viewModel.sessions.filter { $0.matches(searchText) }
    }

    /// Busca ativa mostra tudo que casa; sem busca, respeita o limite até expandir.
    private var visibleSessions: [MeetingSession] {
        let isSearching = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isSearching || showAll { return filteredSessions }
        return Array(filteredSessions.prefix(Self.collapsedLimit))
    }

    private var hiddenCount: Int {
        filteredSessions.count - visibleSessions.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HomeSectionTitle("Recentes")
                Spacer()
                if !viewModel.sessions.isEmpty {
                    MeetingSearchField(text: $searchText)
                        .frame(maxWidth: 260)
                }
            }

            if viewModel.sessions.isEmpty {
                HomeRecentRow(
                    icon: "doc.text",
                    title: String(localized: "Suas reuniões vão aparecer aqui"),
                    subtitle: String(localized: "Inicie uma gravação para criar histórico"),
                    detail: ""
                )
            } else if filteredSessions.isEmpty {
                HomeRecentRow(
                    icon: "magnifyingglass",
                    title: String(localized: "Nenhuma reunião encontrada"),
                    subtitle: String(localized: "Tente outro termo de busca"),
                    detail: ""
                )
            } else {
                // A lista expandida pode ter centenas de reuniões. O stack lazy só constrói as
                // linhas (e seus menus contextuais) que estão perto da área visível.
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(visibleSessions) { session in
                        MeetingSessionRow(
                            session: session,
                            isSelected: selectedSessionID == session.id,
                            onOpen: onOpen,
                            onPreview: onPreview,
                            onRename: {
                                sessionToRename = session
                                renameDraft = session.title
                            }
                        )
                    }
                }

                if hiddenCount > 0 {
                    Button(action: { withAnimation(.easeInOut(duration: 0.15)) { showAll = true } }) {
                        Label("Mostrar todas (\(filteredSessions.count))", systemImage: "chevron.down")
                    }
                    .buttonStyle(GranolaPillButtonStyle())
                } else if showAll && filteredSessions.count > Self.collapsedLimit {
                    Button(action: { withAnimation(.easeInOut(duration: 0.15)) { showAll = false } }) {
                        Label("Mostrar menos", systemImage: "chevron.up")
                    }
                    .buttonStyle(GranolaPillButtonStyle())
                }
            }
        }
        .sheet(isPresented: renameAlertBinding) {
            RenameSheet(
                title: "Renomear reunião",
                text: $renameDraft,
                onCancel: { sessionToRename = nil },
                onSave: {
                    if let session = sessionToRename {
                        viewModel.renameSession(session, to: renameDraft)
                    }
                    sessionToRename = nil
                }
            )
        }
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { sessionToRename != nil },
            set: { if !$0 { sessionToRename = nil } }
        )
    }
}

// MARK: - Live recording

struct MeetingLiveView: View {
    @EnvironmentObject var viewModel: MeetingViewModel
    let session: MeetingSession
    @State private var notesCollapsed = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                MeetingLiveHeader(session: session)

                if viewModel.liveMeetingAssistantAvailable {
                    MeetingLiveAssistCard()
                }

                MeetingLiveNotes(collapsed: $notesCollapsed)

                if viewModel.liveTranscriptCardVisible {
                    MeetingLivePreviewCard()
                        .frame(minHeight: 280)
                }
            }
            .frame(maxWidth: MeetingLayout.maxWidth)
            .padding(.horizontal, MeetingLayout.liveHorizontalPadding)
            .padding(.top, 22)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

struct MeetingLiveHeader: View {
    @EnvironmentObject var viewModel: MeetingViewModel
    let session: MeetingSession

    private var isProcessing: Bool { viewModel.state == .processing }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        if !isProcessing {
                            Circle()
                                .fill(viewModel.meetingPaused ? Color.orange : Color.red)
                                .frame(width: 8, height: 8)
                        }
                        Text(isProcessing
                             ? String(localized: "Finalizando…")
                             : (viewModel.meetingPaused ? String(localized: "Pausado") : String(localized: "Gravando")))
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(VoizTheme.primaryText)
                    }
                    Text(viewModel.statusMessage)
                        .font(.system(size: 12))
                        .foregroundColor(VoizTheme.mutedText)
                        .lineLimit(1)
                }

                Spacer()

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(meetingDurationLabel(
                        viewModel.meetingDuration(for: session, at: context.date)
                    ))
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .foregroundColor(VoizTheme.primaryText)
                }

                if isProcessing {
                    MeetingProcessingProgress()
                } else {
                    Button {
                        MeetingRecordingIndicator.shared.openAssistant(viewModel: viewModel)
                    } label: { Image(systemName: "rectangle.on.rectangle") }
                    .buttonStyle(GranolaPillButtonStyle()).help("Abrir assistente flutuante")
                    .accessibilityLabel("Abrir assistente flutuante")
                    Button(action: viewModel.toggleMeetingPause) {
                        Label(
                            viewModel.meetingPaused ? "Retomar" : "Pausar",
                            systemImage: viewModel.meetingPaused ? "play.fill" : "pause.fill"
                        )
                    }
                    .buttonStyle(GranolaPillButtonStyle())

                    Button(action: viewModel.toggleRecording) {
                        Label("Parar", systemImage: "stop.fill")
                    }
                    .buttonStyle(GranolaPillButtonStyle(accented: true))
                }
            }

            HStack(spacing: 18) {
                MeetingLevelView(title: session.speakerName(for: .microphone), level: viewModel.microphoneLevel, color: .blue)
                MeetingLevelView(title: session.speakerName(for: .systemAudio), level: viewModel.systemAudioLevel, color: VoizTheme.accent)
            }

            if let warning = session.systemAudioWarning {
                HStack(spacing: 10) {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Abrir Ajustes") {
                        ScreenRecordingPermissionService.shared.requestAccess()
                        ScreenRecordingPermissionService.shared.openScreenRecordingSettings()
                    }
                    .buttonStyle(GranolaPillButtonStyle())
                }
            }
        }
        .padding(16)
        .background(VoizTheme.surfaceBackground)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(VoizTheme.border))
        .cornerRadius(12)
    }
}

/// Indicador do pós-processamento: barra determinada com % enquanto o áudio gravado é
/// retranscrito (progresso = áudio já lido dos .caf); spinner nos demais passos
/// (diarização, eco, resumo), que não têm progresso mensurável.
struct MeetingProcessingProgress: View {
    @EnvironmentObject var viewModel: MeetingViewModel
    var session: MeetingSession? = nil

    var body: some View {
        let progress = session != nil
            ? session.flatMap { viewModel.postProcessingProgress(for: $0) }
            : viewModel.postProcessingProgress
        if let progress {
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 120)
                Text(verbatim: "\(Int((progress * 100).rounded()))%")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(VoizTheme.mutedText)
                    .frame(minWidth: 34, alignment: .trailing)
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }
}

struct MeetingLiveNotes: View {
    @EnvironmentObject var viewModel: MeetingViewModel
    @Binding var collapsed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { collapsed.toggle() } }) {
                HStack(spacing: 6) {
                    Label("Notas rápidas", systemImage: "note.text")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(VoizTheme.primaryText)
                    Spacer()
                    Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(VoizTheme.mutedText)
                }
            }
            .buttonStyle(.plain)

            if !collapsed {
                if let session = viewModel.activeSession { MeetingNotesUsageToggle(session: session) }
                ZStack(alignment: .topLeading) {
                    if viewModel.liveNotesDraft.isEmpty {
                        Text("Anote algo para lembrar depois…")
                            .font(.system(size: 13))
                            .foregroundColor(VoizTheme.mutedText.opacity(0.72))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: notesBinding)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(7)
                }
                .frame(height: 88)
                .background(VoizTheme.appBackground.opacity(0.6))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(VoizTheme.border))
                .cornerRadius(8)
                .disabled(viewModel.state != .listening)
            }
        }
        .padding(14)
        .background(VoizTheme.surfaceBackground)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(VoizTheme.border))
        .cornerRadius(12)
    }

    private var notesBinding: Binding<String> {
        Binding(
            get: { viewModel.liveNotesDraft },
            set: { viewModel.updateLiveNotesDraft($0) }
        )
    }
}

private enum MeetingAssistTab: String, CaseIterable, Identifiable {
    case whatToSay
    case followUps
    case recap
    case questions

    var id: String { rawValue }

    var action: MeetingAssistAction? {
        switch self {
        case .whatToSay: return .whatToSay
        case .followUps: return .followUps
        case .recap: return .recap
        case .questions: return nil
        }
    }

    var title: String {
        action?.title ?? String(localized: "Perguntas")
    }

    var icon: String {
        action?.icon ?? "bubble.left.and.bubble.right"
    }
}

/// Assistente ao vivo em abas: cada ação preserva seu próprio resultado e a conversa livre
/// vive em uma quarta aba. Só um painel aparece por vez, evitando a grade alta e embolada.
struct MeetingLiveAssistCard: View {
    @EnvironmentObject var viewModel: MeetingViewModel
    @State private var selectedTab: MeetingAssistTab = .followUps

    private var hasOutput: Bool {
        !viewModel.assistActionResults.isEmpty || !viewModel.assistQuestionHistory.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Label("Assistente da reunião", systemImage: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(VoizTheme.primaryText)
                Spacer()
                if hasOutput {
                    Button(action: viewModel.clearAssist) {
                        Label("Limpar tudo", systemImage: "trash")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(VoizTheme.mutedText)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.assistRunning)
                }
            }

            HStack {
                MeetingLiveContextControl()
                Spacer()
                MeetingRecipeMenu { viewModel.assistQuestion = $0; selectedTab = .questions }
            }
            assistTabs

            Group {
                if let action = selectedTab.action {
                    MeetingAssistActionTabContent(
                        action: action,
                        result: viewModel.assistActionResults[action],
                        assistRunning: viewModel.assistRunning,
                        onGenerate: { viewModel.runLiveAssist(action) },
                        onClear: { viewModel.clearAssistAction(action) }
                    )
                } else {
                    questionsTab
                }
            }
            .frame(maxWidth: .infinity)
            .padding(12)
            .background(VoizTheme.appBackground.opacity(0.42))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(VoizTheme.border))
            .cornerRadius(10)
        }
        .padding(14)
        .background(VoizTheme.surfaceBackground)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(VoizTheme.border))
        .cornerRadius(12)
    }

    private var assistTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(MeetingAssistTab.allCases) { tab in
                    Button {
                        withAnimation(.easeOut(duration: 0.12)) {
                            selectedTab = tab
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tab.icon)
                            Text(tab.title)

                            if let action = tab.action,
                               viewModel.assistActionResults[action]?.isRunning == true {
                                ProgressView().controlSize(.mini)
                            } else if let action = tab.action,
                                      viewModel.assistActionResults[action] != nil {
                                Circle()
                                    .fill(VoizTheme.accent)
                                    .frame(width: 5, height: 5)
                            } else if tab == .questions, !viewModel.assistQuestionHistory.isEmpty {
                                Text("\(viewModel.assistQuestionHistory.count)")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(VoizTheme.elevatedBackground)
                                    .clipShape(Capsule())
                            }
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(
                            selectedTab == tab ? VoizTheme.primaryText : VoizTheme.mutedText
                        )
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(
                            selectedTab == tab
                                ? VoizTheme.elevatedBackground
                                : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
        }
        .background(VoizTheme.appBackground.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private var canAsk: Bool {
        !viewModel.assistRunning &&
        !viewModel.assistQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var questionsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            if viewModel.assistQuestionHistory.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 20))
                        .foregroundColor(VoizTheme.mutedText)
                    Text("Pergunte algo sobre o que já foi dito.")
                        .font(.system(size: 12))
                        .foregroundColor(VoizTheme.mutedText)
                }
                .frame(maxWidth: .infinity, minHeight: 76)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(viewModel.assistQuestionHistory) { item in
                                MeetingAssistQuestionResultCard(
                                    item: item,
                                    onClear: { viewModel.clearAssistQuestion(item.id) }
                                )
                                .id(item.id)
                            }
                        }
                    }
                    .frame(minHeight: 90, maxHeight: 220)
                    .onChange(of: viewModel.assistQuestionHistory.count) { _, _ in
                        if let last = viewModel.assistQuestionHistory.last {
                            withAnimation(.easeOut(duration: 0.18)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: viewModel.assistQuestionHistory.last?.answer) { _, _ in
                        if let last = viewModel.assistQuestionHistory.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Pergunte sobre a conversa…", text: $viewModel.assistQuestion)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(VoizTheme.primaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(VoizTheme.surfaceBackground)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(VoizTheme.border))
                    .cornerRadius(8)
                    .onSubmit(viewModel.submitLiveAssistQuestion)
                    .disabled(viewModel.assistRunning)

                Button(action: viewModel.submitLiveAssistQuestion) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(canAsk ? VoizTheme.accent : VoizTheme.mutedText)
                }
                .buttonStyle(.plain)
                .disabled(!canAsk)
            }
        }
    }
}

private struct MeetingAssistActionTabContent: View {
    @EnvironmentObject var viewModel: MeetingViewModel
    let action: MeetingAssistAction
    let result: MeetingAssistActionResult?
    let assistRunning: Bool
    let onGenerate: () -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(action.title, systemImage: action.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(VoizTheme.primaryText)

                Spacer()

                if result?.isRunning == true {
                    ProgressView().controlSize(.small)
                } else if result != nil {
                    Button(action: onClear) {
                        Label("Limpar", systemImage: "xmark")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(VoizTheme.mutedText)
                }

                Button(action: onGenerate) {
                    Label(result == nil ? String(localized: "Gerar") : String(localized: "Atualizar"),
                          systemImage: "arrow.clockwise")
                }
                .buttonStyle(GranolaPillButtonStyle())
                .disabled(assistRunning)
            }

            Divider().overlay(VoizTheme.border)

            if let result {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if !result.text.isEmpty {
                            MeetingLinkedText(text: result.text, allowedSessionIDs: Set(result.contextSessionIDs))
                                .font(.system(size: 13))
                                .foregroundColor(VoizTheme.primaryText)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else if result.isRunning {
                            Text("Pensando…")
                                .font(.system(size: 12))
                                .foregroundColor(VoizTheme.mutedText)
                        }

                        if let error = result.error {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(minHeight: 76, maxHeight: 180)
            } else {
                VStack(spacing: 7) {
                    Text(emptyMessage)
                        .font(.system(size: 12))
                        .foregroundColor(VoizTheme.mutedText)
                        .multilineTextAlignment(.center)
                    Button("Gerar agora", action: onGenerate)
                        .buttonStyle(VoizPrimaryButtonStyle())
                        .disabled(assistRunning)
                }
                .frame(maxWidth: .infinity, minHeight: 88)
            }
        }
    }

    private var emptyMessage: String {
        switch action {
        case .whatToSay:
            return String(localized: "Receba uma sugestão curta e pronta para falar.")
        case .followUps:
            return String(localized: "Gere três perguntas úteis a partir da conversa atual.")
        case .recap:
            return String(localized: "Veja decisões, pontos-chave e pendências até agora.")
        }
    }
}

private struct MeetingAssistQuestionResultCard: View {
    @EnvironmentObject var viewModel: MeetingViewModel
    let item: MeetingAssistQuestionResult
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.question)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(VoizTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if item.isRunning {
                    ProgressView().controlSize(.mini)
                } else {
                    Button(action: onClear) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(VoizTheme.mutedText)
                    .help("Remover esta pergunta")
                }
            }

            if !item.answer.isEmpty {
                MeetingLinkedText(text: item.answer, allowedSessionIDs: Set(item.contextSessionIDs))
                    .font(.system(size: 13))
                    .foregroundColor(VoizTheme.primaryText.opacity(0.92))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if item.isRunning {
                Text("Pensando…")
                    .font(.system(size: 12))
                    .foregroundColor(VoizTheme.mutedText)
            }

            if let error = item.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(VoizTheme.appBackground.opacity(0.45))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(VoizTheme.border))
        .cornerRadius(8)
    }
}

// MARK: - Review

/// Título do detalhe editável no lugar: clique no texto e digite. Enter ou perder o foco salva,
/// Esc devolve o original. Só vira campo no clique — um `TextField` permanente pegaria o foco
/// inicial da tela com o texto todo selecionado, e a primeira tecla renomearia a reunião.
struct MeetingEditableTitle: View {
    let title: String
    let onCommit: (String) -> Void
    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var font: Font { .system(size: 34, weight: .regular, design: .serif) }

    var body: some View {
        if isEditing {
            TextField("Sem nome", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(font)
                .foregroundColor(VoizTheme.primaryText)
                .lineLimit(1...3)
                .focused($focused)
                .onSubmit(commit)
                .onExitCommand { finish() }
                .onChange(of: focused) { _, isFocused in
                    if isFocused {
                        // O campo entra com o texto todo selecionado, e a primeira tecla
                        // apagaria o título. Cursor no fim, como num editor de texto.
                        DispatchQueue.main.async { Self.moveCaretToEnd() }
                    } else if isEditing {
                        commit()
                    }
                }
        } else {
            Text(title.isEmpty ? String(localized: "Sem nome") : title)
                .font(font)
                .foregroundColor(title.isEmpty ? VoizTheme.mutedText : VoizTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .contentShape(Rectangle())
                .onTapGesture {
                    draft = title
                    isEditing = true
                    focused = true
                }
                .help("Clique para renomear")
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != title {
            onCommit(trimmed)
        }
        finish()
    }

    private func finish() {
        isEditing = false
        focused = false
    }

    private static func moveCaretToEnd() {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
    }
}

private enum MeetingReviewTab: String, CaseIterable, Identifiable {
    case summary
    case transcript
    case notes
    case participants

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .summary: "Resumo"
        case .transcript: "Transcrição"
        case .notes: "Notas"
        case .participants: "Participantes"
        }
    }

    var symbol: String {
        switch self {
        case .summary: "sparkles"
        case .transcript: "text.bubble"
        case .notes: "note.text"
        case .participants: "person.2"
        }
    }
}

private struct MeetingTranscriptScrollRequest: Equatable {
    let token = UUID()
    let turnID: UUID
}

struct MeetingReviewView: View {
    @EnvironmentObject var viewModel: MeetingViewModel
    @EnvironmentObject private var companionOverlay: MeetingReviewCompanionPresentation
    @Environment(\.voizCompanionOverlayWindowHosted) private var overlayWindowHosted
    let session: MeetingSession
    let onBack: () -> Void
    @StateObject private var audioPlayer = MeetingAudioPlayer()
    @State private var selectedTab: MeetingReviewTab = .summary
    @State private var pendingTranscriptScroll: MeetingTranscriptScrollRequest?
    @State private var transcriptSearchQuery = ""
    @State private var transcriptSpeakerFilter: String?

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ZStack(alignment: .bottom) {
                    HStack(spacing: 0) {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                                headerSection
                                    .padding(.bottom, 14)

                                Section {
                                    tabContent
                                        .padding(.top, 18)
                                        .padding(.bottom, audioPlayer.isAvailable ? 92 : 40)
                                } header: {
                                    reviewTabBar
                                }
                            }
                            .frame(maxWidth: MeetingLayout.maxWidth)
                            .padding(.horizontal, MeetingLayout.horizontalPadding)
                            .frame(maxWidth: .infinity)
                        }

                        if companionReservedWidth(for: viewport.size.width) > 0 {
                            Color.clear
                                .frame(width: companionReservedWidth(for: viewport.size.width))
                        }
                    }

                    if audioPlayer.isAvailable {
                        MeetingDockedPlayerBar(
                            player: audioPlayer,
                            showJumpToTranscript: selectedTab != .transcript,
                            onJumpToTranscript: { jumpToCurrentPlayingTurn() }
                        )
                        .frame(maxWidth: MeetingLayout.maxWidth)
                        .padding(.horizontal, MeetingLayout.horizontalPadding)
                        .frame(maxWidth: .infinity)
                        .padding(.trailing, companionReservedWidth(for: viewport.size.width))
                        .padding(.bottom, 14)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(1)
                    }
                }
                .accessibilityHidden(showsCompanionOverlay(width: viewport.size.width))
                .overlay(alignment: .trailing) {
                    if !overlayWindowHosted && companionOverlay.showsWindowPanel {
                        MeetingReviewCompanionDrawer(
                            session: session,
                            player: audioPlayer,
                            presentation: companionOverlay,
                            dimsBackground: showsCompanionOverlay(width: viewport.size.width)
                        )
                    }
                }
                .animation(.easeInOut(duration: 0.16), value: companionOverlay.tab)
                .animation(.easeOut(duration: 0.16), value: audioPlayer.isAvailable)
                .onAppear {
                    companionOverlay.registerHost(session: session, player: audioPlayer, viewportWidth: viewport.size.width)
                }
                .onChange(of: viewport.size.width) { _, width in
                    syncCompanionOverlay(width: width)
                }
                .onChange(of: session) { previous, current in
                    if previous.id != current.id {
                        selectedTab = .summary
                        pendingTranscriptScroll = nil
                        transcriptSearchQuery = ""
                        transcriptSpeakerFilter = nil
                        companionOverlay.registerHost(session: current, player: audioPlayer, viewportWidth: viewport.size.width)
                    } else {
                        syncCompanionOverlay(width: viewport.size.width)
                    }
                }
                .task(id: scrollTriggerIdentity) {
                    guard selectedTab == .transcript, let request = pendingTranscriptScroll else { return }
                    await Task.yield()
                    guard !Task.isCancelled, pendingTranscriptScroll == request else { return }
                    if let groupID = MeetingTranscriptGroup.groupID(containing: request.turnID, in: session.turns) {
                        proxy.scrollTo(MeetingReviewTranscript.groupScrollID(for: groupID), anchor: .center)
                        try? await Task.sleep(for: .milliseconds(24))
                        guard !Task.isCancelled, pendingTranscriptScroll == request else { return }
                    }
                    withAnimation(.easeOut(duration: 0.22)) {
                        proxy.scrollTo(request.turnID, anchor: .center)
                    }
                    pendingTranscriptScroll = nil
                }
            }
        }
        .task(id: audioLoadIdentity) {
            await loadAudio()
        }
        .onChange(of: session.turns) { _, newTurns in
            audioPlayer.updateTurns(newTurns)
        }
        .onDisappear { companionOverlay.dismissIfMatching(session.id, player: audioPlayer) }
    }

    private var scrollTriggerIdentity: String {
        "\(selectedTab.rawValue)|\(pendingTranscriptScroll?.token.uuidString ?? "")"
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            VoizBackButton(title: "Reuniões", action: onBack)
                .padding(.top, 16)

            VStack(alignment: .leading, spacing: 6) {
                MeetingEditableTitle(title: session.title) { newTitle in
                    viewModel.renameSession(session, to: newTitle)
                }
                HStack(spacing: 8) {
                    Text("\(session.formattedDate) • \(session.sessionType.displayName) • \(session.turns.count) falas")
                        .font(.system(size: 13))
                        .foregroundColor(VoizTheme.mutedText)
                    MeetingSummaryModelPill(session: session)
                }
            }

            MeetingReviewActions(session: session)

            statusBanners
        }
    }

    @ViewBuilder
    private var statusBanners: some View {
        if viewModel.isReprocessingTranscript(session) {
            HStack(spacing: 10) {
                MeetingProcessingProgress(session: session)
                Text(viewModel.processingStatusMessage(for: session))
                    .font(.system(size: 13))
                    .foregroundColor(VoizTheme.mutedText)
                    .lineLimit(1)
                Spacer()
            }
            .padding(12)
            .background(VoizTheme.surfaceBackground)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(VoizTheme.border))
            .cornerRadius(10)
        } else if viewModel.needsTranscriptRecovery(session) {
            HStack(spacing: 10) {
                Label("Processamento interrompido. O áudio está salvo.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: { viewModel.reprocessTranscript(for: session) }) {
                    Label("Retomar", systemImage: "arrow.clockwise")
                }
                .buttonStyle(GranolaPillButtonStyle(accented: true))
                .disabled(viewModel.isProcessing(session))
            }
            .padding(12)
            .background(VoizTheme.surfaceBackground)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(VoizTheme.border))
            .cornerRadius(10)
        }

        if let error = session.summaryError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.system(size: 12))
                .foregroundColor(.orange)
        }

        if viewModel.isGeneratingSummary
            && viewModel.selectedSession?.id == session.id
            && !viewModel.isReprocessingTranscript(session) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Gerando resumo…")
                    .font(.system(size: 13))
                    .foregroundColor(VoizTheme.mutedText)
            }
        }
    }

    private var reviewTabBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(MeetingReviewTab.allCases) { tab in
                    reviewTabButton(tab)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 4)

            Rectangle()
                .fill(VoizTheme.border)
                .frame(height: 1)
        }
        .background(VoizTheme.appBackground)
    }

    private func reviewTabButton(_ tab: MeetingReviewTab) -> some View {
        let isSelected = selectedTab == tab
        let badgeCount = tabBadgeCount(for: tab)
        let hasDot = tab == .notes && !session.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return Button {
            withAnimation(.easeOut(duration: 0.14)) {
                selectedTab = tab
            }
        } label: {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 11.5, weight: .medium))
                    Text(tab.title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    if let badgeCount, badgeCount > 0 {
                        Text("\(badgeCount)")
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundColor(isSelected ? VoizTheme.accentBright : VoizTheme.mutedText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(
                                isSelected ? VoizTheme.accent.opacity(0.16) : VoizTheme.elevatedBackground,
                                in: Capsule()
                            )
                    } else if hasDot {
                        Circle()
                            .fill(VoizTheme.accent)
                            .frame(width: 6, height: 6)
                    }
                }
                .foregroundColor(isSelected ? VoizTheme.primaryText : VoizTheme.mutedText)
                .padding(.horizontal, 10)
                .padding(.top, 6)

                Rectangle()
                    .fill(isSelected ? VoizTheme.accent : Color.clear)
                    .frame(height: 2)
                    .clipShape(Capsule())
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func tabBadgeCount(for tab: MeetingReviewTab) -> Int? {
        switch tab {
        case .summary:
            return nil
        case .transcript:
            return session.turns.isEmpty ? nil : session.turns.count
        case .notes:
            return nil
        case .participants:
            let count = session.participantsListSpeakers.count
            return count > 0 ? count : nil
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .summary:
            VStack(alignment: .leading, spacing: 18) {
                if let summary = session.summary, summary.hasContent {
                    MeetingSummaryView(
                        session: session,
                        onPlayTurn: { turn in
                            if audioPlayer.isAvailable { audioPlayer.playFrom(turn.startTime) }
                        },
                        onRevealTurn: { turn in
                            revealTurnInTranscript(turn)
                        }
                    )
                } else if !(viewModel.isGeneratingSummary && viewModel.selectedSession?.id == session.id) {
                    HomeDetailSection(title: "Resumo") {
                        Text("Sem resumo ainda.")
                            .font(.system(size: 13))
                            .foregroundColor(VoizTheme.mutedText)
                    }
                }
            }

        case .transcript:
            MeetingReviewTranscript(
                session: session,
                player: audioPlayer,
                searchQuery: $transcriptSearchQuery,
                selectedSpeakerKey: $transcriptSpeakerFilter,
                onJumpToTime: { time in
                    if audioPlayer.isAvailable { audioPlayer.playFrom(time) }
                    if let target = turnNearest(to: time) {
                        transcriptSearchQuery = ""
                        transcriptSpeakerFilter = nil
                        pendingTranscriptScroll = MeetingTranscriptScrollRequest(turnID: target.id)
                    }
                }
            )

        case .notes:
            MeetingNotesCard(session: session)

        case .participants:
            VStack(alignment: .leading, spacing: 18) {
                if !session.speakers.isEmpty && !session.turns.isEmpty {
                    MeetingParticipantsCard(session: session)
                } else {
                    HomeDetailSection(title: "Participantes") {
                        Text("Nenhuma fala registrada.")
                            .font(.system(size: 13))
                            .foregroundColor(VoizTheme.mutedText)
                    }
                }

                if !session.talkTimeStats.isEmpty {
                    MeetingTalkTimeCard(session: session)
                }
            }
        }
    }

    private func revealTurnInTranscript(_ turn: MeetingTurn) {
        if audioPlayer.isAvailable { audioPlayer.playFrom(turn.startTime) }
        transcriptSearchQuery = ""
        transcriptSpeakerFilter = nil
        pendingTranscriptScroll = MeetingTranscriptScrollRequest(turnID: turn.id)
        if selectedTab != .transcript {
            withAnimation(.easeOut(duration: 0.14)) {
                selectedTab = .transcript
            }
        }
    }

    private func jumpToCurrentPlayingTurn() {
        let targetID = audioPlayer.turnPlaybackState.currentTurnID
            ?? turnNearest(to: audioPlayer.playbackState.currentTime)?.id
        transcriptSearchQuery = ""
        transcriptSpeakerFilter = nil
        if let targetID {
            pendingTranscriptScroll = MeetingTranscriptScrollRequest(turnID: targetID)
        }
        withAnimation(.easeOut(duration: 0.14)) {
            selectedTab = .transcript
        }
    }

    private func turnNearest(to time: TimeInterval) -> MeetingTurn? {
        MeetingTranscriptGroup.turn(at: time, in: session.turns)
    }

    private func showsCompanionOverlay(width: CGFloat) -> Bool {
        companionOverlay.showsWindowPanel && width < MeetingLayout.companionInlineMinWidth
    }

    private func companionReservedWidth(for width: CGFloat) -> CGFloat {
        companionOverlay.showsWindowPanel && width >= MeetingLayout.companionInlineMinWidth
            ? MeetingReviewCompanionPresentation.panelWidth(for: width, preferred: companionOverlay.preferredWidth) : 0
    }

    private func syncCompanionOverlay(width: CGFloat) {
        companionOverlay.updateHost(session: session, player: audioPlayer, viewportWidth: width)
    }

    /// A faixa limpa nasce no fim do pós-processamento. O ID da sessão não muda nesse momento,
    /// portanto usá-lo sozinho no `.task(id:)` deixava o player preso ao microfone bruto que havia
    /// carregado antes — e a soma com `system-audio.caf` reproduzia a voz remota duas vezes.
    private var audioLoadIdentity: String {
        session.id.uuidString + "|" + (session.cleanMicFile ?? "raw")
    }

    private func loadAudio() async {
        let directory = viewModel.store.sessionDirectoryURL(for: session.id)
        // Usa a faixa de mic sem eco quando existe (cai no microphone.caf bruto se faltar).
        let micName: String? = {
            if let clean = session.cleanMicFile,
               FileManager.default.fileExists(atPath: directory.appendingPathComponent(clean).path) {
                return clean
            }
            return session.audioFiles[.microphone]
        }()
        let micURL = micName.map { directory.appendingPathComponent($0) }
        let systemURL = session.audioFiles[.systemAudio].map { directory.appendingPathComponent($0) }
        await audioPlayer.load(
            micURL: micURL,
            systemURL: systemURL,
            key: audioLoadIdentity,
            turns: session.turns
        )
    }
}

private enum NotionExportAlert: Equatable {
    case success(URL)
    /// A página existe no Notion, incompleta. Carrega a URL de propósito: sem
    /// ela o usuário fica com um erro genérico e uma página órfã que ele não
    /// sabe que precisa conferir — e o retry cria uma segunda.
    case partial(URL, String)
    case failure(String)

    /// A página criada, quando houve alguma. É o que decide se o alerta
    /// oferece "Abrir no Notion".
    var pageURL: URL? {
        switch self {
        case .success(let url), .partial(let url, _): url
        case .failure: nil
        }
    }
}

struct MeetingReviewActions: View {
    @EnvironmentObject var viewModel: MeetingViewModel
    let session: MeetingSession

    @State private var isExporting = false
    @State private var exportDocument = MarkdownDocument(text: "")
    @State private var exportFilename = "reuniao"
    @State private var isNotionExporting = false
    @State private var notionAlert: NotionExportAlert?
    @State private var notionExportTask: Task<Void, Never>?
    /// Parcial pendente de aviso, lido do disco ao abrir a tela. É o canal que
    /// não depende de configuração nenhuma.
    @State private var notionPendingPartial: NotionPartialExport?
    /// Quem é o dono ATUAL do estado de exportação. Cada início de exportação
    /// e cada troca de sessão incrementam; uma Task que não é mais a dona não
    /// escreve nada na tela.
    ///
    /// Sem isso, o `defer` de uma Task antiga derrubava a flag de "exportando"
    /// de uma exportação NOVA — o botão reabria com a exportação de B em voo,
    /// e um clique criava uma segunda página.
    @State private var notionExportGeneration = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            notionPartialBanner
            actionsRow
        }
    }

    private var actionsRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                templateMenu
                retrySummaryButton
                audioActionsMenu
                exportMenu
                folderMenu
                Spacer(minLength: 8)
                deleteButton
            }

            // Em larguras menores, quebra por grupos sem permitir que o SwiftUI transforme
            // os rótulos em colunas de letras. Todas as ações continuam visíveis e inteiras.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    templateMenu
                    retrySummaryButton
                    audioActionsMenu
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    exportMenu
                    folderMenu
                    Spacer(minLength: 0)
                    deleteButton
                }
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .markdownText,
            defaultFilename: exportFilename
        ) { result in
            if case .failure(let error) = result {
                print("⚠️ Export Markdown falhou: \(error)")
            }
        }
        .alert(
            notionAlertTitle,
            isPresented: Binding(
                get: { notionAlert != nil },
                set: { if !$0 { notionAlert = nil } }
            )
        ) {
            if let url = notionAlert?.pageURL {
                Button(String(localized: "Abrir no Notion")) {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("OK", role: .cancel) { notionAlert = nil }
        } message: {
            Text(notionAlertMessage)
        }
        // `onChange(of:initial:)`, não `onAppear`. A busca global (⌘K) troca a
        // sessão MANTENDO o mesmo ramo estrutural desta view: o `onAppear` não
        // roda de novo, e um `@State` não chaveado por sessão atravessa a
        // troca. Isso dava os dois lados do erro — banner da sessão A aparecendo
        // em B (e o "Abrir no Notion" levando à página errada, o "Entendi"
        // limpando o registro errado), e B com parcial abrindo SEM aviso, livre
        // para re-exportar às cegas.
        .onChange(of: session.id, initial: true) { _, newSessionID in
            // A exportação em voo é da sessão ANTERIOR: seu alerta não pode
            // aparecer sobre esta. O registro em disco já foi feito antes de
            // qualquer canal de UI, então cancelar aqui não perde o aviso.
            notionExportTask?.cancel()
            notionExportTask = nil
            // Trocar de sessão troca o dono: o que a Task anterior fizer ao
            // retomar não alcança mais esta tela.
            notionExportGeneration += 1
            notionAlert = nil
            isNotionExporting = false
            notionPendingPartial = NotionPartialExportStore.shared.pending(for: newSessionID)
        }
        .onDisappear {
            notionExportTask?.cancel()
            notionExportTask = nil
        }
    }

    private var templateMenu: some View {
        Menu {
            ForEach(viewModel.templateStore.templates) { template in
                Button(action: { viewModel.regenerateSummary(for: session, templateId: template.id) }) {
                    HStack {
                        Text(template.menuLabel)
                        if template.id == session.templateId { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            VoizMenuPillLabel(title: currentTemplateName, systemImage: "doc.text.magnifyingglass")
        }
        .menuStyle(.button)
        .buttonStyle(GranolaPillButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(viewModel.isGeneratingSummary)
    }

    private var retrySummaryButton: some View {
        Button(action: { viewModel.retrySummary(for: session) }) {
            Label("Refazer resumo", systemImage: "sparkles")
                .lineLimit(1)
        }
        .buttonStyle(GranolaPillButtonStyle())
        .fixedSize()
        .disabled(viewModel.isGeneratingSummary)
    }

    private var audioActionsMenu: some View {
        Menu {
            Button(action: { viewModel.diarizeSession(session) }) {
                Label("Identificar participantes", systemImage: "person.2.wave.2")
            }
            .disabled(viewModel.isProcessing(session) || !viewModel.hasRecordedAudio(session))

            if MeetingRecordingLifecycle.showsRemoveEchoAction(
                mode: session.meetingMode,
                turnCount: session.turns.count
            ) {
                Button(action: { viewModel.reconcileEchoForSession(session) }) {
                    Label("Remover eco", systemImage: "waveform.badge.minus")
                }
                .disabled(viewModel.isProcessing(session) || !viewModel.hasRecordedAudio(session))
            }

            Divider()

            Button(action: { viewModel.reprocessTranscript(for: session) }) {
                Label("Reprocessar transcrição", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.isProcessing(session) || !viewModel.hasRecordedAudio(session))
        } label: {
            VoizMenuPillLabel(
                title: String(localized: "Ações de áudio"),
                systemImage: "waveform.and.person.filled"
            )
        }
        .menuStyle(.button)
        .buttonStyle(GranolaPillButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var exportMenu: some View {
        Menu {
            Button(action: copyFullExport) {
                Label("Copiar resumo e transcrição", systemImage: "doc.on.doc")
            }
            Button(action: copyTranscript) {
                Label("Copiar transcrição", systemImage: "text.alignleft")
            }
            Divider()
            ShareLink(
                item: MeetingExporter.markdown(for: session),
                subject: Text(MeetingExporter.title(for: session)),
                message: Text("Resumo da reunião gerado pelo Voiz")
            ) {
                Label("Compartilhar…", systemImage: "envelope")
            }
            Button(action: beginExport) {
                Label("Salvar como Markdown…", systemImage: "square.and.arrow.down")
            }
            if NotionCredentialsStore.shared.hasToken {
                Divider()
                Button(action: exportToNotion) {
                    Label("Exportar para o Notion", systemImage: "n.square")
                }
                .disabled(isNotionExporting)
            }
        } label: {
            VoizMenuPillLabel(title: String(localized: "Exportar"), systemImage: "square.and.arrow.up")
        }
        .menuStyle(.button)
        .buttonStyle(GranolaPillButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(session.turns.isEmpty && !(session.summary?.hasContent ?? false))
    }

    @ViewBuilder
    private var folderMenu: some View {
        if !viewModel.folders.isEmpty {
            Menu {
                if session.folderId != nil {
                    Button(action: { viewModel.moveSession(session, toFolderId: nil) }) {
                        Label("Sem pasta", systemImage: "tray")
                    }
                    Divider()
                }
                ForEach(viewModel.folders) { folder in
                    Button(action: { viewModel.moveSession(session, toFolderId: folder.id) }) {
                        HStack {
                            Text(folder.name)
                            if session.folderId == folder.id { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                VoizMenuPillLabel(
                    title: viewModel.folderName(for: session) ?? String(localized: "Mover para pasta"),
                    systemImage: "folder"
                )
            }
            .menuStyle(.button)
            .buttonStyle(GranolaPillButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var deleteButton: some View {
        Button(action: {
            viewModel.selectSession(session)
            viewModel.deleteSelectedSession()
        }) {
            Label("Apagar", systemImage: "trash")
                .lineLimit(1)
        }
        .buttonStyle(GranolaPillButtonStyle(destructive: true))
        .fixedSize()
    }

    /// O aviso que não depende de canal nenhum: fica na tela onde o botão de
    /// exportar está, então o usuário não consegue re-exportar sem vê-lo — que
    /// é o ponto, porque re-exportar cria uma SEGUNDA página.
    @ViewBuilder
    private var notionPartialBanner: some View {
        if let partial = notionPendingPartial {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Página do Notion ficou incompleta")
                        .font(.system(size: 12, weight: .semibold))
                    Text(
                        "\(partial.appendedBlocks) de \(partial.totalBlocks) partes enviadas. Exportar de novo cria outra página."
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(String(localized: "Abrir no Notion")) {
                    NSWorkspace.shared.open(partial.pageURL)
                }
                Button(String(localized: "Entendi")) {
                    // O reconhecimento do usuário é a escrita mais recente que
                    // existe: leva a geração atual da tela.
                    NotionPartialExportStore.shared.clear(
                        for: session.id,
                        generation: notionExportGeneration
                    )
                    notionPendingPartial = nil
                }
            }
            .padding(10)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var notionAlertTitle: String {
        switch notionAlert {
        case .success:
            String(localized: "Exportado para o Notion")
        case .partial:
            String(localized: "Exportação incompleta")
        case .failure, .none:
            String(localized: "Não foi possível exportar para o Notion")
        }
    }

    private var notionAlertMessage: String {
        switch notionAlert {
        case .success:
            String(localized: "A página da reunião foi criada.")
        case .partial(_, let message):
            message
        case .failure(let message):
            message
        case .none:
            ""
        }
    }

    private func exportToNotion() {
        notionExportTask?.cancel()
        notionExportGeneration += 1
        let generation = notionExportGeneration
        // A sessão desta exportação, congelada aqui: a Task pode terminar
        // depois de a tela já mostrar outra reunião, e o registro do parcial
        // tem que ir para a sessão que foi exportada, não para a que está à
        // vista.
        let exportedSessionID = session.id
        let store = NotionCredentialsStore.shared
        isNotionExporting = true
        notionExportTask = Task {
            defer {
                // Só o dono atual mexe na flag. Uma Task cancelada que retoma
                // tarde não pode reabrir o botão de uma exportação em voo.
                if notionExportGeneration == generation { isNotionExporting = false }
            }
            do {
                let result = try await NotionExportService().export(
                    session,
                    token: store.token(),
                    destination: store.destination()
                )
                guard !Task.isCancelled else { return }
                // Concluiu inteira: o parcial anterior deixou de ser a última
                // verdade sobre ESSA reunião — a que foi exportada.
                NotionPartialExportStore.shared.clear(for: exportedSessionID, generation: generation)
                guard notionExportGeneration == generation else { return }
                notionPendingPartial = nil
                notionAlert = .success(result.url)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription

                // Página criada e conteúdo incompleto: isto NUNCA é silencioso,
                // nem quando a saída da tela cancelou a exportação. O que existe
                // do lado do Notion é do usuário, e ele precisa saber que está
                // lá pela metade — senão confere um transcript truncado sem
                // desconfiar, ou exporta de novo e fica com duas páginas.
                if case .partiallyExported(let page, let appended, let total, _) =
                    error as? NotionExportError {
                    // PRIMEIRO o registro em disco, e só depois qualquer canal
                    // de UI. Alerta depende de a tela estar viva; o toast do
                    // notch depende de um overlay que é opt-in e vem DESLIGADO.
                    // O registro não depende de nada, e é ele que garante que
                    // nenhuma configuração deixa o parcial silencioso.
                    let partial = NotionPartialExport(
                        pageURL: page.url,
                        appendedBlocks: appended,
                        totalBlocks: total
                    )
                    NotionPartialExportStore.shared.record(partial, for: exportedSessionID, generation: generation)

                    guard notionExportGeneration == generation else {
                        // A tela já é de outra sessão: o registro em disco já
                        // foi feito e o aviso espera lá. Nada é escrito aqui.
                        return
                    }
                    guard !Task.isCancelled else {
                        // A tela já saiu. O toast aparece se o overlay estiver
                        // ligado; o aviso de verdade é o banner, que espera na
                        // próxima abertura desta tela.
                        NotchOverlay.shared.showToast(
                            message: String(localized: "Página do Notion ficou incompleta"),
                            symbol: "exclamationmark.triangle.fill"
                        )
                        return
                    }
                    notionPendingPartial = partial
                    notionAlert = .partial(page.url, message)
                    return
                }

                if error is CancellationError { return }
                guard !Task.isCancelled, notionExportGeneration == generation else { return }
                notionAlert = .failure(message)
            }
        }
    }

    private var currentTemplateName: String {
        viewModel.templateStore.template(withId: session.templateId)?.name ?? String(localized: "Modelo")
    }

    private func copyTranscript() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(session.transcriptText, forType: .string)
    }

    private func copyFullExport() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(MeetingExporter.markdown(for: session), forType: .string)
    }

    private func beginExport() {
        exportDocument = MarkdownDocument(text: MeetingExporter.markdown(for: session))
        exportFilename = MeetingExporter.suggestedFileName(for: session)
        // Adia para depois do Menu fechar: trocar o flag de apresentação no mesmo ciclo do clique
        // do Menu faz o SwiftUI engolir a apresentação (o .fileExporter nunca abre).
        DispatchQueue.main.async {
            isExporting = true
        }
    }
}

/// Documento de texto (Markdown) para o `.fileExporter` nativo do SwiftUI.
struct MarkdownDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.markdownText, .plainText] }

    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        text = String(decoding: data, as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

extension UTType {
    /// Tipo Markdown (extensão `.md`). Usa o tipo do sistema quando existe; senão deriva de `.md`.
    static var markdownText: UTType {
        UTType("net.daringfireball.markdown") ?? (UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText)
    }
}

struct MeetingNotesCard: View {
    @EnvironmentObject var viewModel: MeetingViewModel
    let session: MeetingSession
    @State private var isEditing = false
    @State private var isAuthorizing = false
    @State private var activity: VoizWorkActivity?
    @State private var admissionID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Notas")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(VoizTheme.mutedText)
                    .textCase(.uppercase)
                Spacer()
                Button(isEditing ? "Concluir" : (session.notes.isEmpty ? "Adicionar" : "Editar")) {
                    if isEditing {
                        activity?.finish(); activity = nil
                        withAnimation(.easeInOut(duration: 0.15)) { isEditing = false }
                    } else if !isAuthorizing {
                        isAuthorizing = true
                        let id = UUID(); admissionID = id
                        Task { @MainActor in
                            let admitted = await VoizEditingGate.shared.begin()
                            guard admissionID == id else { admitted?.finish(); return }
                            isAuthorizing = false
                            activity = admitted
                            withAnimation(.easeInOut(duration: 0.15)) { isEditing = admitted != nil }
                        }
                    }
                }
                .disabled(isAuthorizing)
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(VoizTheme.accent)
            }

            MeetingNotesUsageToggle(session: session)
            if isEditing {
                TextEditor(text: notesBinding)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120)
                    .padding(8)
                    .background(VoizTheme.appBackground.opacity(0.6))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(VoizTheme.border))
                    .cornerRadius(8)
            } else if session.notes.isEmpty {
                Text("Nenhuma nota.")
                    .font(.system(size: 13))
                    .foregroundColor(VoizTheme.mutedText)
            } else {
                Text(session.notes)
                    .font(.system(size: 14))
                    .foregroundColor(VoizTheme.primaryText)
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(VoizTheme.surfaceBackground)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(VoizTheme.border))
        .cornerRadius(12)
        .onDisappear { admissionID = nil; activity?.finish(); activity = nil }
    }

    private var notesBinding: Binding<String> {
        Binding(
            get: { session.notes },
            set: { viewModel.updateNotes($0, sessionID: session.id) }
        )
    }
}

// MARK: - Shared

/// Transcript ao vivo. No Granola: bolhas por canal (Você à esquerda, Eles à
/// direita). No Qualidade: parágrafo neutro full-width da prévia Whisper.
///
/// `liveFeed` = falas fechadas (Text estático, barato). O volátil de cada canal
/// (ou o parágrafo único no Qualidade) é UM StreamingText — reunião longa não
/// reanima o histórico.
struct MeetingLivePreviewCard: View {
    @EnvironmentObject var viewModel: MeetingViewModel

    private var isGranolaLayout: Bool { viewModel.granolaLiveTranscriptionActive }

    private var isEmpty: Bool {
        viewModel.liveFeed.isEmpty
            && viewModel.liveCurrentParagraph.isEmpty
            && viewModel.liveVolatiles.systemAudio.isEmpty
            && viewModel.displayedMicrophoneVolatile.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Transcrição")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(VoizTheme.mutedText)
                    .textCase(.uppercase)
                Text(isGranolaLayout ? "Ao vivo" : "Prévia")
                    .font(.system(size: 11))
                    .foregroundColor(VoizTheme.mutedText.opacity(0.75))
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if isEmpty {
                            Text("Ouvindo… as falas aparecem aqui assim que alguém falar.")
                                .font(.system(size: 13))
                                .foregroundColor(VoizTheme.mutedText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                        } else if isGranolaLayout {
                            granolaFeed
                        } else {
                            qualityFeed
                        }

                        Color.clear.frame(height: 1).id("liveFeedBottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 4)
                }
                .onChange(of: viewModel.liveFeed.last?.id) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("liveFeedBottom", anchor: .bottom)
                    }
                }
                .onChange(of: viewModel.liveCurrentParagraph) { _, _ in
                    proxy.scrollTo("liveFeedBottom", anchor: .bottom)
                }
                .onChange(of: viewModel.liveVolatiles) { _, _ in
                    proxy.scrollTo("liveFeedBottom", anchor: .bottom)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(16)
        .background(VoizTheme.surfaceBackground)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(VoizTheme.border))
        .cornerRadius(12)
    }

    @ViewBuilder
    private var qualityFeed: some View {
        ForEach(viewModel.liveFeed) { entry in
            Text(entry.text)
                .font(.system(size: 14))
                .lineSpacing(5)
                .foregroundColor(VoizTheme.primaryText.opacity(0.88))
                .textSelection(.enabled)
        }
        if !viewModel.liveCurrentParagraph.isEmpty {
            StreamingText(
                text: viewModel.liveCurrentParagraph,
                font: .system(size: 14),
                lineSpacing: 5,
                cadence: .liveTranscript
            )
        }
    }

    @ViewBuilder
    private var granolaFeed: some View {
        ForEach(Array(viewModel.liveFeed.enumerated()), id: \.element.id) { index, entry in
            if let stamp = timestampLabel(before: index) {
                Text(stamp)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(VoizTheme.mutedText.opacity(0.7))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
            }
            MeetingLiveBubble(
                text: entry.text,
                side: .forChannel(entry.channel),
                streaming: false
            )
        }
        if !viewModel.liveVolatiles.systemAudio.isEmpty {
            MeetingLiveBubble(
                text: viewModel.liveVolatiles.systemAudio,
                side: .them,
                streaming: true
            )
        }
        if !viewModel.displayedMicrophoneVolatile.isEmpty {
            MeetingLiveBubble(
                text: viewModel.displayedMicrophoneVolatile,
                side: .you,
                streaming: true
            )
        }
    }

    private func timestampLabel(before index: Int) -> String? {
        guard index > 0,
              let previous = viewModel.liveFeed[index - 1].startTime,
              let current = viewModel.liveFeed[index].startTime,
              current - previous >= 15
        else { return nil }
        return Self.formatCaptureClock(current)
    }

    private static func formatCaptureClock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Bolha de chat do transcript Granola. Você à esquerda, Eles à direita;
/// `fill` (canal ausente) ocupa a linha inteira, como a prévia Qualidade.
private struct MeetingLiveBubble: View {
    let text: String
    let side: MeetingLiveTranscriptSide
    let streaming: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if side == .them { Spacer(minLength: 80) }
            bubble
            if side == .you { Spacer(minLength: 80) }
        }
        .frame(maxWidth: .infinity, alignment: side.isLeading ? .leading : .trailing)
    }

    private var bubbleFill: Color {
        switch side {
        case .you:
            return meetingSpeakerColor(source: .microphone, speakerId: nil).opacity(0.16)
        case .them:
            return VoizTheme.assistantBubbleBackground
        case .fill:
            return VoizTheme.elevatedBackground
        }
    }

    @ViewBuilder
    private var bubble: some View {
        Group {
            if streaming {
                StreamingText(
                    text: text,
                    font: .system(size: 14),
                    lineSpacing: 5,
                    cadence: .liveTranscript
                )
            } else {
                Text(text)
                    .font(.system(size: 14))
                    .lineSpacing(5)
                    .foregroundColor(VoizTheme.primaryText.opacity(0.88))
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(bubbleFill)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(VoizTheme.border)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: MeetingLayout.maxWidth * 0.72, alignment: .leading)
    }
}

struct MeetingLevelView: View {
    let title: String
    let level: Float
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(VoizTheme.mutedText)
                .lineLimit(1)
                .frame(width: 92, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(VoizTheme.iconBackground)
                    Capsule()
                        .fill(color.gradient)
                        .frame(width: geometry.size.width * CGFloat(min(level * 10, 1)))
                }
            }
            .frame(height: 5)
        }
    }
}

struct MeetingParticipantsCard: View {
    @EnvironmentObject var viewModel: MeetingViewModel
    let session: MeetingSession
    @State private var speakerToRename: MeetingSpeaker?
    @State private var renameDraft = ""
    @State private var showExpectedSheet = false
    @State private var expectedDraft = ""

    private var effectiveExpected: [String] {
        viewModel.effectiveExpectedParticipants(for: session)
    }

    private var folderExpected: [String] {
        guard let folderId = session.folderId else { return [] }
        return MeetingParticipantMemory.normalizeExpectedParticipants(
            viewModel.folders.first(where: { $0.id == folderId })?.expectedParticipants ?? []
        )
    }

    private var canIdentifyAfterSave: Bool {
        let hasRemoteClusters = session.speakers.contains {
            $0.source == .systemAudio
                && $0.id != MeetingCaptureSource.systemAudio.rawValue
                && !$0.id.hasPrefix("unidentified:")
        }
        return (hasRemoteClusters && !session.turns.isEmpty) || viewModel.hasRecordedAudio(session)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Participantes")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(VoizTheme.mutedText)
                    .textCase(.uppercase)
                Spacer()
                Button {
                    expectedDraft = (session.expectedParticipants ?? []).joined(separator: "\n")
                    showExpectedSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "person.badge.plus")
                        if effectiveExpected.isEmpty {
                            Text("Lista esperada")
                        } else {
                            Text("Lista esperada (\(effectiveExpected.count))")
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(VoizTheme.accent)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isProcessing(session) || viewModel.activeSession?.id == session.id)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(session.participantsListSpeakers) { speaker in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(meetingSpeakerColor(source: speaker.source, speakerId: speaker.id))
                            .frame(width: 9, height: 9)
                        Text(speaker.name)
                            .font(.system(size: 14))
                            .foregroundColor(VoizTheme.primaryText)
                        Spacer()
                        Button("Renomear") {
                            speakerToRename = speaker
                            renameDraft = speaker.name
                        }
                        .accessibilityLabel(Text("Renomear \(speaker.name)"))
                        .buttonStyle(.borderless)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(VoizTheme.accent)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(VoizTheme.surfaceBackground)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(VoizTheme.border))
        .cornerRadius(12)
        .sheet(isPresented: renameBinding) {
            RenameSheet(
                title: "Renomear participante",
                text: $renameDraft,
                suggestions: speakerToRename.map { viewModel.suggestedRenameNames(for: $0, in: session) } ?? [],
                onCancel: { speakerToRename = nil },
                onSave: {
                    if let speaker = speakerToRename {
                        viewModel.renameSpeaker(speaker, to: renameDraft)
                    }
                    speakerToRename = nil
                }
            )
        }
        .sheet(isPresented: $showExpectedSheet) {
            ExpectedParticipantsSheet(
                text: $expectedDraft,
                folderParticipants: folderExpected,
                canIdentify: canIdentifyAfterSave,
                onCancel: { showExpectedSheet = false },
                onSave: {
                    let parsed = MeetingParticipantMemory.parseExpectedParticipants(from: expectedDraft)
                    viewModel.saveExpectedParticipants(parsed, for: session, andIdentify: false)
                    showExpectedSheet = false
                },
                onSaveAndIdentify: {
                    let parsed = MeetingParticipantMemory.parseExpectedParticipants(from: expectedDraft)
                    viewModel.saveExpectedParticipants(parsed, for: session, andIdentify: true)
                    showExpectedSheet = false
                }
            )
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { speakerToRename != nil },
            set: { if !$0 { speakerToRename = nil } }
        )
    }
}

private struct ExpectedParticipantsSheet: View {
    @Binding var text: String
    let folderParticipants: [String]
    let canIdentify: Bool
    let onCancel: () -> Void
    let onSave: () -> Void
    let onSaveAndIdentify: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "person.2.wave.2")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(VoizTheme.accent)
                Text("Participantes esperados")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(VoizTheme.primaryText)
            }

            Text("Cole os participantes do Teams ou Outlook ou digite um nome por linha.")
                .font(.system(size: 12))
                .foregroundColor(VoizTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)

            if !folderParticipants.isEmpty {
                Text("Da pasta: \(folderParticipants.joined(separator: ", "))")
                    .font(.system(size: 11))
                    .foregroundColor(VoizTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextEditor(text: $text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .frame(height: 130)
                .padding(8)
                .background(VoizTheme.elevatedBackground)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(VoizTheme.border))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 10) {
                Spacer()
                Button("Cancelar", action: onCancel)
                    .buttonStyle(GranolaPillButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Salvar", action: onSave)
                    .buttonStyle(GranolaPillButtonStyle())
                if canIdentify {
                    Button("Salvar e identificar", action: onSaveAndIdentify)
                        .buttonStyle(VoizPrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(VoizTheme.surfaceBackground)
    }
}

struct MeetingTalkTimeCard: View {
    let session: MeetingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tempo de fala")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(VoizTheme.mutedText)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(session.talkTimeStats) { stat in
                    MeetingTalkTimeRow(stat: stat)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(VoizTheme.surfaceBackground)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(VoizTheme.border))
        .cornerRadius(12)
    }
}

struct MeetingTalkTimeRow: View {
    let stat: MeetingTalkTimeStat

    private var color: Color {
        meetingSpeakerColor(source: stat.source, speakerId: stat.speakerId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(stat.speakerName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(VoizTheme.primaryText)
                    .lineLimit(1)
                Spacer()
                Text("\(Int((stat.fraction * 100).rounded()))% · \(meetingDurationLabel(stat.duration))")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(VoizTheme.mutedText)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(VoizTheme.iconBackground)
                    Capsule()
                        .fill(color.gradient)
                        .frame(width: max(2, geometry.size.width * CGFloat(stat.fraction)))
                }
            }
            .frame(height: 6)
        }
    }
}

struct MeetingPlayerBar: View {
    let player: MeetingAudioPlayer
    @ObservedObject private var playback: MeetingPlayerPlaybackState

    init(player: MeetingAudioPlayer) {
        self.player = player
        _playback = ObservedObject(wrappedValue: player.playbackState)
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: { player.togglePlayPause() }) {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(VoizTheme.accent.opacity(0.9))
                    .foregroundColor(.white)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playback.isPlaying ? Text("Pausar") : Text("Reproduzir"))

            Text(meetingDurationLabel(playback.currentTime))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(VoizTheme.mutedText)

            Slider(
                value: Binding(
                    get: { playback.currentTime },
                    set: { player.seek(to: $0) }
                ),
                in: 0...max(playback.duration, 0.1)
            )
            .tint(VoizTheme.accent)

            Text(meetingDurationLabel(playback.duration))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(VoizTheme.mutedText)
        }
        .padding(14)
        .background(VoizTheme.surfaceBackground)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(VoizTheme.border))
        .cornerRadius(12)
    }
}

struct MeetingDockedPlayerBar: View {
    let player: MeetingAudioPlayer
    var showJumpToTranscript: Bool = false
    var onJumpToTranscript: (() -> Void)? = nil
    @ObservedObject private var playback: MeetingPlayerPlaybackState

    init(
        player: MeetingAudioPlayer,
        showJumpToTranscript: Bool = false,
        onJumpToTranscript: (() -> Void)? = nil
    ) {
        self.player = player
        self.showJumpToTranscript = showJumpToTranscript
        self.onJumpToTranscript = onJumpToTranscript
        _playback = ObservedObject(wrappedValue: player.playbackState)
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: { player.togglePlayPause() }) {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(VoizTheme.accent.opacity(0.95))
                    .foregroundColor(.white)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playback.isPlaying ? Text("Pausar") : Text("Reproduzir"))

            Text(meetingDurationLabel(playback.currentTime))
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundColor(VoizTheme.primaryText)
                .frame(minWidth: 38, alignment: .leading)

            Slider(
                value: Binding(
                    get: { playback.currentTime },
                    set: { player.seek(to: $0) }
                ),
                in: 0...max(playback.duration, 0.1)
            )
            .tint(VoizTheme.accent)

            Text(meetingDurationLabel(playback.duration))
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(VoizTheme.mutedText)
                .frame(minWidth: 38, alignment: .trailing)

            if showJumpToTranscript, let onJumpToTranscript, playback.isPlaying || playback.currentTime > 0 {
                Button(action: onJumpToTranscript) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(VoizTheme.accent)
                        .frame(width: 26, height: 26)
                        .background(VoizTheme.accent.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Ir para a fala atual")
                .accessibilityLabel(Text("Ir para a fala atual"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(VoizTheme.borderStrong, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.24), radius: 14, y: 6)
    }
}

/// Capítulos compactos exibidos no topo da aba Transcrição; clicar navega no player e na fala.
private struct MeetingTranscriptChaptersStrip: View {
    @EnvironmentObject var viewModel: MeetingViewModel
    let session: MeetingSession
    let onSelectTime: (TimeInterval) -> Void
    @State private var isExpanded = true

    private var chapters: [MeetingChapter] { session.chapters ?? [] }
    private var isGenerating: Bool { viewModel.generatingSummarySessionIDs.contains(session.id) }

    var body: some View {
        if isGenerating || !chapters.isEmpty || session.chaptersError != nil {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.easeOut(duration: 0.14)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "list.bullet.indent")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(VoizTheme.mutedText)
                        Text("Capítulos")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(VoizTheme.mutedText)
                            .textCase(.uppercase)
                        if !chapters.isEmpty {
                            Text("\(chapters.count)")
                                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                .foregroundColor(VoizTheme.mutedText)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(VoizTheme.mutedText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? String(localized: "Ocultar capítulos") : String(localized: "Mostrar capítulos"))

                if isExpanded {
                    if isGenerating {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(viewModel.generatingChapterSessionIDs.contains(session.id)
                                 ? String(localized: "Gerando capítulos…")
                                 : String(localized: "Gerando resumo…"))
                                .font(.system(size: 12))
                                .foregroundColor(VoizTheme.mutedText)
                        }
                    } else if let error = session.chaptersError {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundColor(VoizTheme.mutedText)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(chapters) { chapter in
                                    Button {
                                        onSelectTime(chapter.startTime)
                                    } label: {
                                        HStack(spacing: 6) {
                                            Text(chapterTimeLabel(chapter.startTime))
                                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                                .foregroundColor(VoizTheme.accent)
                                            Text(chapter.title)
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundColor(VoizTheme.primaryText)
                                                .lineLimit(1)
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(VoizTheme.elevatedBackground, in: Capsule())
                                        .overlay(Capsule().stroke(VoizTheme.border, lineWidth: 1))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .padding(12)
            .background(VoizTheme.surfaceBackground, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(VoizTheme.border))
        }
    }

    private func chapterTimeLabel(_ time: TimeInterval) -> String {
        let total = max(0, Int(time))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

struct MeetingReviewTranscript: View {
    static func groupScrollID(for groupID: UUID) -> String {
        "transcript-group:\(groupID.uuidString)"
    }

    let session: MeetingSession
    let player: MeetingAudioPlayer
    @Binding var searchQuery: String
    @Binding var selectedSpeakerKey: String?
    var onJumpToTime: ((TimeInterval) -> Void)? = nil
    @ObservedObject private var turnPlayback: MeetingTurnPlaybackState

    init(
        session: MeetingSession,
        player: MeetingAudioPlayer,
        searchQuery: Binding<String>,
        selectedSpeakerKey: Binding<String?>,
        onJumpToTime: ((TimeInterval) -> Void)? = nil
    ) {
        self.session = session
        self.player = player
        _searchQuery = searchQuery
        _selectedSpeakerKey = selectedSpeakerKey
        self.onJumpToTime = onJumpToTime
        _turnPlayback = ObservedObject(wrappedValue: player.turnPlaybackState)
    }

    private struct SpeakerOption: Identifiable {
        let id: String
        let name: String
        let source: MeetingCaptureSource
        let speakerId: String?
        let count: Int
    }

    private var speakerOptions: [SpeakerOption] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        var meta: [String: (name: String, source: MeetingCaptureSource, speakerId: String?)] = [:]
        for turn in session.turns {
            let key = MeetingTranscriptGroup.speakerKey(for: turn)
            if counts[key] == nil {
                order.append(key)
                meta[key] = (turn.speakerName, turn.source, turn.speakerId)
            }
            counts[key, default: 0] += 1
        }
        return order.compactMap { key in
            guard let info = meta[key], let count = counts[key] else { return nil }
            return SpeakerOption(id: key, name: info.name, source: info.source, speakerId: info.speakerId, count: count)
        }
    }

    private var filteredTurns: [MeetingTurn] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return session.turns.filter { turn in
            if let selectedSpeakerKey, MeetingTranscriptGroup.speakerKey(for: turn) != selectedSpeakerKey {
                return false
            }
            if !query.isEmpty {
                return turn.text.localizedCaseInsensitiveContains(query)
                    || turn.speakerName.localizedCaseInsensitiveContains(query)
            }
            return true
        }
    }

    private var groupedTurns: [MeetingTranscriptGroup] {
        MeetingTranscriptGroup.group(filteredTurns)
    }

    var body: some View {
        let currentID = player.isAvailable ? turnPlayback.currentTurnID : nil
        let options = speakerOptions
        let groups = groupedTurns

        VStack(alignment: .leading, spacing: 14) {
            if !session.turns.isEmpty, let onJumpToTime {
                MeetingTranscriptChaptersStrip(session: session, onSelectTime: onJumpToTime)
            }

            if !session.turns.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12))
                            .foregroundColor(VoizTheme.mutedText)
                        TextField("Buscar na transcrição…", text: $searchQuery)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundColor(VoizTheme.primaryText)
                        if !searchQuery.isEmpty {
                            Button {
                                searchQuery = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(VoizTheme.mutedText)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(VoizTheme.surfaceBackground, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(VoizTheme.border))

                    if options.count >= 2 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                filterChip(
                                    title: String(localized: "Todos"),
                                    count: session.turns.count,
                                    dotColor: nil,
                                    selected: selectedSpeakerKey == nil
                                ) {
                                    selectedSpeakerKey = nil
                                }
                                ForEach(options) { option in
                                    filterChip(
                                        title: option.name,
                                        count: option.count,
                                        dotColor: meetingSpeakerColor(source: option.source, speakerId: option.speakerId),
                                        selected: selectedSpeakerKey == option.id
                                    ) {
                                        selectedSpeakerKey = selectedSpeakerKey == option.id ? nil : option.id
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if session.turns.isEmpty {
                HomeDetailSection(title: "Transcrição") {
                    Text("Nenhuma fala registrada.")
                        .font(.system(size: 13))
                        .foregroundColor(VoizTheme.mutedText)
                }
            } else if groups.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Nenhuma fala encontrada.")
                        .font(.system(size: 13))
                        .foregroundColor(VoizTheme.mutedText)
                    Button("Limpar filtro") {
                        searchQuery = ""
                        selectedSpeakerKey = nil
                    }
                    .buttonStyle(GranolaPillButtonStyle())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(VoizTheme.surfaceBackground, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(VoizTheme.border))
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(groups) { group in
                        MeetingTranscriptGroupBubble(
                            group: group,
                            currentTurnID: currentID,
                            onSeek: player.isAvailable ? { turn in player.playFrom(turn.startTime) } : nil
                        )
                        .id(Self.groupScrollID(for: group.id))
                    }
                }
                .padding(16)
                .background(VoizTheme.surfaceBackground, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(VoizTheme.border))
            }
        }
    }

    private func filterChip(
        title: String,
        count: Int,
        dotColor: Color?,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let dotColor {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 7, height: 7)
                }
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundColor(selected ? VoizTheme.primaryText : VoizTheme.mutedText)
                    .lineLimit(1)
                Text("\(count)")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundColor(selected ? VoizTheme.accentBright : VoizTheme.mutedText.opacity(0.85))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                selected ? VoizTheme.accent.opacity(0.16) : VoizTheme.surfaceBackground,
                in: Capsule()
            )
            .overlay(
                Capsule().stroke(selected ? VoizTheme.accent.opacity(0.45) : VoizTheme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct MeetingTranscriptGroupBubble: View {
    let group: MeetingTranscriptGroup
    let currentTurnID: UUID?
    let onSeek: ((MeetingTurn) -> Void)?

    private var speakerColor: Color {
        meetingSpeakerColor(source: group.source, speakerId: group.speakerId)
    }

    private var isMe: Bool { group.source == .microphone }

    private var containsCurrent: Bool {
        guard let currentTurnID else { return false }
        return group.turns.contains(where: { $0.id == currentTurnID })
    }

    private var bubbleFill: Color {
        if isMe { return speakerColor.opacity(containsCurrent ? 0.24 : 0.14) }
        return containsCurrent ? VoizTheme.selectedBackground : VoizTheme.assistantBubbleBackground
    }

    var body: some View {
        HStack(spacing: 0) {
            if !isMe { Spacer(minLength: 48) }
            bubble
            if isMe { Spacer(minLength: 48) }
        }
        .frame(maxWidth: .infinity)
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(speakerColor)
                    .frame(width: 7, height: 7)
                Text(group.speakerName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(speakerColor)
                if let first = group.turns.first {
                    timeButton(for: first)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(group.turns.enumerated()), id: \.element.id) { offset, turn in
                    let isCurrent = turn.id == currentTurnID
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if offset > 0 {
                            timeButton(for: turn, subtle: true)
                        }
                        Text(turn.text)
                            .font(.system(size: 13.5))
                            .foregroundColor(VoizTheme.primaryText)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, isCurrent ? 8 : 0)
                    .padding(.vertical, isCurrent ? 5 : 0)
                    .background(
                        isCurrent ? speakerColor.opacity(0.16) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                    .id(turn.id)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(bubbleFill)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(containsCurrent ? speakerColor.opacity(0.65) : VoizTheme.border, lineWidth: containsCurrent ? 1.5 : 1)
        )
        .cornerRadius(12)
    }

    @ViewBuilder
    private func timeButton(for turn: MeetingTurn, subtle: Bool = false) -> some View {
        let label = timeLabel(turn.startTime)
        if let onSeek {
            Button { onSeek(turn) } label: {
                HStack(spacing: 2.5) {
                    if !subtle {
                        Image(systemName: "play.fill").font(.system(size: 7.5))
                    }
                    Text(label)
                        .font(.system(size: subtle ? 10.5 : 11, design: .monospaced))
                }
                .foregroundColor(subtle ? VoizTheme.mutedText.opacity(0.75) : VoizTheme.mutedText)
            }
            .buttonStyle(.plain)
            .help("Tocar a partir daqui")
            .accessibilityLabel(Text("Tocar a partir daqui"))
            .accessibilityValue(Text(label))
        } else {
            Text(label)
                .font(.system(size: subtle ? 10.5 : 11, design: .monospaced))
                .foregroundColor(VoizTheme.mutedText.opacity(subtle ? 0.75 : 1))
        }
    }

    private func timeLabel(_ time: TimeInterval) -> String {
        let total = max(0, Int(time))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - Summary (seções dinâmicas)

/// Renderiza o resumo com o parágrafo principal fixo no topo e as demais seções do template em
/// sub-abas com contagem (além da opção "Tudo" com cards recolhíveis).
struct MeetingSummaryView: View {
    let session: MeetingSession
    var onPlayTurn: ((MeetingTurn) -> Void)? = nil
    var onRevealTurn: ((MeetingTurn) -> Void)? = nil

    @State private var selectedSectionID: String?
    @State private var collapsedSectionIDs: Set<String> = []

    private var nonEmptySections: [MeetingSummarySection] {
        session.summary?.sections.filter { !$0.isEmpty } ?? []
    }

    private var leadSection: MeetingSummarySection? {
        nonEmptySections.first(where: { $0.kind == .paragraph })
    }

    private var detailSections: [MeetingSummarySection] {
        guard let lead = leadSection else { return nonEmptySections }
        return nonEmptySections.filter { $0.id != lead.id }
    }

    private var detailSectionIDs: [String] {
        detailSections.map(\.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let lead = leadSection {
                leadParagraphCard(lead)
            }

            if detailSections.count >= 2 {
                sectionSelectorBar
            }

            if detailSections.count >= 2, let selectedSectionID,
               let activeSection = detailSections.first(where: { $0.id == selectedSectionID }) {
                sectionCard(activeSection, collapsible: false)
            } else {
                ForEach(detailSections) { section in
                    sectionCard(section, collapsible: detailSections.count >= 2)
                }
            }
        }
        .onChange(of: session.id, initial: true) { _, _ in
            collapsedSectionIDs = []
            selectedSectionID = detailSections.count >= 2 ? detailSections.first?.id : nil
        }
        .onChange(of: detailSectionIDs) { _, ids in
            if ids.count < 2 {
                selectedSectionID = nil
            } else if let current = selectedSectionID, !ids.contains(current) {
                selectedSectionID = ids.first
            }
        }
    }

    private func leadParagraphCard(_ section: MeetingSummarySection) -> some View {
        HomeDetailSection(title: LocalizedStringKey(section.title)) {
            VStack(alignment: .leading, spacing: 10) {
                Text(section.paragraph)
                    .font(.system(size: 14.5))
                    .foregroundColor(VoizTheme.primaryText)
                    .textSelection(.enabled)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                MeetingEvidenceLinks(
                    session: session,
                    section: section,
                    itemIndex: 0,
                    onPlayTurn: onPlayTurn,
                    onRevealTurn: onRevealTurn
                )
            }
        }
    }

    private var sectionSelectorBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(detailSections) { section in
                    let isSelected = selectedSectionID == section.id
                    sectionTabPill(
                        title: section.title,
                        badge: sectionBadge(for: section),
                        selected: isSelected
                    ) {
                        withAnimation(.easeOut(duration: 0.14)) {
                            selectedSectionID = section.id
                        }
                    }
                }

                sectionTabPill(
                    title: String(localized: "Tudo"),
                    badge: nil,
                    selected: selectedSectionID == nil
                ) {
                    withAnimation(.easeOut(duration: 0.14)) {
                        selectedSectionID = nil
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func sectionBadge(for section: MeetingSummarySection) -> String? {
        switch section.kind {
        case .paragraph:
            return nil
        case .bullets:
            let count = section.displayItemCount
            return count > 0 ? "\(count)" : nil
        case .actionItems:
            let valid = section.actionItems.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !valid.isEmpty else { return nil }
            let doneCount = valid.filter(\.done).count
            return doneCount > 0 ? "\(doneCount)/\(valid.count)" : "\(valid.count)"
        }
    }

    private func sectionTabPill(
        title: String,
        badge: String?,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                    .foregroundColor(selected ? VoizTheme.primaryText : VoizTheme.mutedText)
                    .lineLimit(1)
                if let badge {
                    Text(badge)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(selected ? VoizTheme.accentBright : VoizTheme.mutedText)
                        .padding(.horizontal, 5.5)
                        .padding(.vertical, 1.5)
                        .background(
                            selected ? VoizTheme.accent.opacity(0.20) : VoizTheme.elevatedBackground,
                            in: Capsule()
                        )
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                selected ? VoizTheme.accent.opacity(0.14) : VoizTheme.surfaceBackground,
                in: Capsule()
            )
            .overlay(
                Capsule().stroke(selected ? VoizTheme.accent.opacity(0.42) : VoizTheme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func sectionCard(_ section: MeetingSummarySection, collapsible: Bool) -> some View {
        let isCollapsed = collapsible && collapsedSectionIDs.contains(section.id)

        return VStack(alignment: .leading, spacing: 12) {
            if collapsible {
                Button {
                    withAnimation(.easeOut(duration: 0.14)) {
                        if collapsedSectionIDs.contains(section.id) {
                            collapsedSectionIDs.remove(section.id)
                        } else {
                            collapsedSectionIDs.insert(section.id)
                        }
                    }
                } label: {
                    sectionHeaderRow(section, collapsible: true, isCollapsed: isCollapsed)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                sectionHeaderRow(section, collapsible: false, isCollapsed: false)
            }

            if !isCollapsed {
                sectionBody(section)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(VoizTheme.surfaceBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(VoizTheme.border)
        )
        .cornerRadius(12)
    }

    private func sectionHeaderRow(_ section: MeetingSummarySection, collapsible: Bool, isCollapsed: Bool) -> some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey(section.title))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(VoizTheme.mutedText)
                .textCase(.uppercase)

            if let badge = sectionBadge(for: section) {
                Text(badge)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(VoizTheme.mutedText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(VoizTheme.elevatedBackground, in: Capsule())
            }

            Spacer(minLength: 0)

            if collapsible {
                Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(VoizTheme.mutedText)
            }
        }
    }

    @ViewBuilder
    private func sectionBody(_ section: MeetingSummarySection) -> some View {
        switch section.kind {
        case .paragraph:
            VStack(alignment: .leading, spacing: 8) {
                Text(section.paragraph)
                    .font(.system(size: 14.5))
                    .foregroundColor(VoizTheme.primaryText)
                    .textSelection(.enabled)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                MeetingEvidenceLinks(
                    session: session,
                    section: section,
                    itemIndex: 0,
                    onPlayTurn: onPlayTurn,
                    onRevealTurn: onRevealTurn
                )
            }
        case .bullets:
            MeetingSummaryBulletsSectionView(
                session: session,
                section: section,
                onPlayTurn: onPlayTurn,
                onRevealTurn: onRevealTurn
            )
        case .actionItems:
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(section.actionItems.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Divider().opacity(0.5)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        MeetingActionItemRow(sessionId: session.id, sectionId: section.id, item: item)
                        MeetingEvidenceLinks(
                            session: session,
                            section: section,
                            itemIndex: index,
                            onPlayTurn: onPlayTurn,
                            onRevealTurn: onRevealTurn
                        )
                        .padding(.leading, 33)
                    }
                }
            }
        }
    }
}

private struct MeetingSummaryBulletsSectionView: View {
    let session: MeetingSession
    let section: MeetingSummarySection
    var onPlayTurn: ((MeetingTurn) -> Void)? = nil
    var onRevealTurn: ((MeetingTurn) -> Void)? = nil

    @State private var selectedGroupID: String?

    private var groups: [MeetingSummaryBulletGroup]? {
        MeetingSummaryBulletGroup.groups(for: section.bullets)
    }

    var body: some View {
        Group {
            if let groups {
                groupedContent(groups)
            } else {
                flatBulletsContent
            }
        }
        .onChange(of: session.id) { _, _ in selectedGroupID = nil }
        .onChange(of: section.id) { _, _ in selectedGroupID = nil }
    }

    private func groupedContent(_ groups: [MeetingSummaryBulletGroup]) -> some View {
        let visibleGroups: [MeetingSummaryBulletGroup] = {
            if let selectedGroupID,
               let match = groups.first(where: { $0.id == selectedGroupID }) {
                return [match]
            }
            return groups
        }()

        return VStack(alignment: .leading, spacing: 14) {
            if groups.count >= 2 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        personChip(
                            title: String(localized: "Todos"),
                            count: section.displayItemCount,
                            dotColor: nil,
                            selected: selectedGroupID == nil
                        ) {
                            withAnimation(.easeOut(duration: 0.14)) {
                                selectedGroupID = nil
                            }
                        }

                        ForEach(groups) { group in
                            personChip(
                                title: group.title,
                                count: group.entries.count,
                                dotColor: groupColor(for: group),
                                selected: selectedGroupID == group.id
                            ) {
                                withAnimation(.easeOut(duration: 0.14)) {
                                    selectedGroupID = selectedGroupID == group.id ? nil : group.id
                                }
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(visibleGroups) { group in
                    groupBlock(group, showHeader: selectedGroupID == nil || groups.count == 1)
                }
            }
        }
    }

    private func groupBlock(_ group: MeetingSummaryBulletGroup, showHeader: Bool) -> some View {
        let color = groupColor(for: group)
        return VStack(alignment: .leading, spacing: 8) {
            if showHeader {
                HStack(spacing: 7) {
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                    Text(group.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(VoizTheme.primaryText)
                    Text("\(group.entries.count)")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundColor(VoizTheme.mutedText)
                    Spacer(minLength: 0)
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                ForEach(group.entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text("•")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(VoizTheme.mutedText)

                            VStack(alignment: .leading, spacing: 4) {
                                if let tag = entry.tag {
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        tagBadge(tag)
                                        Text(entry.text)
                                            .font(.system(size: 14))
                                            .foregroundColor(VoizTheme.primaryText)
                                            .lineSpacing(3)
                                            .textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                } else {
                                    Text(entry.text)
                                        .font(.system(size: 14))
                                        .foregroundColor(VoizTheme.primaryText)
                                        .lineSpacing(3)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                MeetingEvidenceLinks(
                                    session: session,
                                    section: section,
                                    itemIndex: entry.index,
                                    onPlayTurn: onPlayTurn,
                                    onRevealTurn: onRevealTurn
                                )
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(.leading, showHeader ? 2 : 0)
        }
        .padding(showHeader ? 12 : 0)
        .background(
            showHeader ? VoizTheme.appBackground.opacity(0.45) : Color.clear,
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(showHeader ? VoizTheme.border.opacity(0.8) : Color.clear, lineWidth: 1)
        )
    }

    private var flatBulletsContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(section.bullets.enumerated()), id: \.offset) { index, text in
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("•")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(VoizTheme.mutedText)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(trimmed)
                                .font(.system(size: 14))
                                .foregroundColor(VoizTheme.primaryText)
                                .lineSpacing(3)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            MeetingEvidenceLinks(
                                session: session,
                                section: section,
                                itemIndex: index,
                                onPlayTurn: onPlayTurn,
                                onRevealTurn: onRevealTurn
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func personChip(
        title: String,
        count: Int,
        dotColor: Color?,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let dotColor {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 7, height: 7)
                }
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundColor(selected ? VoizTheme.primaryText : VoizTheme.mutedText)
                    .lineLimit(1)
                Text("\(count)")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundColor(selected ? VoizTheme.accentBright : VoizTheme.mutedText.opacity(0.85))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                selected ? VoizTheme.accent.opacity(0.16) : VoizTheme.elevatedBackground,
                in: Capsule()
            )
            .overlay(
                Capsule().stroke(selected ? VoizTheme.accent.opacity(0.45) : VoizTheme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func groupColor(for group: MeetingSummaryBulletGroup) -> Color {
        if group.isOther { return VoizTheme.mutedText }
        if let speaker = MeetingSummaryBulletGroup.matchingSpeaker(for: group.title, in: session.speakers) {
            return meetingSpeakerColor(source: speaker.source, speakerId: speaker.id)
        }
        return meetingSpeakerColor(source: .systemAudio, speakerId: group.id)
    }

    private func tagBadge(_ tag: String) -> some View {
        let tint = tagTint(for: tag)
        return Text(tag)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(tint)
            .padding(.horizontal, 6.5)
            .padding(.vertical, 1.5)
            .background(tint.opacity(0.14), in: Capsule())
            .fixedSize()
    }

    private func tagTint(for tag: String) -> Color {
        let normalized = tag.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        if normalized.contains("bloqueio") || normalized.contains("impedimento") || normalized.contains("risco") || normalized.contains("block") {
            return .orange
        }
        if normalized.contains("feito") || normalized.contains("concluido") || normalized.contains("ontem") || normalized.contains("done") {
            return .green
        }
        if normalized.contains("hoje") || normalized.contains("andamento") || normalized.contains("proximo") || normalized.contains("today") || normalized.contains("next") {
            return VoizTheme.accentBright
        }
        return VoizTheme.mutedText
    }
}

/// Linha de action item com checkbox. Marcar/desmarcar persiste via o view model.
struct MeetingActionItemRow: View {
    @EnvironmentObject var viewModel: MeetingViewModel
    let sessionId: UUID
    let sectionId: String
    let item: MeetingActionItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Só o círculo conclui. O texto e o prazo não são botão: clicar na data para ler
            // não pode marcar a ação como feita.
            HStack(alignment: .top, spacing: 9) {
                Button(action: {
                    viewModel.setActionItemDone(!item.done, sessionId: sessionId, sectionId: sectionId, itemId: item.id)
                }) {
                    Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15))
                        .foregroundColor(item.done ? VoizTheme.accent : VoizTheme.mutedText)
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.done ? String(localized: "Reabrir") : String(localized: "Concluir"))
                .accessibilityLabel(item.done ? Text("Reabrir") : Text("Concluir"))

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.text)
                        .font(.system(size: 14))
                        .foregroundColor(item.done ? VoizTheme.mutedText : VoizTheme.primaryText)
                        .strikethrough(item.done)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if item.assignee != nil || item.dueDate != nil {
                        HStack(spacing: 10) {
                            if let assignee = item.assignee {
                                Label(assignee, systemImage: "person")
                            }
                            if let dueDate = item.dueDate {
                                Label(dueDate, systemImage: "calendar")
                            }
                        }
                        .font(.system(size: 11))
                        .foregroundColor(VoizTheme.mutedText)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                viewModel.setActionItemFollowed(!item.isFollowed, sessionId: sessionId, sectionId: sectionId, itemId: item.id)
            } label: {
                Label(item.isFollowed ? String(localized: "Deixar de acompanhar") : String(localized: "Acompanhar"),
                      systemImage: item.isFollowed ? "bookmark.slash" : "bookmark")
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(VoizTheme.accent)
        }
    }
}

#Preview {
    MeetingView()
        .environmentObject(MeetingViewModel())
        .environmentObject(VoizNavigation())
        .environmentObject(MeetingReviewCompanionPresentation())
        .frame(width: 980, height: 620)
}
