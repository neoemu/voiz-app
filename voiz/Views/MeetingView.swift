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
                onSave: { name, details in
                    viewModel.createFolder(name: name, details: details)
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
                onCancel: { folderToEdit = nil },
                onSave: { name, details in
                    viewModel.updateFolder(folder, name: name, details: details)
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

/// Folha de criar/editar pasta (título + descrição), no mesmo estilo do RenameSheet.
struct MeetingFolderSheet: View {
    /// São sempre rótulos do app. Como `String`, `Text(heading)` e `Button(confirmLabel)` os
    /// exibiam literalmente e a folha escapava da localização.
    let heading: LocalizedStringKey
    let confirmLabel: LocalizedStringKey
    var initialName: String = ""
    var initialDetails: String = ""
    let onCancel: () -> Void
    let onSave: (String, String) -> Void

    @State private var name = ""
    @State private var details = ""
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
                    .onSubmit { if canSave { onSave(name, details) } }
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

            HStack(spacing: 10) {
                Spacer()
                Button("Cancelar", action: onCancel)
                    .buttonStyle(GranolaPillButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(confirmLabel) { onSave(name, details) }
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
                onCancel: { folderToEdit = nil },
                onSave: { name, details in
                    viewModel.updateFolder(original, name: name, details: details)
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

private struct MeetingReviewPlayerFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect?

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

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

struct MeetingReviewView: View {
    @EnvironmentObject var viewModel: MeetingViewModel
    @EnvironmentObject private var companionOverlay: MeetingReviewCompanionPresentation
    @Environment(\.voizCompanionOverlayWindowHosted) private var overlayWindowHosted
    let session: MeetingSession
    let onBack: () -> Void
    @StateObject private var audioPlayer = MeetingAudioPlayer()
    @State private var isFullPlayerAboveViewport = false

    private static let playerBarID = "meeting-review-player-bar"
    private static let scrollSpaceName = "meeting-review-scroll"

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ZStack(alignment: .bottom) {
                    HStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
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

                            if let summary = session.summary, summary.hasContent {
                                MeetingSummaryView(session: session) { turn in
                                    if audioPlayer.isAvailable { audioPlayer.playFrom(turn.startTime) }
                                    withAnimation { proxy.scrollTo(turn.id, anchor: .center) }
                                }
                            } else if !(viewModel.isGeneratingSummary && viewModel.selectedSession?.id == session.id) {
                                HomeDetailSection(title: "Resumo") {
                                    Text("Sem resumo ainda.")
                                        .font(.system(size: 13))
                                        .foregroundColor(VoizTheme.mutedText)
                                }
                            }

                            if !session.speakers.isEmpty && !session.turns.isEmpty {
                                MeetingParticipantsCard(session: session)
                            }

                            if !session.talkTimeStats.isEmpty {
                                MeetingTalkTimeCard(session: session)
                            }

                            MeetingNotesCard(session: session)

                            if audioPlayer.isAvailable {
                                MeetingPlayerBar(player: audioPlayer)
                                    .id(Self.playerBarID)
                                    .background {
                                        GeometryReader { geometry in
                                            Color.clear.preference(
                                                key: MeetingReviewPlayerFramePreferenceKey.self,
                                                value: geometry.frame(in: .named(Self.scrollSpaceName))
                                            )
                                        }
                                    }
                            }

                            if !session.turns.isEmpty {
                                MeetingChaptersCard(session: session, player: audioPlayer)
                            }

                            MeetingReviewTranscript(session: session, player: audioPlayer)

                            Spacer(minLength: 40)
                        }
                        .frame(maxWidth: MeetingLayout.maxWidth)
                        .padding(.horizontal, MeetingLayout.horizontalPadding)
                        .frame(maxWidth: .infinity)
                    }
                    .coordinateSpace(name: Self.scrollSpaceName)
                    .onPreferenceChange(MeetingReviewPlayerFramePreferenceKey.self) { frame in
                        updatePlayerBarPosition(frame, viewportHeight: viewport.size.height)
                    }

                    if companionReservedWidth(for: viewport.size.width) > 0 {
                        Color.clear
                            .frame(width: companionReservedWidth(for: viewport.size.width))
                    }
                    }
                    if audioPlayer.isAvailable && isFullPlayerAboveViewport {
                        MeetingFloatingPlayer(player: audioPlayer) {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(Self.playerBarID, anchor: .center)
                            }
                        }
                        .frame(maxWidth: MeetingLayout.maxWidth, alignment: .trailing)
                        .padding(.horizontal, MeetingLayout.horizontalPadding)
                        .frame(maxWidth: .infinity)
                        .padding(.trailing, companionReservedWidth(for: viewport.size.width))
                        .padding(.bottom, 16)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
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
                .animation(.easeOut(duration: 0.16), value: isFullPlayerAboveViewport)
                .onAppear {
                    companionOverlay.registerHost(session: session, player: audioPlayer, viewportWidth: viewport.size.width)
                }
                .onChange(of: viewport.size.width) { _, width in
                    syncCompanionOverlay(width: width)
                }
                .onChange(of: session) { previous, current in
                    if previous.id != current.id {
                        companionOverlay.registerHost(session: current, player: audioPlayer, viewportWidth: viewport.size.width)
                    } else {
                        syncCompanionOverlay(width: viewport.size.width)
                    }
                }
            }
        }
        .task(id: audioLoadIdentity) {
            isFullPlayerAboveViewport = false
            await loadAudio()
        }
        .onChange(of: session.turns) { _, newTurns in
            audioPlayer.updateTurns(newTurns)
        }
        .onDisappear { companionOverlay.dismissIfMatching(session.id, player: audioPlayer) }
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

    private func updatePlayerBarPosition(_ frame: CGRect?, viewportHeight: CGFloat) {
        let nextValue: Bool
        if audioPlayer.isAvailable, let frame, viewportHeight > 0 {
            // O mini-player só aparece depois que a barra passou pelo topo. Se ela ainda está
            // abaixo do viewport (usuário no início da página), não há player prematuro.
            nextValue = frame.maxY <= 0
        } else {
            nextValue = false
        }
        guard nextValue != isFullPlayerAboveViewport else { return }
        isFullPlayerAboveViewport = nextValue
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Participantes")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(VoizTheme.mutedText)
                .textCase(.uppercase)

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
                onCancel: { speakerToRename = nil },
                onSave: {
                    if let speaker = speakerToRename {
                        viewModel.renameSpeaker(speaker, to: renameDraft)
                    }
                    speakerToRename = nil
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

struct MeetingFloatingPlayer: View {
    let player: MeetingAudioPlayer
    let onReturnToFullPlayer: () -> Void
    @ObservedObject private var playback: MeetingPlayerPlaybackState

    init(player: MeetingAudioPlayer, onReturnToFullPlayer: @escaping () -> Void) {
        self.player = player
        self.onReturnToFullPlayer = onReturnToFullPlayer
        _playback = ObservedObject(wrappedValue: player.playbackState)
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: { player.togglePlayPause() }) {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(VoizTheme.accent.opacity(0.95))
                    .foregroundColor(.white)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playback.isPlaying ? Text("Pausar") : Text("Reproduzir"))

            Button(action: onReturnToFullPlayer) {
                HStack(spacing: 7) {
                    Text(meetingDurationLabel(playback.currentTime))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                    Text("/")
                        .foregroundColor(VoizTheme.mutedText.opacity(0.7))
                    Text(meetingDurationLabel(playback.duration))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(VoizTheme.mutedText)
                    Image(systemName: "arrow.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(VoizTheme.accent)
                }
                .foregroundColor(VoizTheme.primaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Voltar ao player completo")
            .accessibilityLabel("Voltar ao player completo")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .overlay(Capsule().stroke(VoizTheme.border))
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
    }
}

/// Capítulos gerados automaticamente no fluxo do resumo; clicar navega no player.
struct MeetingChaptersCard: View {
    @EnvironmentObject var viewModel: MeetingViewModel
    let session: MeetingSession
    @ObservedObject var player: MeetingAudioPlayer

    private var chapters: [MeetingChapter] { session.chapters ?? [] }
    private var isGenerating: Bool { viewModel.generatingSummarySessionIDs.contains(session.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Capítulos", systemImage: "list.bullet.indent")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(VoizTheme.primaryText)
                Spacer()
            }

            if isGenerating {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(viewModel.generatingChapterSessionIDs.contains(session.id) ? String(localized: "Gerando capítulos…") : String(localized: "Gerando resumo…"))
                        .font(.system(size: 12))
                        .foregroundColor(VoizTheme.mutedText)
                }
            } else if let error = session.chaptersError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(VoizTheme.mutedText)
            }
            if !isGenerating && chapters.isEmpty && session.chaptersError == nil {
                Text("Gerados junto com o resumo.")
                    .font(.system(size: 12))
                    .foregroundColor(VoizTheme.mutedText)
            } else if !chapters.isEmpty {
                VStack(spacing: 0) {
                    ForEach(chapters) { chapter in
                        Button(action: { player.playFrom(chapter.startTime) }) {
                            HStack(spacing: 10) {
                                Text(chapterTimeLabel(chapter.startTime))
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(VoizTheme.accent)
                                    .frame(width: 46, alignment: .leading)
                                Text(chapter.title)
                                    .font(.system(size: 13))
                                    .foregroundColor(VoizTheme.primaryText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if player.isAvailable {
                                    Image(systemName: "play.circle")
                                        .font(.system(size: 12))
                                        .foregroundColor(VoizTheme.mutedText)
                                }
                            }
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!player.isAvailable)
                    }
                }
            }
        }
        .padding(14)
        .background(VoizTheme.surfaceBackground)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(VoizTheme.border))
        .cornerRadius(12)
    }

    private func chapterTimeLabel(_ time: TimeInterval) -> String {
        let total = max(0, Int(time))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

struct MeetingReviewTranscript: View {
    let session: MeetingSession
    let player: MeetingAudioPlayer
    @ObservedObject private var turnPlayback: MeetingTurnPlaybackState

    init(session: MeetingSession, player: MeetingAudioPlayer) {
        self.session = session
        self.player = player
        _turnPlayback = ObservedObject(wrappedValue: player.turnPlaybackState)
    }

    var body: some View {
        let currentID = player.isAvailable ? turnPlayback.currentTurnID : nil
        HomeDetailSection(title: "Transcrição") {
            if session.turns.isEmpty {
                Text("Nenhuma fala registrada.")
                    .font(.system(size: 13))
                    .foregroundColor(VoizTheme.mutedText)
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(session.turns) { turn in
                        MeetingTurnBubble(
                            turn: turn,
                            isCurrent: turn.id == currentID,
                            onSeek: player.isAvailable ? { player.playFrom(turn.startTime) } : nil
                        )
                        .equatable()
                        .id(turn.id)
                    }
                }
            }
        }
    }
}

struct MeetingTurnBubble: View, Equatable {
    let turn: MeetingTurn
    var isCurrent: Bool = false
    var onSeek: (() -> Void)? = nil
    /// Quando true, revela o texto com o mesmo efeito de streaming da tela de tradução.
    /// Usado só no último turno ao vivo (o que está crescendo).
    var animated: Bool = false

    static func == (lhs: MeetingTurnBubble, rhs: MeetingTurnBubble) -> Bool {
        lhs.turn == rhs.turn
            && lhs.isCurrent == rhs.isCurrent
            && lhs.animated == rhs.animated
            && (lhs.onSeek == nil) == (rhs.onSeek == nil)
    }

    private var speakerColor: Color {
        meetingSpeakerColor(source: turn.source, speakerId: turn.speakerId)
    }

    /// Estilo Granola "Eu vs Outros": o bucket é a **fonte** do turn (mic = Você, sistema = Outros).
    /// Você vai à esquerda com o tom da própria cor; Outros à direita, neutro/mais claro — assim
    /// todos os participantes ficam visualmente uniformes (a identidade fina segue no rótulo/cor do nome).
    private var isMe: Bool { turn.source == .microphone }

    private var bubbleFill: Color {
        if isMe { return speakerColor.opacity(isCurrent ? 0.30 : 0.16) }
        return isCurrent ? VoizTheme.selectedBackground : VoizTheme.assistantBubbleBackground
    }

    var body: some View {
        HStack(spacing: 0) {
            if !isMe { Spacer(minLength: 56) }
            bubble
            if isMe { Spacer(minLength: 56) }
        }
        .frame(maxWidth: .infinity)
    }

    private var bubble: some View {
        VStack(alignment: isMe ? .leading : .trailing, spacing: 3) {
            HStack(spacing: 6) {
                Text(turn.speakerName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(speakerColor)
                timeView
            }
            StreamingText(
                text: turn.text,
                font: .system(size: 14),
                color: VoizTheme.primaryText,
                lineSpacing: 3,
                animated: animated
            )
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(bubbleFill)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isCurrent ? speakerColor.opacity(0.7) : VoizTheme.border, lineWidth: isCurrent ? 1.5 : 1)
        )
        .cornerRadius(12)
    }

    @ViewBuilder
    private var timeView: some View {
        if let onSeek {
            Button(action: onSeek) {
                HStack(spacing: 3) {
                    Image(systemName: "play.fill").font(.system(size: 8))
                    Text(timeLabel).font(.caption2)
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Tocar a partir daqui")
            .accessibilityLabel(Text("Tocar a partir daqui"))
            .accessibilityValue(Text(timeLabel))
        } else {
            Text(timeLabel)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var timeLabel: String {
        let minutes = Int(turn.startTime) / 60
        let seconds = Int(turn.startTime) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Summary (seções dinâmicas)

/// Renderiza o resumo a partir das seções dinâmicas do template. Parágrafos e tópicos são
/// somente leitura; action items viram checkboxes acionáveis. Reusado na revisão e na Home.
struct MeetingSummaryView: View {
    let session: MeetingSession
    var onRevealTurn: ((MeetingTurn) -> Void)? = nil

    var body: some View {
        if let summary = session.summary {
            ForEach(summary.sections) { section in
                if !section.isEmpty {
                    sectionView(section)
                }
            }
        }
    }

    @ViewBuilder
    private func sectionView(_ section: MeetingSummarySection) -> some View {
        switch section.kind {
        case .paragraph:
            HomeDetailSection(title: LocalizedStringKey(section.title)) {
                Text(section.paragraph)
                    .font(.system(size: 15))
                    .foregroundColor(VoizTheme.primaryText)
                    .textSelection(.enabled)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                MeetingEvidenceLinks(session: session, section: section, itemIndex: 0, onRevealTurn: onRevealTurn)
            }
        case .bullets:
            HomeDetailSection(title: LocalizedStringKey(section.title)) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(section.bullets.enumerated()), id: \.offset) { index, text in
                        VStack(alignment: .leading, spacing: 4) {
                            HomeDetailBulletList(items: [text])
                            MeetingEvidenceLinks(session: session, section: section, itemIndex: index, onRevealTurn: onRevealTurn)
                        }
                    }
                }
            }
        case .actionItems:
            HomeDetailSection(title: LocalizedStringKey(section.title)) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(section.actionItems.enumerated()), id: \.element.id) { index, item in
                        VStack(alignment: .leading, spacing: 4) {
                            MeetingActionItemRow(sessionId: session.id, sectionId: section.id, item: item)
                            MeetingEvidenceLinks(session: session, section: section, itemIndex: index, onRevealTurn: onRevealTurn)
                        }
                    }
                }
            }
        }
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
