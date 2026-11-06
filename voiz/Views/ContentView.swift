import SwiftUI
import Combine
import AppKit

struct ContentView: View {
    @EnvironmentObject var viewModel: TranscriptionViewModel
    @StateObject private var translationViewModel: TranslationViewModel
    @StateObject private var meetingViewModel: MeetingViewModel
    @StateObject private var chatViewModel = VoizChatViewModel()
    @StateObject private var navigation = VoizNavigation()
    @StateObject private var companionOverlay = MeetingReviewCompanionPresentation()
    @State private var updateActivityID = UUID()
    @State private var selectedTab = 0
    @State private var isSearchOpen = false
    @State private var isCompactSidebarOpen = false
    @AppStorage("voiz.sidebar.width") private var sidebarWidth: Double = 244
    @AppStorage("voiz.sidebar.visible") private var isSidebarVisible: Bool = true
    @State private var sidebarLiveWidth: CGFloat = 244
    @State private var sidebarDragStartWidth: Double?
    @State private var isHoveringSidebarHandle = false
    @State private var trafficLightCenterY: CGFloat = VoizWindowChrome.titleBarHeight / 2

    private let sidebarMinWidth: CGFloat = 208
    private let sidebarMaxWidth: CGFloat = 340
    /// Abaixo disso a barra vira gaveta. Com a barra na largura máxima, a lista de Reuniões
    /// (420 pt + margens) ainda cabe ao lado.
    private let dockedSidebarMinimumWindowWidth: CGFloat = 820
    /// As telas usam margens estreitas quando sobra pouca largura ao lado da barra.
    private let compactContentMaximumWidth: CGFloat = 720

    init() {
        let settingsStore = SettingsStore()
        _translationViewModel = StateObject(wrappedValue: TranslationViewModel(settingsStore: settingsStore))
        // O view model NÃO pode nascer aqui fora do `StateObject`: a SwiftUI reexecuta este
        // `init` toda vez que o body do `VoizApp` é reavaliado, e só a PRIMEIRA instância
        // sobrevive. Construído eagerly, cada instância descartada já tinha rodado o
        // recovery do `MeetingViewModel.init` e disparado o pós-processamento (com as
        // chamadas pagas de resumo e nomes) da mesma reunião — dezenas de vezes por hora.
        // O autoclosure do `StateObject` só constrói uma vez, quando a View se instala.
        _meetingViewModel = StateObject(wrappedValue: Self.makeMeetingViewModel(settingsStore: settingsStore))
    }

    private static func makeMeetingViewModel(settingsStore: SettingsStore) -> MeetingViewModel {
        let meeting = MeetingViewModel(settingsStore: settingsStore)
        // Factory preguiçosa: cada gravação Granola pede uma instância NOVA.
        // wireProvider não invoca make() — o boot não constrói o SpeechAnalyzer.
        meeting.liveTranscriberProvider = MeetingRecordingLifecycle.wireProvider {
            AppleSpeechMeetingTranscriber.make()
        }
        return meeting
    }
    
    var body: some View {
        GeometryReader { viewport in
            let compact = viewport.size.width < dockedSidebarMinimumWindowWidth
            let sidebarDocked = !compact && isSidebarVisible
            let contentWidth = viewport.size.width - (sidebarDocked ? sidebarLiveWidth + 4 : 0)
            shell(compact: compact, width: viewport.size.width)
                .environment(\.voizCompactLayout, contentWidth < compactContentMaximumWidth)
                .environment(\.voizWindowSize, viewport.size)
                // Datas, horas e o DatePicker seguem o idioma da interface, não a região do sistema.
                .environment(\.locale, .voizInterface)
                .onChange(of: compact) { _, _ in isCompactSidebarOpen = false }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { VoizAccessNotice { selectedTab = 5 } }
    }

    private func shell(compact: Bool, width: CGFloat) -> some View {
        HStack(spacing: 0) {
            if !compact && isSidebarVisible {
                VoizSidebar(
                    selectedTab: $selectedTab,
                    meetingViewModel: meetingViewModel,
                    onToggleSidebar: { isSidebarVisible = false },
                    onOpenSearch: { isSearchOpen = true }
                )
                .environmentObject(navigation)
                .frame(width: sidebarLiveWidth)
                .transition(.move(edge: .leading).combined(with: .opacity))

                sidebarResizeHandle
            }

            VStack(spacing: 0) {
                ZStack {
                    VoizTheme.appBackground.ignoresSafeArea()

                    switch selectedTab {
                    case 0:
                        HomeDashboardView(selectedTab: $selectedTab)
                            .environmentObject(meetingViewModel)
                            .environmentObject(chatViewModel)
                            .environmentObject(navigation)
                    case 1:
                        VoizChatView()
                            .environmentObject(meetingViewModel)
                            .environmentObject(chatViewModel)
                            .environmentObject(navigation)
                    case 2:
                        TranscriptionTab()
                            .environmentObject(navigation)
                    case 3:
                        TranslationView()
                            .environmentObject(translationViewModel)
                            .environmentObject(navigation)
                    case 4:
                        MeetingView()
                            .environmentObject(meetingViewModel)
                            .environmentObject(navigation)
                    case 5:
                        VoizProfileView()
                    case 6:
                        VoizSettingsView(calendarService: meetingViewModel.calendarService) {
                            selectedTab = 5
                        }
                    default:
                        HomeDashboardView(selectedTab: $selectedTab)
                            .environmentObject(meetingViewModel)
                    }
                }
                // O seletor "/" do chat mede aqui quanto há de espaço acima e abaixo do composer
                // para decidir de que lado abrir e até onde pode crescer.
                .coordinateSpace(name: ChatSlashCommandPickerModifier.containerSpace)
            }
            .padding(.top, VoizWindowChrome.sidebarContentTopInset)
        }
        .accessibilityHidden((compact && isCompactSidebarOpen) || companionOverlay.isOverlay)
        .environmentObject(companionOverlay)
        .environment(\.voizCompanionOverlayWindowHosted, true)
        .environment(\.locale, .voizInterface)
        .overlay(alignment: .trailing) {
            if companionOverlay.showsWindowPanel,
               let session = companionOverlay.session,
               let player = companionOverlay.player {
                MeetingReviewCompanionDrawer(
                    session: session,
                    player: player,
                    presentation: companionOverlay,
                    chrome: .windowOverlay,
                    dimsBackground: companionOverlay.isOverlay
                )
                .environmentObject(meetingViewModel)
            }
        }
        .overlay(alignment: .leading) {
            if compact && isCompactSidebarOpen {
                ZStack(alignment: .leading) {
                    Color.black.opacity(0.25)
                        .contentShape(Rectangle())
                        .onTapGesture { isCompactSidebarOpen = false }
                        .accessibilityLabel(Text("Ocultar barra lateral"))
                        .accessibilityAddTraits(.isButton)
                    VoizSidebar(
                        selectedTab: Binding(
                            get: { selectedTab },
                            set: { selectedTab = $0; isCompactSidebarOpen = false }
                        ),
                        meetingViewModel: meetingViewModel,
                        onToggleSidebar: { isCompactSidebarOpen = false },
                        onOpenSearch: {
                            isCompactSidebarOpen = false
                            isSearchOpen = true
                        }
                    )
                    .environmentObject(navigation)
                    .frame(width: min(sidebarLiveWidth, 280))
                    .shadow(color: .black.opacity(0.22), radius: 18, x: 8)
                }
                .transition(.opacity)
            }
        }
        .overlay(alignment: .topLeading) {
            topChrome(compact: compact, width: width)
        }
        .animation(.easeInOut(duration: 0.16), value: isCompactSidebarOpen)
        .animation(.easeInOut(duration: 0.16), value: companionOverlay.showsWindowPanel)
        // O desfoque entra *antes* da paleta: aplicado depois, borraria a paleta junto.
        .blur(radius: isSearchOpen ? 9 : 0)
        .overlay {
            if isSearchOpen {
                VoizSearchPalette(
                    transcriptionViewModel: viewModel,
                    meetingViewModel: meetingViewModel,
                    translationStore: translationViewModel.historyStore,
                    onOpen: open,
                    onDismiss: { isSearchOpen = false }
                )
                .zIndex(10)
            }
        }
        // Botão invisível só para registrar o ⌘K na janela — o menu "Buscar…" também o dispara,
        // mas o atalho precisa funcionar mesmo com o foco dentro de um campo de texto.
        .background {
            Button("") { isSearchOpen = true }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .animation(.easeOut(duration: 0.14), value: isSearchOpen)
        .background(VoizTheme.appBackground)
        .preferredColorScheme(viewModel.settings.appearance.colorScheme)
        // Aqui o `StateObject` já foi instalado pelo SwiftUI. Fazer esse attach no init poderia
        // conectar o singleton a um MeetingViewModel temporário descartado numa reinicialização.
        .onAppear {
            LocalMCPServer.shared.attach(to: meetingViewModel.store)
            let protectedWork: () -> Bool? = { [weak viewModel, weak meetingViewModel, weak translationViewModel] in
                guard viewModel != nil || meetingViewModel != nil || translationViewModel != nil else { return nil }
                let activeStates: [TranscriptionState] = [.listening, .processing]
                return activeStates.contains(viewModel?.state ?? .idle)
                    || activeStates.contains(translationViewModel?.state ?? .idle)
                    || activeStates.contains(meetingViewModel?.state ?? .idle)
                    || meetingViewModel?.activeSession != nil
                    || meetingViewModel?.isStartingMeeting == true
                    || meetingViewModel?.hasActivePostProcessing == true
                    || meetingViewModel?.isGeneratingSummary == true
                    || !(meetingViewModel?.generatingChapterSessionIDs.isEmpty ?? true)
                    || meetingViewModel?.assistRunning == true
            }
            VoizWorkTracker.shared.registerActivity(id: updateActivityID, check: protectedWork)
            VoizDevelopmentLifecycle.shared.registerActivity(id: updateActivityID) {
                [weak meetingViewModel, weak translationViewModel, weak chatViewModel] in
                // Dictation has a process-wide registration; a closed window can expire independently.
                guard meetingViewModel != nil || translationViewModel != nil || chatViewModel != nil else { return nil }
                return (protectedWork() ?? false) || chatViewModel?.isSending == true
            }
        }
        // Both update and Dev-quit checks remain weakly registered while background work outlives a window.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
        .onAppear {
            sidebarLiveWidth = min(max(CGFloat(sidebarWidth), sidebarMinWidth), sidebarMaxWidth)
        }
        .onChange(of: selectedTab) { oldValue, newValue in
            if oldValue == 0 && newValue != 0 {
                chatViewModel.resetHomeChat()
            }
            if oldValue == 1 && newValue != 1 {
                chatViewModel.startNewChat()
            }
            if newValue != 4 {
                companionOverlay.dismiss()
            }
        }
        .onChange(of: navigation.calendarEvent?.id) { _, eventID in
            if eventID != nil { companionOverlay.dismiss() }
        }
        .animation(.easeInOut(duration: 0.16), value: isSidebarVisible)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("OpenVoizSettings"))) { _ in
            isCompactSidebarOpen = false
            selectedTab = 6
        }
        // Card flutuante "Reunião detectada" → botão Gravar abre direto a aba Reuniões.
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("VoizOpenMeetingsTab"))) { _ in
            isCompactSidebarOpen = false
            navigation.calendarEvent = nil
            selectedTab = 4
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("VoizOpenSearch"))) { _ in
            isCompactSidebarOpen = false
            isSearchOpen = true
        }
        // Citação clicada no Chat: a aba de destino entra e depois consome o `pendingOpen`.
        .onChange(of: navigation.requestedTab) { _, tab in
            guard let tab else { return }
            // Mesma ressalva do ⌘K: dentro de uma pasta a lista filtra as sessões, e a reunião
            // citada pode não estar nela. O `!= nil` evita publicar uma mudança que não muda nada
            // — é uma invalidação de view a menos no meio da troca de aba.
            if tab == VoizSearchKind.meeting.tab, meetingViewModel.viewingFolderId != nil {
                meetingViewModel.viewingFolderId = nil
            }
            selectedTab = tab
            navigation.requestedTab = nil
        }
    }

    /// Fecha a paleta, troca para a aba do resultado e deixa o item pendente para a tela abrir.
    private func open(_ result: VoizSearchResult) {
        isSearchOpen = false
        // Sair de uma pasta é necessário para a reunião aparecer — a pasta filtra as sessões.
        if result.kind == .meeting {
            meetingViewModel.viewingFolderId = nil
        }
        navigation.open(result)
        selectedTab = result.kind.tab
    }

    private func topChrome(compact: Bool, width: CGFloat) -> some View {
        ZStack {
            WindowDragArea()

            HStack(spacing: 6) {
                Color.clear
                    .frame(width: VoizWindowChrome.trafficLightInset)
                    .allowsHitTesting(false)

                VoizTitleBarSidebarButton(isSidebarVisible: compact ? isCompactSidebarOpen : isSidebarVisible) {
                    if compact {
                        isCompactSidebarOpen.toggle()
                    } else {
                        isSidebarVisible.toggle()
                    }
                }

                Button {
                    isCompactSidebarOpen = false
                    isSearchOpen = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(VoizTheme.mutedText)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Buscar")
                .accessibilityLabel(Text("Buscar"))
                Spacer(minLength: 0)
                if AppEnvironment.current.isDevelopment {
                    DevelopmentBuildBadge()
                        .padding(.trailing, selectedTab == 4 && companionOverlay.hasReview ? 4 : 12)
                }
                if selectedTab == 4 && companionOverlay.hasReview {
                    MeetingReviewToolbar(presentation: companionOverlay)
                        .padding(.trailing, 12)
                }
            }

            if selectedTab != 4, let session = meetingViewModel.activeSession {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VoizActiveMeetingButton(
                        title: session.title,
                        isRecording: meetingViewModel.state == .listening,
                        isPaused: meetingViewModel.meetingPaused,
                        duration: meetingViewModel.meetingDuration(for: session, at: context.date)
                    ) {
                        isCompactSidebarOpen = false
                        meetingViewModel.viewingFolderId = nil
                        meetingViewModel.selectedSession = session
                        selectedTab = 4
                    }
                    .frame(maxWidth: min(380, max(200, width - (AppEnvironment.current.isDevelopment ? 440 : 340))))
                }
            }
        }
        .frame(height: VoizWindowChrome.titleBarHeight)
        .padding(.top, max(0, trafficLightCenterY - VoizWindowChrome.titleBarHeight / 2))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WindowButtonReader(centerY: $trafficLightCenterY).allowsHitTesting(false))
        .ignoresSafeArea(.container, edges: .top)
    }

    private var sidebarResizeHandle: some View {
        ZStack {
            Rectangle()
                .fill(VoizTheme.sidebarHairline)
                .frame(width: 1)

            RoundedRectangle(cornerRadius: 2)
                .fill(isHoveringSidebarHandle ? VoizTheme.accent.opacity(0.75) : Color.clear)
                .frame(width: 2, height: 42)
        }
            .frame(width: 4)
            .contentShape(Rectangle())
            .onHover { isHoveringSidebarHandle = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if sidebarDragStartWidth == nil {
                            sidebarDragStartWidth = Double(sidebarLiveWidth)
                        }

                        let start = sidebarDragStartWidth ?? Double(sidebarLiveWidth)
                        let proposed = CGFloat(start + value.translation.width)
                        sidebarLiveWidth = min(max(proposed, sidebarMinWidth), sidebarMaxWidth)
                    }
                    .onEnded { _ in
                        sidebarWidth = Double(sidebarLiveWidth)
                        sidebarDragStartWidth = nil
                    }
            )
            .help("Arraste para redimensionar")
    }
}

enum VoizTheme {
    /// `NSColor` dinâmico acompanha tanto o macOS quanto uma preferência imposta por
    /// `preferredColorScheme`, sem obrigar cada tela a receber `colorScheme` pelo Environment.
    private static func adaptive(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    private static func gray(_ white: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: white, green: white, blue: white, alpha: alpha)
    }

    static let appBackground = adaptive(
        dark: rgb(0.105, 0.106, 0.120),
        light: rgb(0.957, 0.945, 0.918)
    )
    static let sidebarBackground = adaptive(
        dark: rgb(0.125, 0.126, 0.145),
        light: rgb(0.925, 0.910, 0.875)
    )
    static let elevatedBackground = adaptive(
        dark: gray(1, 0.052),
        light: gray(0, 0.045)
    )
    static let surfaceBackground = adaptive(
        dark: gray(1, 0.035),
        light: rgb(0.982, 0.973, 0.954)
    )
    static let hoverBackground = adaptive(
        dark: gray(1, 0.055),
        light: gray(0, 0.045)
    )
    static let selectedBackground = adaptive(
        dark: gray(1, 0.075),
        light: rgb(0.32, 0.29, 0.82, 0.11)
    )
    static let border = adaptive(
        dark: gray(1, 0.09),
        light: gray(0, 0.10)
    )
    /// Borda no hover — o realce vem do contorno, não só do preenchimento.
    static let borderStrong = adaptive(
        dark: gray(1, 0.17),
        light: gray(0, 0.19)
    )
    static let sidebarHairline = adaptive(
        dark: gray(1, 0.045),
        light: gray(0, 0.08)
    )
    static let mutedText = adaptive(
        dark: gray(1, 0.62),
        light: gray(0, 0.54)
    )
    static let primaryText = adaptive(
        dark: gray(1, 0.90),
        light: gray(0, 0.78)
    )
    static let accent = adaptive(
        dark: rgb(0.56, 0.54, 1.0),
        light: rgb(0.32, 0.29, 0.82)
    )
    static let accentBright = adaptive(
        dark: rgb(0.67, 0.64, 1.0),
        light: rgb(0.40, 0.37, 0.90)
    )
    static let chatPanelBackground = adaptive(
        dark: rgb(0.118, 0.119, 0.133),
        light: rgb(0.980, 0.965, 0.937)
    )
    static let iconBackground = adaptive(
        dark: gray(1, 0.10),
        light: gray(0, 0.055)
    )
    static let assistantBubbleBackground = adaptive(
        dark: gray(1, 0.07),
        light: gray(0, 0.035)
    )

    /// Preenchimento dos CTAs principais.
    static let accentGradient = LinearGradient(
        colors: [accentBright, accent],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Fundo dos cartões-herói: um leve brilho do acento no canto superior esquerdo,
    /// dissolvendo na superfície neutra.
    static let heroCardGradient = LinearGradient(
        colors: [
            adaptive(dark: rgb(0.175, 0.170, 0.220), light: rgb(0.925, 0.905, 0.970)),
            adaptive(dark: rgb(0.138, 0.138, 0.158), light: rgb(0.965, 0.948, 0.920)),
            adaptive(dark: rgb(0.128, 0.129, 0.142), light: rgb(0.982, 0.973, 0.954))
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let sidebarGradient = LinearGradient(
        colors: [
            adaptive(dark: rgb(0.155, 0.160, 0.185), light: rgb(0.940, 0.920, 0.965)),
            adaptive(dark: rgb(0.128, 0.138, 0.150), light: rgb(0.932, 0.918, 0.890)),
            sidebarBackground
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

extension AppSettings.InterfaceAppearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

private struct VoizCompactLayoutKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var voizCompactLayout: Bool {
        get { self[VoizCompactLayoutKey.self] }
        set { self[VoizCompactLayoutKey.self] = newValue }
    }

    /// Tamanho da área da janela principal. Folhas grandes limitam-se a ele para não passar da borda.
    var voizWindowSize: CGSize {
        get { self[VoizWindowSizeKey.self] }
        set { self[VoizWindowSizeKey.self] = newValue }
    }
}

private struct VoizWindowSizeKey: EnvironmentKey {
    static let defaultValue = CGSize(width: 1_200, height: 800)
}

/// Presente fora da seção Reuniões durante a sessão; a ação só navega para a gravação.
struct VoizActiveMeetingButton: View {
    let title: String
    let isRecording: Bool
    let isPaused: Bool
    let duration: TimeInterval
    let action: () -> Void

    private var status: String {
        if !isRecording { return String(localized: "Preparando reunião…") }
        return isPaused ? String(localized: "Pausado") : String(localized: "Gravando")
    }

    private var timeLabel: String {
        let total = max(0, Int(duration))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: !isRecording ? "hourglass" : (isPaused ? "pause.fill" : "waveform"))
                    .foregroundStyle(isPaused || !isRecording ? Color.orange : Color.green)
                Text(status)
                    .fixedSize()
                Text(title)
                    .foregroundStyle(VoizTheme.mutedText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if isRecording {
                    Text(timeLabel)
                        .monospacedDigit()
                        .fixedSize()
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(VoizTheme.mutedText)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(VoizTheme.primaryText)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(VoizTheme.chatPanelBackground, in: Capsule())
            .overlay(Capsule().stroke(VoizTheme.border))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Voltar à reunião em andamento")
        .accessibilityLabel(Text("\(status), \(title), \(timeLabel)"))
        .accessibilityHint(Text("Voltar à reunião em andamento"))
    }
}

enum VoizWindowChrome {
    static let trafficLightInset: CGFloat = 74
    static let titleBarHeight: CGFloat = 28
    static let sidebarContentTopInset: CGFloat = 38
}

struct VoizTitleBarSidebarButton: View {
    let isSidebarVisible: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(VoizTheme.mutedText.opacity(isHovering ? 1 : 0.82))
                .frame(width: 28, height: 28)
                .background(isHovering ? VoizTheme.hoverBackground : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isSidebarVisible ? "Ocultar barra lateral" : "Mostrar barra lateral")
        // Sem rótulo, o VoiceOver lê o nome do símbolo ("Split View Horizontalmente À Esquerda").
        .accessibilityLabel(isSidebarVisible ? Text("Ocultar barra lateral") : Text("Mostrar barra lateral"))
    }
}

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowDragView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowDragView: NSView {
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }

        if event.clickCount >= 2 {
            performDoubleClickAction(on: window)
        } else {
            window.performDrag(with: event)
        }
    }

    /// Mirrors the macOS "Double-click a window's title bar to…" preference.
    private func performDoubleClickAction(on window: NSWindow) {
        let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
        switch action {
        case "Minimize":
            window.miniaturize(nil)
        case "None":
            break
        default:
            window.zoom(nil)
        }
    }
}

/// Reads the real macOS traffic-light vertical center (in points from the content top)
/// so the sidebar toggle can be aligned exactly with the window buttons.
struct WindowButtonReader: NSViewRepresentable {
    @Binding var centerY: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        scheduleMeasure(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        scheduleMeasure(from: nsView)
    }

    private func scheduleMeasure(from view: NSView) {
        DispatchQueue.main.async {
            measure(from: view, attempt: 0)
        }
    }

    private func measure(from view: NSView, attempt: Int) {
        guard let window = view.window,
              let close = window.standardWindowButton(.closeButton),
              let contentView = window.contentView else {
            if attempt < 10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    measure(from: view, attempt: attempt + 1)
                }
            }
            return
        }

        let buttonInScreen = window.convertToScreen(close.convert(close.bounds, to: nil))
        let contentInScreen = window.convertToScreen(contentView.convert(contentView.bounds, to: nil))
        let centerFromTop = contentInScreen.maxY - buttonInScreen.midY

        if centerFromTop > 0, abs(centerFromTop - centerY) > 0.5 {
            centerY = centerFromTop
        }
    }
}

struct VoizSidebar: View {
    @ObservedObject private var profileStore = UserProfileStore.shared
    @EnvironmentObject var viewModel: TranscriptionViewModel
    @EnvironmentObject var navigation: VoizNavigation
    @Binding var selectedTab: Int
    @ObservedObject var meetingViewModel: MeetingViewModel
    let onToggleSidebar: () -> Void
    let onOpenSearch: () -> Void
    /// Recolhe a lista de pastas sob "Reuniões" (persistido entre sessões).
    @AppStorage("voiz.sidebar.meetingFoldersCollapsed") private var foldersCollapsed = false
    @State private var showCreateFolderSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onOpenSearch) {
                VoizHoverSurface(shape: .rounded(10)) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                        Text("Buscar")
                            .font(.system(size: 12))
                        Spacer()
                        Text("⌘K")
                            .font(.system(size: 10, weight: .medium))
                            .opacity(0.8)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                }
            }
            .buttonStyle(.plain)
            .help("Buscar em reuniões, ditados e traduções")

            VStack(spacing: 2) {
                SidebarNavigationRow(title: "Início", systemImage: "house", isSelected: selectedTab == 0) {
                    selectedTab = 0
                }
                SidebarNavigationRow(title: "Chat", systemImage: "bubble.left", isSelected: selectedTab == 1) {
                    selectedTab = 1
                }
                SidebarNavigationRow(title: "Ditado", systemImage: "waveform", isSelected: selectedTab == 2) {
                    selectedTab = 2
                }
                SidebarNavigationRow(
                    title: "Reuniões",
                    systemImage: "person.2.wave.2",
                    isSelected: selectedTab == 4 && meetingViewModel.viewingFolderId == nil,
                    action: { openMeetingsAndToggleFolders() },
                    isCollapsed: foldersCollapsed,
                    onToggleCollapse: meetingViewModel.folders.isEmpty ? nil : {
                        openMeetingsAndToggleFolders()
                    },
                    onAdd: { showCreateFolderSheet = true }
                )
                // Pastas de reuniões aninhadas sob "Reuniões", estilo Spaces do Granola.
                if !foldersCollapsed {
                    ForEach(meetingViewModel.folders) { folder in
                        SidebarFolderRow(
                            title: folder.name,
                            isSelected: selectedTab == 4 && meetingViewModel.viewingFolderId == folder.id
                        ) {
                            navigation.calendarEvent = nil
                            meetingViewModel.viewingFolderId = folder.id
                            selectedTab = 4
                        }
                    }
                }
                SidebarNavigationRow(title: "Tradução", systemImage: "translate", isSelected: selectedTab == 3) {
                    selectedTab = 3
                }
            }

            Spacer()

            profileMenu
                .padding(.top, 7)
                .overlay(Rectangle().fill(VoizTheme.border).frame(height: 1), alignment: .top)
        }
        .padding(.horizontal, 10)
        .padding(.top, VoizWindowChrome.sidebarContentTopInset)
        .padding(.bottom, 10)
        .background(VoizTheme.sidebarBackground)
        .sheet(isPresented: $showCreateFolderSheet) {
            MeetingFolderSheet(
                heading: "Criar pasta",
                confirmLabel: "Criar",
                onCancel: { showCreateFolderSheet = false },
                onSave: { name, details in
                    meetingViewModel.createFolder(name: name, details: details)
                    // Garante que a pasta recém-criada apareça na sidebar.
                    foldersCollapsed = false
                    showCreateFolderSheet = false
                }
            )
        }
    }

    /// Primeiro seleciona Reuniões; só alterna as pastas quando a raiz já estava selecionada.
    private func openMeetingsAndToggleFolders() {
        let wasMeetingsSelected = selectedTab == 4
            && meetingViewModel.viewingFolderId == nil
            && navigation.calendarEvent == nil
        navigation.calendarEvent = nil
        meetingViewModel.viewingFolderId = nil
        selectedTab = 4

        guard !meetingViewModel.folders.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            foldersCollapsed = wasMeetingsSelected ? !foldersCollapsed : false
        }
    }

    private var profileMenu: some View {
        Menu {
            Button(action: { selectedTab = 5 }) {
                Label("Perfil", systemImage: "person.crop.circle")
            }

            Button(action: { selectedTab = 6 }) {
                Label("Configurações", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)

            Divider()

            Button(role: .destructive, action: { NSApp.terminate(nil) }) {
                Label("Sair do Voiz", systemImage: "power")
            }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(VoizTheme.elevatedBackground)
                    Text(profileStore.profile.displayName.prefix(1).uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(VoizTheme.primaryText)
                }
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(profileStore.profile.displayName)
                        .lineLimit(1)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(VoizTheme.primaryText)
                }

                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(VoizTheme.mutedText)
                    .accessibilityHidden(true)
            }
            // O VoiceOver lê "nome, plano" como um item só, não a inicial e o chevron soltos.
            .accessibilityElement(children: .combine)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .help("Perfil e configurações")
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

}

struct SidebarNavigationRow: View {
    /// `LocalizedStringKey` para os rótulos fixos da navegação localizarem sozinhos. As pastas de
    /// reunião ficam no `SidebarFolderRow`, que segue com `String` — nome de pasta é dado do usuário.
    let title: LocalizedStringKey
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void
    /// Acessórios opcionais (linha "Reuniões", estilo Granola): chevron à esquerda para
    /// recolher/expandir as pastas e "+" à direita para criar pasta. Aparecem no hover.
    var isCollapsed: Bool = false
    var onToggleCollapse: (() -> Void)? = nil
    var onAdd: (() -> Void)? = nil
    @State private var isHovering = false

    /// Chevron só no hover (como no Granola); fora dele a linha mostra o ícone normal,
    /// mesmo com as pastas recolhidas.
    private var showsChevron: Bool {
        onToggleCollapse != nil && isHovering
    }

    var body: some View {
        // A linha inteira é o alvo de clique (`contentShape` + `onTapGesture` na altura cheia):
        // antes o texto ficava num `Button` sem altura própria e só a faixa fina da fonte
        // respondia ao clique. Chevron e "+" continuam como botões, e consomem o próprio clique.
        HStack(spacing: 0) {
            leadingSlot

            Text(title)
                .font(.system(size: 13, weight: .medium))
                .padding(.leading, 10)

            Spacer(minLength: 0)

            if let onAdd, isHovering {
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Nova pasta")
            }
        }
        .foregroundColor(isSelected ? VoizTheme.primaryText : VoizTheme.mutedText)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .background(backgroundColor)
        .cornerRadius(9)
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onTapGesture(perform: action)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { action() }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    /// Ícone (decorativo — o clique é da linha) ou chevron (recolhe/expande) no hover.
    @ViewBuilder
    private var leadingSlot: some View {
        if let onToggleCollapse, showsChevron {
            Button(action: onToggleCollapse) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "Mostrar pastas" : "Recolher pastas")
            .accessibilityLabel(isCollapsed ? Text("Mostrar pastas") : Text("Recolher pastas"))
        } else {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 20, height: 20)
        }
    }

    private var backgroundColor: Color {
        if isSelected {
            return VoizTheme.selectedBackground
        }
        if isHovering {
            return VoizTheme.hoverBackground
        }
        return Color.clear
    }
}

/// Linha de pasta de reuniões na sidebar, indentada sob "Reuniões" (estilo Spaces do Granola).
struct SidebarFolderRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Spacer()
            }
            .foregroundColor(isSelected ? VoizTheme.primaryText : VoizTheme.mutedText)
            .padding(.leading, 26)
            .padding(.trailing, 9)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .background(backgroundColor)
            .cornerRadius(9)
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var backgroundColor: Color {
        if isSelected {
            return VoizTheme.selectedBackground
        }
        if isHovering {
            return VoizTheme.hoverBackground
        }
        return Color.clear
    }
}

struct GranolaPillButtonStyle: ButtonStyle {
    var accented = false
    /// Ações destrutivas ficam neutras em repouso e assumem o vermelho no hover.
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        VoizHoverSurface(
            isPressed: configuration.isPressed,
            shape: .capsule,
            accented: accented,
            destructive: destructive
        ) {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
        }
    }
}

struct GranolaIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        VoizHoverSurface(isPressed: configuration.isPressed, shape: .rounded(8)) {
            configuration.label
                .frame(width: 30, height: 30)
        }
    }
}

/// Caixa dos seletores (`SettingsDropdown`): cantos levemente arredondados em vez de cápsula,
/// para não competir com os botões de ação ao lado.
struct VoizDropdownButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        VoizHoverSurface(isPressed: configuration.isPressed, shape: .rounded(8)) {
            configuration.label
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
        }
    }
}

struct VoizTinyIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        VoizHoverSurface(isPressed: configuration.isPressed, shape: .rounded(8)) {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 28)
        }
    }
}

/// Botão primário (Salvar) em destaque com a cor de acento do app.
struct VoizPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AccentBody(configuration: configuration)
    }

    private struct AccentBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(VoizTheme.accent.opacity(fillOpacity))
                .clipShape(Capsule())
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { isHovering = $0 && isEnabled }
                .animation(.easeOut(duration: 0.12), value: isHovering)
        }

        private var fillOpacity: Double {
            if configuration.isPressed { return 0.78 }
            return isHovering ? 1 : 0.9
        }
    }
}

/// CTA principal das telas (Iniciar gravação, Começar a ditar). Preenchimento com o acento,
/// brilho difuso embaixo e leve resposta ao hover/pressionar — é o único botão "cheio" de cada
/// tela, por isso concentra o peso visual.
struct VoizCTAButtonStyle: ButtonStyle {
    /// Estado "em andamento" (gravando) — troca o acento pelo vermelho.
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        CTABody(configuration: configuration, isActive: isActive)
    }

    private struct CTABody: View {
        let configuration: Configuration
        let isActive: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        private var isHighlighted: Bool { isHovering && isEnabled }
        private var tint: Color { isActive ? .red : VoizTheme.accent }

        private var fill: LinearGradient {
            isActive
                ? LinearGradient(colors: [Color.red.opacity(0.92), Color.red.opacity(0.74)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing)
                : VoizTheme.accentGradient
        }

        var body: some View {
            configuration.label
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background { fill.opacity(isHighlighted ? 1 : 0.92) }
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Color.white.opacity(isHighlighted ? 0.22 : 0.12))
                )
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .shadow(color: tint.opacity(isEnabled ? (isHighlighted ? 0.40 : 0.24) : 0),
                        radius: isHighlighted ? 16 : 10,
                        y: isHighlighted ? 6 : 4)
                .scaleEffect(configuration.isPressed ? 0.985 : 1)
                .opacity(isEnabled ? 1 : 0.5)
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.14), value: isHighlighted)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

/// Formas usadas pelas superfícies com hover do app.
enum VoizSurfaceShape {
    case capsule
    case rounded(CGFloat)
}

/// Superfície "chip" com estados de hover/pressionado/desabilitado, compartilhada pelos
/// `ButtonStyle`s e pelos rótulos de `Menu` (que não aceitam `ButtonStyle`). Centralizar aqui
/// mantém o feedback visual idêntico entre botões e menus lado a lado na mesma barra de ações.
struct VoizHoverSurface<Content: View>: View {
    var isPressed = false
    var shape: VoizSurfaceShape = .capsule
    var accented = false
    var destructive = false
    /// Menus mantêm o hover mesmo com o popover aberto.
    var forceHighlight = false
    @ViewBuilder let content: Content

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    private var isHighlighted: Bool { (isHovering || forceHighlight) && isEnabled }

    var body: some View {
        content
            .foregroundColor(foreground)
            .background(fill)
            .overlay(border)
            .clipShape(clipShape)
            .contentShape(clipShape)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHighlighted)
            .animation(.easeOut(duration: 0.08), value: isPressed)
    }

    private var foreground: Color {
        if accented { return .red.opacity(0.95) }
        if destructive && isHighlighted { return .red.opacity(0.95) }
        return isHighlighted ? VoizTheme.primaryText : VoizTheme.mutedText
    }

    private var fill: Color {
        if isPressed { return VoizTheme.elevatedBackground.opacity(0.72) }
        if destructive && isHighlighted { return Color.red.opacity(0.14) }
        return isHighlighted ? VoizTheme.selectedBackground : VoizTheme.elevatedBackground
    }

    @ViewBuilder
    private var border: some View {
        let color: Color = accented || (destructive && isHighlighted)
            ? Color.red.opacity(isHighlighted ? 0.55 : 0.35)
            : (isHighlighted ? VoizTheme.borderStrong : VoizTheme.border)

        switch shape {
        case .capsule:
            Capsule().stroke(color)
        case .rounded(let radius):
            RoundedRectangle(cornerRadius: radius).stroke(color)
        }
    }

    private var clipShape: AnyShape {
        switch shape {
        case .capsule:
            return AnyShape(Capsule())
        case .rounded(let radius):
            return AnyShape(RoundedRectangle(cornerRadius: radius))
        }
    }
}

/// Conteúdo do rótulo dos `Menu` em pílula (Modelo, Exportar, Mover para pasta…).
///
/// Use sempre com `.menuStyle(.button).buttonStyle(GranolaPillButtonStyle())`: com
/// `.menuStyle(.borderlessButton)` o macOS descarta fundo e borda do label e o menu fica só com
/// o texto solto, destoando dos botões ao lado — era o que acontecia nesta barra de ações.
struct VoizMenuPillLabel: View {
    let title: String
    let systemImage: String
    var showsChevron = true

    var body: some View {
        // Ícone e chevron são decorativos: o VoiceOver lê só o título do menu.
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .accessibilityHidden(true)
            Text(title)
                .lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.6)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Pill com o modelo (e o esforço de raciocínio) que gerou o resumo da sessão. Some quando a
/// sessão não tem o carimbo — resumos gerados antes deste campo, ou sessões ainda sem resumo.
///
/// Lê de `session.summaryModel`/`summaryEffort`, nunca das configurações atuais: o ponto é
/// justamente saber com que modelo **aquela** reunião foi resumida, mesmo depois de trocar o
/// provider.
struct MeetingSummaryModelPill: View {
    let session: MeetingSession

    /// Rótulo traduzido do esforço carimbado. nil quando a sessão rodou no padrão do modelo ou
    /// quando o slug salvo não existe mais na escada — nesses casos a pill fica só com o modelo.
    private var effortName: String? {
        guard let raw = session.summaryEffort,
              let effort = AppSettings.ReasoningEffort(rawValue: raw),
              effort != .auto else { return nil }
        return effort.displayName
    }

    var body: some View {
        if let model = session.summaryModel, !model.isEmpty {
            let label = effortName.map { "\(model) · \($0)" } ?? model
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(VoizTheme.mutedText)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(VoizTheme.elevatedBackground)
            .overlay(Capsule().stroke(VoizTheme.border))
            .clipShape(Capsule())
            .help(effortName.map { Text("Resumo gerado com \(model), raciocínio \($0)") }
                  ?? Text("Resumo gerado com \(model)"))
        }
    }
}

/// "‹ Voltar" das telas de detalhe. Área de clique generosa (a versão anterior era só o texto,
/// de ~16 pt de altura) e realce no hover.
struct VoizBackButton: View {
    let title: LocalizedStringKey
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(isHovering ? VoizTheme.primaryText : VoizTheme.mutedText)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(isHovering ? VoizTheme.hoverBackground : Color.clear)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        // Compensa o padding interno para o texto alinhar com o título abaixo.
        .padding(.leading, -9)
    }
}

/// Folha de renomear reutilizada por Ditado, Tradução e Reunião.
/// Usamos um sheet (não `.alert`) porque o `TextField` dentro de `.alert` no
/// macOS não popula o valor inicial de forma confiável — além de o sheet
/// permitir um campo bem maior. Enter = Salvar, ESC = Cancelar.
struct RenameSheet: View {
    /// `LocalizedStringKey` (e não `String`): como `String`, as literais dos chamadores
    /// ("Renomear reunião", "Renomear ditado"…) escapavam da tradução.
    let title: LocalizedStringKey
    @Binding var text: String
    let onCancel: () -> Void
    let onSave: () -> Void
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(VoizTheme.primaryText)

            TextField("Título", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundColor(VoizTheme.primaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(VoizTheme.elevatedBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(fieldFocused ? VoizTheme.accent.opacity(0.6) : VoizTheme.border,
                                lineWidth: fieldFocused ? 1.5 : 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .focused($fieldFocused)
                .onSubmit(onSave)

            HStack(spacing: 10) {
                Spacer()
                Button("Cancelar", action: onCancel)
                    .buttonStyle(GranolaPillButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Salvar", action: onSave)
                    .buttonStyle(VoizPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(VoizTheme.surfaceBackground)
        .onAppear { fieldFocused = true }
    }
}

struct HomeDashboardView: View {
    @ObservedObject private var profileStore = UserProfileStore.shared
    @Environment(\.voizCompactLayout) private var compactLayout
    @EnvironmentObject var transcriptionViewModel: TranscriptionViewModel
    @EnvironmentObject var meetingViewModel: MeetingViewModel
    @EnvironmentObject var chatModel: VoizChatViewModel
    @EnvironmentObject var navigation: VoizNavigation
    @Binding var selectedTab: Int
    @State private var selectedActivity: HomeActivityItem?
    /// Lista "em acompanhamento" aberta pelo card de hoje. É uma tela de detalhe da Home, como
    /// o ditado aberto: não tem item no sidebar porque não é um gerenciador de tarefas — só o
    /// que a pessoa marcou nas reuniões para não deixar cair.
    @State private var showsTrackedActions = false
    @State private var isChatExpanded = false

    private var showsDashboard: Bool {
        selectedActivity == nil && !showsTrackedActions
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    if let selectedActivity {
                        HomeDictationDetailView(
                            entryID: selectedActivity.id,
                            onBack: { self.selectedActivity = nil }
                        )
                        .environmentObject(meetingViewModel)
                        .environmentObject(transcriptionViewModel)
                    } else if showsTrackedActions {
                        HomeTrackedActionsView(onBack: { showsTrackedActions = false })
                            .environmentObject(meetingViewModel)
                    } else {
                        VStack(alignment: .leading, spacing: 18) {
                            Text("Olá, \(profileStore.profile.displayName)")
                                .font(.system(size: 34, weight: .regular, design: .serif))
                                .foregroundColor(VoizTheme.primaryText)

                            MeetingTodayCard(onTasks: { showsTrackedActions = true })
                                .environmentObject(meetingViewModel)
                            HomeRecentList(onOpen: openActivity)
                                .environmentObject(meetingViewModel)
                                .environmentObject(transcriptionViewModel)
                        }
                        .padding(.top, 16)
                    }

                    Spacer(minLength: showsDashboard ? 220 : 40)
                }
                .frame(maxWidth: 920)
                .padding(.horizontal, compactLayout ? 24 : 56)
                .frame(maxWidth: .infinity)
            }

            if showsDashboard && isChatExpanded {
                Color.black.opacity(0.22)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.2)) {
                            isChatExpanded = false
                        }
                    }
                    .transition(.opacity)
                    .zIndex(1)
            }

            if showsDashboard {
                HomeQuickChatPanel(selectedTab: $selectedTab, isExpanded: $isChatExpanded)
                    .environmentObject(meetingViewModel)
                    .environmentObject(transcriptionViewModel)
                    .padding(.horizontal, compactLayout ? 24 : 56)
                    .padding(.bottom, 26)
                    .zIndex(2)
            }
        }
        .onAppear {
            if chatModel.homeMessages.isEmpty {
                isChatExpanded = false
            }        }
    }

    private func openActivity(_ item: HomeActivityItem) {
        switch item.kind {
        case .meeting:
            navigation.open(VoizSearchResult(
                id: item.id,
                kind: .meeting,
                title: item.title,
                snippet: item.subtitle,
                date: item.date
            ))
        case .transcription:
            selectedActivity = item
        }
    }
}

struct HomeActivityItem: Identifiable {
    enum Kind {
        case meeting
        case transcription
    }

    let id: UUID
    let kind: Kind
    let title: String
    let subtitle: String
    let detail: String
    let icon: String
    let date: Date
}

struct HomeRecentList: View {
    @EnvironmentObject var transcriptionViewModel: TranscriptionViewModel
    @EnvironmentObject var meetingViewModel: MeetingViewModel
    let onOpen: (HomeActivityItem) -> Void

    private var items: [HomeActivityItem] {
        let meetings = meetingViewModel.sessions.map { session in
            HomeActivityItem(
                id: session.id,
                kind: .meeting,
                title: session.title,
                subtitle: meetingSubtitle(for: session),
                detail: timeFormatter.string(from: session.startedAt),
                icon: session.sessionType == .interview ? "person.text.rectangle" : "doc.text",
                date: session.startedAt
            )
        }

        let transcriptions = transcriptionViewModel.historyStore.entries.map { entry in
            HomeActivityItem(
                id: entry.id,
                kind: .transcription,
                title: entry.displayTitle,
                subtitle: String(localized: "Ditado"),
                detail: timeFormatter.string(from: entry.timestamp),
                icon: "waveform",
                date: entry.timestamp
            )
        }

        return (meetings + transcriptions).sorted { $0.date > $1.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            if items.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HomeSectionTitle("Recentes")
                    HomeRecentRow(icon: "doc", title: String(localized: "Suas reuniões e ditados vão aparecer aqui"), subtitle: String(localized: "Grave ou dite algo para criar histórico"), detail: "")
                }
            } else {
                ForEach(groupedItems, id: \.label) { group in
                    VStack(alignment: .leading, spacing: 14) {
                        HomeSectionTitle(LocalizedStringKey(group.label))

                        ForEach(group.items) { item in
                            HomeRecentRow(
                                icon: item.icon,
                                title: item.title,
                                subtitle: item.subtitle,
                                detail: item.detail,
                                action: { onOpen(item) }
                            )
                        }
                    }
                }
            }
        }
    }

    private var groupedItems: [(label: String, items: [HomeActivityItem])] {
        let grouped = Dictionary(grouping: items) { dayStart(for: $0.date) }
        return grouped.keys.sorted(by: >).map { date in
            (label: sectionLabel(for: date), items: grouped[date] ?? [])
        }
    }

    private func meetingSubtitle(for session: MeetingSession) -> String {
        if let summary = session.summary, summary.hasContent {
            let actionCount = summary.actionItemCount
            if actionCount > 0 {
                return String(localized: "\(actionCount) ações")
            }
            return String(localized: "Resumo disponível")
        }

        if !session.turns.isEmpty {
            return String(localized: "\(session.turns.count) falas")
        }

        return session.sessionType.displayName
    }

    private func dayStart(for date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    private func sectionLabel(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return String(localized: "Hoje")
        }
        if Calendar.current.isDateInYesterday(date) {
            return String(localized: "Ontem")
        }

        let formatter = DateFormatter()
        formatter.locale = .voizInterface
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return formatter.string(from: date)
    }

    private var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .voizInterface
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }
}

struct HomeQuickChatPanel: View {
    @EnvironmentObject var chatModel: VoizChatViewModel
    @EnvironmentObject var transcriptionViewModel: TranscriptionViewModel
    @EnvironmentObject var meetingViewModel: MeetingViewModel
    @EnvironmentObject var navigation: VoizNavigation
    @Binding var selectedTab: Int
    @Binding var isExpanded: Bool
    @State private var prompt = ""
    @State private var pendingSend: Task<Void, Never>?
    @State private var pendingSendID: UUID?
    @FocusState private var isPromptFocused

    /// Âncora de rolagem do indicador de "pensando" — ele não é uma mensagem, então não tem id.
    fileprivate static let thinkingAnchor = "home-chat-thinking"

    private var showsExampleQuestions: Bool {
        isExpanded && VoizChatExampleQuestion.isVisible(
            prompt: prompt,
            isSending: chatModel.isSending,
            hasMessages: !chatModel.homeMessages.isEmpty
        )
    }

    private var chatContext: VoizChatContext {
        VoizChatContext(meetings: meetingViewModel, dictations: transcriptionViewModel)
    }

    private var chatCitations: MarkdownCitations {
        makeChatCitations(context: chatContext, navigation: navigation)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isExpanded && (!chatModel.homeMessages.isEmpty || chatModel.isSending) {
                homeMessagesSection
            }

            if showsExampleQuestions {
                ChatExampleQuestions(onSelect: applyExample)
            }

            if isExpanded {
                expandedComposer
            } else {
                collapsedComposer
            }
        }
        .padding(isExpanded ? 14 : 0)
        .background(panelBackground)
        .overlay(panelBorder)
        .shadow(color: panelShadowColor, radius: panelShadowRadius, x: 0, y: panelShadowY)
        .frame(maxWidth: 980)
        .animation(.easeOut(duration: 0.2), value: isExpanded)
        .animation(.easeOut(duration: 0.2), value: chatModel.homeMessages.count)
        .animation(.easeOut(duration: 0.15), value: showsExampleQuestions)
        .onDisappear { pendingSend?.cancel(); pendingSend = nil; pendingSendID = nil }
        .onChange(of: isPromptFocused) { _, focused in
            if focused {
                isExpanded = true
            }
        }
        .onChange(of: isExpanded) { _, expanded in
            if !expanded {
                isPromptFocused = false
            }
        }
    }

    private var homeMessagesSection: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(chatModel.homeMessages) { message in
                        ChatMessageBubble(message: message, citations: chatCitations)
                            .id(message.id)
                    }

                    if chatModel.isSending {
                        ChatThinkingIndicator(bubbled: true)
                            .id(Self.thinkingAnchor)
                    }

                    if let errorMessage = chatModel.errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 12))
                            .foregroundColor(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)
            .onChange(of: chatModel.homeMessages.count) {
                if let last = chatModel.homeMessages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            // O indicador entra depois da mensagem do usuário; sem isto ele nasce fora da área
            // visível justo quando é a única coisa que o usuário quer ver.
            .onChange(of: chatModel.isSending) { _, sending in
                guard sending else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(Self.thinkingAnchor, anchor: .bottom)
                }
            }
        }
        .padding(14)
        .background(VoizTheme.surfaceBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(VoizTheme.border)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        // Depois do clipShape: a prévia da citação é desenhada por fora do recorte da lista.
        .citationPreviewOverlay()
    }

    private var expandedComposer: some View {
        ChatPromptBox(
            prompt: $prompt,
            isSending: chatModel.isSending,
            isActive: isPromptFocused,
            placeholder: "Pergunte o que quiser",
            focus: $isPromptFocused,
            onSend: { sendPrompt() }
        )
    }

    private var collapsedComposer: some View {
        HStack(spacing: 12) {
            Button(action: expandComposer) {
                Text("Pergunte o que quiser")
                    .font(.system(size: 16))
                    .foregroundColor(VoizTheme.mutedText)
                    .padding(.leading, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity, minHeight: 68, maxHeight: 68, alignment: .leading)
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: isExpanded ? 22 : 999, style: .continuous)
            .fill(VoizTheme.chatPanelBackground)
    }

    private var panelBorder: some View {
        RoundedRectangle(cornerRadius: isExpanded ? 22 : 999, style: .continuous)
            .stroke(VoizTheme.border)
    }

    private var panelShadowColor: Color {
        Color.black.opacity(isExpanded ? 0.42 : 0.28)
    }

    private var panelShadowRadius: CGFloat {
        isExpanded ? 28 : 16
    }

    private var panelShadowY: CGFloat {
        isExpanded ? -8 : -4
    }

    private func openChatTab() {
        chatModel.openHomeSessionInChat()
        selectedTab = 1
    }

    private func expandComposer() {
        withAnimation(.easeOut(duration: 0.2)) {
            isExpanded = true
        }
        isPromptFocused = true
    }

    private func applyExample(_ text: String) {
        prompt = text
        isPromptFocused = true
    }

    private func sendPrompt() {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !chatModel.isSending, pendingSendID == nil else { return }
        let context = chatContext
        let token = UUID()
        pendingSendID = token
        pendingSend = Task { @MainActor in
            defer {
                if pendingSendID == token { pendingSend = nil; pendingSendID = nil }
            }
            await chatModel.sendFromHome(trimmed, context: context) {
                pendingSend = nil
                pendingSendID = nil
                withAnimation(.easeOut(duration: 0.2)) { isExpanded = true }
                if prompt.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed { prompt = "" }
            }
        }
    }
}

/// Pergunta-exemplo do composer vazio. O clique só preenche o campo — o envio continua
/// no Enter, para o usuário ainda completar com contexto.
struct VoizChatExampleQuestion: Identifiable, Hashable {
    let id: String
    let text: String

    static let all: [Self] = [
        .init(id: "pending", text: String(localized: "O que ficou pendente esta semana?")),
        .init(id: "decisions", text: String(localized: "Quais decisões saíram das últimas reuniões?")),
        .init(id: "followup", text: String(localized: "O que preciso para o próximo follow-up?")),
    ]

    /// Só no vazio: sem texto no campo, sem envio em andamento e sem conversa já começada.
    static func isVisible(prompt: String, isSending: Bool, hasMessages: Bool = false) -> Bool {
        !isSending && !hasMessages && prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Pílulas sob (ou acima) do composer. Sem ícone de "receita": são perguntas, não ações.
struct ChatExampleQuestions: View {
    let onSelect: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 8, rowSpacing: 8) {
            ForEach(VoizChatExampleQuestion.all) { example in
                Button(action: { onSelect(example.text) }) {
                    Text(example.text)
                }
                .buttonStyle(GranolaPillButtonStyle())
            }
        }
    }
}

struct HomeSectionTitle: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(VoizTheme.mutedText)
    }
}

struct HomeRecentRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let detail: String
    var action: (() -> Void)? = nil
    /// Seleção persistente usada por layouts mestre-detalhe, como a prévia de Reuniões.
    var isSelected = false
    /// Quando fornecidos, mostram um menu "..." no hover (Renomear / Apagar).
    var onRename: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    /// Conteúdo extra do menu "…", inserido entre Renomear e Apagar (ex.: "Mover para pasta").
    var extraMenu: (() -> AnyView)? = nil
    /// Notifica entrada/saída do ponteiro sem mudar a ação primária da linha.
    var onHoverChange: ((Bool) -> Void)? = nil
    @State private var isHovering = false

    private var hasMenu: Bool { onRename != nil || onDelete != nil || extraMenu != nil }

    var body: some View {
        Group {
            if let action {
                Button(action: action) {
                    rowContent
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .background(rowBackground)
                .cornerRadius(10)
                .onHover { hovering in
                    isHovering = hovering
                    onHoverChange?(hovering)
                }
            } else {
                rowContent
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
        }
    }

    private var rowBackground: Color {
        if isSelected { return VoizTheme.selectedBackground }
        return isHovering ? VoizTheme.hoverBackground : Color.clear
    }

    private var rowContent: some View {
        HStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 8)
                .fill(VoizTheme.iconBackground)
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(VoizTheme.mutedText)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(VoizTheme.primaryText)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(VoizTheme.mutedText)
                    .lineLimit(1)
            }

            Spacer()

            if isHovering && hasMenu {
                Menu {
                    if let onRename {
                        Button(action: onRename) {
                            Label("Renomear", systemImage: "pencil")
                        }
                    }
                    if let extraMenu {
                        extraMenu()
                    }
                    if let onDelete {
                        Divider()
                        Button(role: .destructive, action: onDelete) {
                            Label("Apagar", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(VoizTheme.mutedText)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            } else if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(VoizTheme.mutedText)
            }
        }
    }
}

struct HomeDictationDetailView: View {
    @EnvironmentObject var transcriptionViewModel: TranscriptionViewModel
    let entryID: UUID
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VoizBackButton(title: "Início", action: onBack)
                .padding(.top, 16)

            if let entry = transcriptionViewModel.historyStore.entries.first(where: { $0.id == entryID }) {
                HomeTranscriptionDetailContent(entry: entry, viewModel: transcriptionViewModel)
            } else {
                HomeMissingContentView(message: String(localized: "Este ditado não está mais disponível."))
            }
        }
    }
}

struct HomeDetailSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(VoizTheme.mutedText)
                .textCase(.uppercase)

            content
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
}

struct HomeDetailBulletList: View {
    let items: [String]

    var body: some View {
        let filtered = items.filter { !$0.isEmpty }
        if filtered.isEmpty {
            Text("Nenhum item.")
                .font(.system(size: 13))
                .foregroundColor(VoizTheme.mutedText)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(filtered, id: \.self) { item in
                    Text("• \(item)")
                        .font(.system(size: 14))
                        .foregroundColor(VoizTheme.primaryText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct HomeMissingContentView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 14))
            .foregroundColor(VoizTheme.mutedText)
            .padding(.vertical, 24)
    }
}

struct VoizChatView: View {
    @ObservedObject private var profileStore = UserProfileStore.shared
    @Environment(\.voizCompactLayout) private var compactLayout
    @EnvironmentObject var transcriptionViewModel: TranscriptionViewModel
    @EnvironmentObject var meetingViewModel: MeetingViewModel
    @EnvironmentObject var chatModel: VoizChatViewModel
    @EnvironmentObject var navigation: VoizNavigation
    @State private var prompt = ""
    @State private var pendingSend: Task<Void, Never>?
    @State private var pendingSendID: UUID?
    @State private var sessionToRename: ChatSession?
    @State private var renameDraft = ""
    @FocusState private var isPromptFocused

    /// Âncora de rolagem do indicador de "pensando" — ele não é uma mensagem, então não tem id.
    fileprivate static let thinkingAnchor = "chat-thinking"

    private var showsExampleQuestions: Bool {
        VoizChatExampleQuestion.isVisible(prompt: prompt, isSending: chatModel.isSending)
    }

    private var chatContext: VoizChatContext {
        VoizChatContext(meetings: meetingViewModel, dictations: transcriptionViewModel)
    }

    private var chatCitations: MarkdownCitations {
        makeChatCitations(context: chatContext, navigation: navigation)
    }

    private var isConversationMode: Bool {
        chatModel.activeSession != nil
    }

    var body: some View {
        Group {
            if isConversationMode, let session = chatModel.activeSession {
                chatConversationLayout(for: session)
            } else {
                chatLandingLayout
            }
        }
        .frame(maxWidth: 820)
        .padding(.horizontal, compactLayout ? 24 : 56)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear { pendingSend?.cancel(); pendingSend = nil; pendingSendID = nil }
        .onExitCommand {
            if isConversationMode {
                chatModel.startNewChat()
            }
        }
        .alert("Renomear conversa", isPresented: renameAlertBinding) {
            TextField("Título", text: $renameDraft)
            Button("Cancelar", role: .cancel) {
                sessionToRename = nil
            }
            Button("Salvar") {
                if let session = sessionToRename {
                    chatModel.renameSession(session, title: renameDraft)
                }
                sessionToRename = nil
            }
        }
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { sessionToRename != nil },
            set: { if !$0 { sessionToRename = nil } }
        )
    }

    private var chatLandingLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Olá, \(profileStore.profile.displayName)")
                        .font(.system(size: 31, weight: .regular, design: .serif))
                        .foregroundColor(VoizTheme.primaryText)

                    ChatPromptBox(
                        prompt: $prompt,
                        isSending: chatModel.isSending,
                        isActive: isPromptFocused,
                        focus: $isPromptFocused,
                        slashPickerEdge: .bottom,
                        onSend: sendPrompt
                    )
                    // O painel de comandos abre para baixo, sobre as perguntas de exemplo; elas
                    // são irmãs desenhadas depois e cobririam o painel (o `zIndex` do VStack só
                    // resolve contra os "Recentes").
                    .zIndex(1)

                    if showsExampleQuestions {
                        ChatExampleQuestions(onSelect: applyExample)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: showsExampleQuestions)
                // O painel de ações abre para baixo, sobre os "Recentes"; sem isto o irmão
                // desenhado depois cobriria o painel.
                .zIndex(1)

                chatRecentsSection
            }
            .padding(.top, 24)
            .padding(.bottom, 40)
        }
    }

    private func chatConversationLayout(for session: ChatSession) -> some View {
        VStack(spacing: 0) {
            chatConversationToolbar

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(session.messages) { message in
                            ConversationMessageView(message: message, citations: chatCitations)
                                .id(message.id)
                        }

                        if chatModel.isSending {
                            ChatThinkingIndicator()
                                .id(Self.thinkingAnchor)
                        }

                        if let errorMessage = chatModel.errorMessage {
                            Text(errorMessage)
                                .font(.system(size: 12))
                                .foregroundColor(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
                }
                .onAppear {
                    scrollToLatestMessage(in: session, proxy: proxy)
                }
                .onChange(of: session.messages.count) {
                    scrollToLatestMessage(in: session, proxy: proxy)
                }
                .onChange(of: chatModel.isSending) { _, sending in
                    guard sending else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(Self.thinkingAnchor, anchor: .bottom)
                    }
                }
            }
            .id(session.id)
            .citationPreviewOverlay()

            VStack(alignment: .leading, spacing: 8) {
                ChatAttachmentChips()
                ChatCompactInputBar(
                    prompt: $prompt,
                    isSending: chatModel.isSending,
                    onSend: sendPrompt
                )
            }
            .padding(.vertical, 20)
        }
    }

    private var chatConversationToolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                Button(action: { chatModel.startNewChat() }) {
                    Image(systemName: "chevron.left")
                        .frame(width: 36, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Voltar (Esc)")

                Rectangle()
                    .fill(VoizTheme.border)
                    .frame(width: 1, height: 18)

                ChatHistoryMenu(
                    groupedSessions: chatModel.groupedSessions(),
                    activeSessionId: chatModel.activeSessionId,
                    onSelect: { chatModel.selectSession($0) },
                    compact: true
                )
            }
            .foregroundColor(VoizTheme.primaryText)
            .background(VoizTheme.elevatedBackground)
            .overlay(
                Capsule()
                    .stroke(VoizTheme.border)
            )
            .clipShape(Capsule())

            Spacer()

            Button(action: { chatModel.startNewChat() }) {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(ChatToolbarIconButtonStyle())
            .help("Nova conversa")
        }
        .padding(.top, 18)
        .padding(.bottom, 8)
    }

    private var chatRecentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HomeSectionTitle("Recentes")
                Spacer()
            }

            if chatModel.sessions.isEmpty {
                ChatSessionRow(
                    session: nil,
                    placeholderTitle: String(localized: "Pergunte sobre suas notas e reuniões"),
                    placeholderDetail: String(localized: "agora")
                )
            } else {
                ForEach(chatModel.sortedSessions.prefix(8)) { session in
                    ChatSessionRow(
                        session: session,
                        onSelect: { chatModel.selectSession(session) },
                        onPin: { chatModel.togglePin(session) },
                        onRename: {
                            sessionToRename = session
                            renameDraft = session.displayTitle
                        },
                        onDelete: { chatModel.deleteSession(session) }
                    )
                }
            }
        }
    }

    private func scrollToLatestMessage(in session: ChatSession, proxy: ScrollViewProxy) {
        if let last = session.messages.last {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private func applyExample(_ text: String) {
        prompt = text
        isPromptFocused = true
    }

    private func sendPrompt() {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !chatModel.isSending, pendingSendID == nil else { return }
        let context = chatContext
        let token = UUID()
        pendingSendID = token
        pendingSend = Task { @MainActor in
            defer {
                if pendingSendID == token { pendingSend = nil; pendingSendID = nil }
            }
            await chatModel.sendFromChat(trimmed, context: context) {
                pendingSend = nil
                pendingSendID = nil
                if prompt.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed { prompt = "" }
            }
        }
    }
}

/// Liga as marcas de citação do texto do modelo ao app: resolve `[[m:1a2b3c4d]]` para a reunião
/// correspondente e, no clique, navega até ela.
///
/// A resolução é por **prefixo de UUID** — o que o prompt mandou para o modelo. Se nada casar (o
/// modelo inventou a marca, ou a reunião foi apagada depois da resposta), devolve `nil` e o chip
/// simplesmente não aparece.
@MainActor
func makeChatCitations(context: VoizChatContext, navigation: VoizNavigation) -> MarkdownCitations {
    MarkdownCitations(
        resolve: { ref in
            switch ref.kind {
            case .meeting:
                guard let session = context.meetings.first(where: {
                    ChatCitation.handle(for: $0.id) == ref.handle
                }) else { return nil }
                return MarkdownCitation(
                    id: session.id,
                    kind: .meeting,
                    title: session.title,
                    detail: session.formattedDate,
                    snippet: session.summary?.overview ?? session.notes
                )
            case .dictation:
                guard let entry = context.dictations.first(where: {
                    ChatCitation.handle(for: $0.id) == ref.handle
                }) else { return nil }
                return MarkdownCitation(
                    id: entry.id,
                    kind: .dictation,
                    title: entry.displayTitle,
                    detail: entry.formattedDate,
                    snippet: entry.text
                )
            case .translation:
                return nil
            }
        },
        open: { citation in
            let date: Date
            switch citation.kind {
            case .meeting: date = context.meeting(id: citation.id)?.startedAt ?? Date()
            case .dictation: date = context.dictation(id: citation.id)?.timestamp ?? Date()
            case .translation: date = Date()
            }
            navigation.open(
                VoizSearchResult(
                    id: citation.id,
                    kind: citation.kind,
                    title: citation.title,
                    snippet: citation.snippet,
                    date: date
                )
            )
        }
    )
}

/// Atalho para as duas telas de chat montarem o mesmo contexto. Fica aqui, e não no
/// `VoizChatContext`, para o tipo do prompt não passar a depender de view models.
extension VoizChatContext {
    init(meetings: MeetingViewModel, dictations: TranscriptionViewModel) {
        self.init(
            meetings: meetings.sessions,
            folders: meetings.folders,
            dictations: dictations.historyStore.entries
        )
    }
}

struct ChatHistoryMenu: View {
    let groupedSessions: [(label: String, sessions: [ChatSession])]
    let activeSessionId: UUID?
    let onSelect: (ChatSession) -> Void
    var compact = false

    var body: some View {
        Menu {
            if groupedSessions.isEmpty {
                Button("Nenhuma conversa") {}
                    .disabled(true)
            } else {
                ForEach(groupedSessions, id: \.label) { group in
                    Section(group.label) {
                        ForEach(group.sessions) { session in
                            Button(action: { onSelect(session) }) {
                                HStack {
                                    Text(session.displayTitle)
                                    if activeSessionId == session.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            if compact {
                Image(systemName: "bubble.left.and.bubble.right")
                    .frame(width: 36, height: 34)
                    .accessibilityLabel(Text("Histórico"))
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .accessibilityHidden(true)
                    Text("Histórico")
                        .font(.system(size: 13, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .accessibilityHidden(true)
                }
                .foregroundColor(VoizTheme.primaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(VoizTheme.elevatedBackground)
                .overlay(
                    Capsule()
                        .stroke(VoizTheme.border)
                )
                .clipShape(Capsule())
            }
        }
        .menuStyle(.borderlessButton)
    }
}

struct ChatToolbarIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(VoizTheme.primaryText)
            .frame(width: 34, height: 34)
            .background(VoizTheme.elevatedBackground.opacity(configuration.isPressed ? 0.72 : 1))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(VoizTheme.border)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct ChatCompactInputBar: View {
    @Binding var prompt: String
    let isSending: Bool
    let onSend: () -> Void

    @FocusState private var fieldFocused: Bool
    @State private var commandsRequested = false

    var body: some View {
        HStack(spacing: 12) {
            TextField("Pergunte o que quiser", text: $prompt)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundColor(VoizTheme.primaryText)
                .focused($fieldFocused)
                .disabled(isSending)

            HStack(spacing: 10) {
                ChatCommandsButton(isActive: commandsRequested, showsLabel: false) {
                    commandsRequested.toggle()
                    fieldFocused = true
                }

                ChatModelMenu()

                ChatAttachMenu()
                    .font(.system(size: 12))

                Button(action: onSend) {
                    if isSending {
                        ChatSendSpinner()
                    } else {
                        Image(systemName: "arrow.up")
                    }
                }
                .buttonStyle(ChatSendButtonStyle())
                .help("Enviar")
                .accessibilityLabel("Enviar")
                .disabled(isSending || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(VoizTheme.chatPanelBackground)
        .overlay(
            Capsule()
                .stroke(VoizTheme.border)
        )
        .clipShape(Capsule())
        // A barra fica no rodapé da conversa: o painel de ações abre para cima, por fora da cápsula.
        .chatSlashCommandPicker(
            prompt: $prompt,
            requested: $commandsRequested,
            edge: .top,
            onSend: onSend
        )
    }
}

/// Spinner que ocupa o lugar do ícone no botão de enviar enquanto a resposta não volta. Trocou a
/// ampulheta estática de antes: parado, o ícone não distingue "esperando" de "travado".
struct ChatSendSpinner: View {
    var body: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .controlSize(.small)
            .scaleEffect(0.7)
            .frame(width: 14, height: 14)
    }
}

struct ChatSendButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(VoizTheme.primaryText)
            .frame(width: 32, height: 32)
            .background(VoizTheme.iconBackground.opacity(configuration.isPressed ? 0.72 : 1))
            .clipShape(Circle())
    }
}

struct ConversationMessageView: View {
    let message: ChatMessage
    var citations: MarkdownCitations?

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 80)
                Text(message.content)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(VoizTheme.primaryText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(VoizTheme.elevatedBackground)
                    .overlay(
                        Capsule()
                            .stroke(VoizTheme.border)
                    )
                    .clipShape(Capsule())
            }
        } else {
            MarkdownText(
                markdown: message.content,
                font: .system(size: 15),
                color: VoizTheme.primaryText,
                lineSpacing: 5,
                citations: citations
            )
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ChatSessionRow: View {
    let session: ChatSession?
    var placeholderTitle: String?
    var placeholderDetail: String?
    var onSelect: (() -> Void)?
    var onPin: (() -> Void)?
    var onRename: (() -> Void)?
    var onDelete: (() -> Void)?
    @State private var isHovering = false

    var body: some View {
        Group {
            if let onSelect {
                Button(action: onSelect) {
                    rowContent
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            } else {
                rowContent
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
            }
        }
        .background(isHovering && onSelect != nil ? VoizTheme.hoverBackground : Color.clear)
        .cornerRadius(10)
        .onHover { isHovering = $0 }
    }

    private var rowContent: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 8)
                .fill(VoizTheme.iconBackground)
                .frame(width: 34, height: 34)
                .overlay(
                    Image(systemName: session?.isPinned == true ? "pin.fill" : "bubble.left")
                        .font(.system(size: 13))
                        .foregroundColor(VoizTheme.mutedText)
                )

            Text(session?.displayTitle ?? placeholderTitle ?? "")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(VoizTheme.primaryText)
                .lineLimit(1)

            Spacer()

            if isHovering, let session, onPin != nil {
                Menu {
                    Button(action: { onPin?() }) {
                        Label(session.isPinned ? "Desafixar" : "Fixar", systemImage: "pin")
                    }
                    Button(action: { onRename?() }) {
                        Label("Renomear", systemImage: "pencil")
                    }
                    Divider()
                    Button(role: .destructive, action: { onDelete?() }) {
                        Label("Apagar", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(VoizTheme.mutedText)
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
            } else {
                Text(session?.relativeDate ?? placeholderDetail ?? "")
                    .font(.system(size: 12))
                    .foregroundColor(VoizTheme.mutedText)
            }
        }
    }
}

struct ChatPromptBox: View {
    @Binding var prompt: String
    let isSending: Bool
    var isActive = false
    var placeholder: LocalizedStringKey = "Quais são minhas pendências?"
    /// Optional external focus binding (used by the Home composer). When nil, the
    /// box manages its own focus internally.
    var focus: FocusState<Bool>.Binding? = nil
    /// Lado em que o seletor de comandos ("/") abre. A Home fica no rodapé e abre para cima;
    /// a abertura do Chat fica no topo da página e abre para baixo.
    var slashPickerEdge: VerticalEdge = .top
    let onSend: () -> Void

    @FocusState private var internalFocus: Bool
    @State private var commandsRequested = false

    private var fieldFocus: FocusState<Bool>.Binding {
        focus ?? $internalFocus
    }

    private var isHighlighted: Bool {
        isActive || fieldFocus.wrappedValue
    }

    var body: some View {
        VStack(spacing: 18) {
            ChatAttachmentChips()

            TextField(placeholder, text: $prompt)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundColor(VoizTheme.primaryText)
                .frame(minHeight: 52, alignment: .topLeading)
                .focused(fieldFocus)
                .disabled(isSending)

            HStack {
                ChatAttachMenu()

                ChatModelMenu()

                ChatCommandsButton(isActive: commandsRequested) {
                    commandsRequested.toggle()
                    fieldFocus.wrappedValue = true
                }

                Spacer()

                Button(action: onSend) {
                    if isSending {
                        ChatSendSpinner()
                    } else {
                        Image(systemName: "arrow.up")
                    }
                }
                .buttonStyle(GranolaIconButtonStyle())
                .help("Enviar")
                .accessibilityLabel("Enviar")
                .disabled(isSending || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 20)
        .background(VoizTheme.elevatedBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(isHighlighted ? VoizTheme.accent.opacity(0.55) : VoizTheme.border, lineWidth: isHighlighted ? 1.5 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .contentShape(RoundedRectangle(cornerRadius: 24))
        .onTapGesture {
            if !isSending {
                fieldFocus.wrappedValue = true
            }
        }
        // Depois do clipShape: o painel de ações precisa sair da caixa do composer.
        .chatSlashCommandPicker(
            prompt: $prompt,
            requested: $commandsRequested,
            edge: slashPickerEdge,
            onSend: onSend
        )
    }
}

/// O clipe: pendura uma reunião, uma pasta ou um ditado na conversa.
///
/// Não abre um seletor de arquivo de propósito. O que o modelo não tem hoje não é PDF — é o
/// **conteúdo inteiro** do que já está no app: o índice manda 100 caracteres por reunião, e é
/// aqui que se pede os 45.000 de uma específica.
struct ChatAttachMenu: View {
    @EnvironmentObject var chatModel: VoizChatViewModel
    @EnvironmentObject var meetingViewModel: MeetingViewModel
    @EnvironmentObject var transcriptionViewModel: TranscriptionViewModel

    /// Teto das listas do menu. Um menu com 45 itens já é desconfortável; o que ficar de fora
    /// continua alcançável pela pasta.
    private let listLimit = 25

    var body: some View {
        Menu {
            let meetings = meetingViewModel.sessions
                .sorted { $0.startedAt > $1.startedAt }
                .prefix(listLimit)
            if !meetings.isEmpty {
                Menu("Reuniões") {
                    ForEach(Array(meetings)) { session in
                        Button("\(session.formattedDate) · \(session.title)") {
                            chatModel.attach(ChatAttachment(id: session.id, kind: .meeting, title: session.title))
                        }
                    }
                }
            }

            if !meetingViewModel.folders.isEmpty {
                Menu("Pastas") {
                    ForEach(meetingViewModel.folders) { folder in
                        Button(folder.name) {
                            chatModel.attach(ChatAttachment(id: folder.id, kind: .folder, title: folder.name))
                        }
                    }
                }
            }

            let dictations = transcriptionViewModel.historyStore.entries
                .sorted { $0.timestamp > $1.timestamp }
                .prefix(listLimit)
            if !dictations.isEmpty {
                Menu("Ditados") {
                    ForEach(Array(dictations)) { entry in
                        Button("\(entry.formattedDate) · \(entry.displayTitle)") {
                            chatModel.attach(ChatAttachment(id: entry.id, kind: .dictation, title: entry.displayTitle))
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "paperclip")
                .foregroundColor(VoizTheme.mutedText)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("Anexar uma reunião, pasta ou ditado à conversa"))
    }
}

/// Os anexos pendurados na conversa, acima do campo de texto. Cada um mostra o que é e sai com um
/// clique — o usuário precisa ver o que está indo junto com a pergunta antes de mandar.
struct ChatAttachmentChips: View {
    @EnvironmentObject var chatModel: VoizChatViewModel

    var body: some View {
        if !chatModel.attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(chatModel.attachments) { attachment in
                        HStack(spacing: 6) {
                            Image(systemName: attachment.kind.systemImage)
                                .font(.system(size: 10, weight: .semibold))
                            Text(attachment.title)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            Button {
                                chatModel.removeAttachment(attachment)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .buttonStyle(.plain)
                        }
                        .foregroundColor(VoizTheme.mutedText)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(VoizTheme.elevatedBackground)
                        .overlay(Capsule().stroke(VoizTheme.border))
                        .clipShape(Capsule())
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Seletor de modelo do Chat e da Home: lista **todos** os provedores com chave configurada,
/// agrupados, e troca o modelo só destas telas — as Configurações não são tocadas.
///
/// Antes ele mostrava apenas os modelos do provider ativo e gravava a escolha no `AppSettings`,
/// então experimentar outro provider no chat significava mudar a configuração geral do app (e
/// junto com ela o modelo das reuniões e da tradução) e depois lembrar de desfazer.
struct ChatModelMenu: View {
    @EnvironmentObject var chatModel: VoizChatViewModel

    var body: some View {
        let groups = chatModel.modelMenuGroups()
        let active = chatModel.activeChoice

        Menu {
            if groups.isEmpty {
                Text("Adicione uma chave de API em Configurações.")
            }

            ForEach(groups, id: \.provider) { group in
                Section(group.provider.displayName) {
                    ForEach(group.models, id: \.self) { choice in
                        Button(action: { chatModel.select(choice) }) {
                            HStack {
                                Text(chatModel.label(for: choice))
                                if choice == active {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }

            // Só aparece quando há o que desfazer — sem escolha própria, a tela já segue as
            // Configurações e o item não faria nada.
            if chatModel.modelChoice != nil {
                Divider()
                Button("Voltar ao modelo das Configurações") { chatModel.select(nil) }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: Self.symbol(for: active.provider))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(VoizTheme.mutedText)
                    .accessibilityHidden(true)
                Text(chatModel.currentModelLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(VoizTheme.mutedText)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(VoizTheme.mutedText)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("Modelo do Chat. Não altera as Configurações."))
    }

    /// Glifo por provider, para distinguir de onde vem o modelo sem ler o nome inteiro.
    private static func symbol(for provider: AppSettings.TranslationProvider) -> String {
        switch provider {
        case .openai: return "circle.hexagongrid"
        case .anthropic: return "sparkle"
        case .xai: return "x.circle"
        case .gemini: return "diamond"
        case .custom: return "server.rack"
        }
    }
}

@MainActor
final class VoizChatViewModel: ObservableObject {
    private let meetingWorkspace = MeetingWorkspaceStore.shared
    @Published private(set) var sessions: [ChatSession] = []
    @Published var homeMessages: [ChatMessage] = []
    @Published var activeSessionId: UUID?
    @Published var isSending = false
    @Published var errorMessage: String?

    private var homeSessionId: UUID?
    private var conversationRevision = 0
    private let settingsStore = SettingsStore()
    private let aiService = AICompletionService()
    private let historyStore = ChatHistoryStore()
    private var libraryObserver: NSObjectProtocol?

    /// Modelo escolhido no seletor do Chat/Home. nil = segue as Configurações.
    ///
    /// Mora aqui, e não em `AppSettings`, porque é uma preferência destas duas telas: trocar de
    /// modelo no meio de uma conversa não deve mudar com o que as reuniões vão ser resumidas nem
    /// o que a Tradução usa.
    @Published private(set) var modelChoice: AppSettings.ModelChoice?

    init() {
        sessions = historyStore.load()
        modelChoice = historyStore.loadModelChoice()
        libraryObserver = NotificationCenter.default.addObserver(forName: .voizSyncRemoteApplied, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isSending else { return }
                self.sessions = self.historyStore.load()
            }
        }
    }
    deinit { if let libraryObserver { NotificationCenter.default.removeObserver(libraryObserver) } }

    /// Grava o histórico inteiro. Chamado a cada mutação em `sessions` — o arquivo é pequeno
    /// (texto) e a escrita é atômica, então vale a simplicidade de não ter estado sujo pendente:
    /// um crash ou um rebuild no meio da conversa não perde o que já foi respondido.
    @discardableResult
    private func persist() -> Bool {
        if !historyStore.save(sessions) {
            errorMessage = String(localized: "Não foi possível salvar a conversa. O conteúdo permanece disponível nesta janela.")
            return false
        }
        return true
    }

    var activeSession: ChatSession? {
        guard let activeSessionId else { return nil }
        return sessions.first { $0.id == activeSessionId }
    }

    /// O modelo que a próxima mensagem vai usar: o escolhido no seletor, ou o das Configurações
    /// quando não há escolha (ou quando a chave dela sumiu).
    var activeChoice: AppSettings.ModelChoice {
        settingsStore.load().resolvedChoice(modelChoice)
    }

    var currentModelLabel: String {
        let settings = settingsStore.load()
        return settings.displayName(for: settings.resolvedChoice(modelChoice))
    }

    var currentModelId: String {
        activeChoice.modelId
    }

    /// Modelos oferecidos no seletor, agrupados por provider — só os provedores com credencial
    /// configurada. Lista vazia = nenhuma API configurada ainda.
    func modelMenuGroups() -> [(provider: AppSettings.TranslationProvider, models: [AppSettings.ModelChoice])] {
        let settings = settingsStore.load()
        return settings.configuredProviders.compactMap { provider in
            let models = settings.models(for: provider)
            return models.isEmpty ? nil : (provider: provider, models: models)
        }
    }

    func label(for choice: AppSettings.ModelChoice) -> String {
        settingsStore.load().displayName(for: choice)
    }

    /// Troca o modelo **destas telas**. `nil` volta a seguir as Configurações.
    ///
    /// Não grava em `AppSettings` de propósito: era esse o incômodo — para experimentar outro
    /// modelo no chat era preciso mudar a configuração geral do app e depois desfazer.
    func select(_ choice: AppSettings.ModelChoice?) {
        modelChoice = choice
        historyStore.saveModelChoice(choice)
    }

    var sortedSessions: [ChatSession] {
        sessions.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned && !rhs.isPinned
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    func groupedSessions() -> [(label: String, sessions: [ChatSession])] {
        let sorted = sortedSessions
        let grouped = Dictionary(grouping: sorted) { session -> String in
            if Calendar.current.isDateInToday(session.updatedAt) {
                return String(localized: "Hoje")
            }
            if Calendar.current.isDateInYesterday(session.updatedAt) {
                return String(localized: "Ontem")
            }
            let days = Calendar.current.dateComponents([.day], from: session.updatedAt, to: Date()).day ?? 0
            if days <= 21 {
                return String(localized: "Últimas semanas")
            }
            return String(localized: "Anteriores")
        }

        let order = [String(localized: "Hoje"), String(localized: "Ontem"),
                     String(localized: "Últimas semanas"), String(localized: "Anteriores")]
        return order.compactMap { label in
            guard let items = grouped[label], !items.isEmpty else { return nil }
            return (label: label, sessions: items)
        }
    }

    func resetHomeChat() {
        conversationRevision += 1
        homeMessages = []
        homeSessionId = nil
        errorMessage = nil
        attachments = []
    }

    func startNewChat() {
        conversationRevision += 1
        activeSessionId = nil
        errorMessage = nil
        attachments = []
    }

    func selectSession(_ session: ChatSession) {
        conversationRevision += 1
        activeSessionId = session.id
        errorMessage = nil
    }

    func deleteSession(_ session: ChatSession) {
        VoizEditingGate.shared.submit { [self] in
            conversationRevision += 1
            sessions.removeAll { $0.id == session.id }
            if activeSessionId == session.id {
                activeSessionId = nil
            }
            if homeSessionId == session.id {
                homeSessionId = nil
            }
            persist()
        }
    }

    func togglePin(_ session: ChatSession) {
        VoizEditingGate.shared.submit { [self] in
            guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
            sessions[index].isPinned.toggle()
            persist()
        }
    }

    func renameSession(_ session: ChatSession, title: String) {
        VoizEditingGate.shared.submit { [self] in
            guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
            sessions[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            persist()
        }
    }

    func openHomeSessionInChat() {
        conversationRevision += 1
        if let homeSessionId,
           sessions.contains(where: { $0.id == homeSessionId }) {
            activeSessionId = homeSessionId
        } else if let latest = sessions.first {
            activeSessionId = latest.id
        }
        errorMessage = nil
    }

    func sendFromHome(_ userPrompt: String, context: VoizChatContext, onAdmitted: @MainActor () -> Void = {}) async {
        await send(userPrompt: userPrompt, target: .home, context: context, onAdmitted: onAdmitted)
    }

    func sendFromChat(_ userPrompt: String, context: VoizChatContext, onAdmitted: @MainActor () -> Void = {}) async {
        await send(userPrompt: userPrompt, target: .chat, context: context, onAdmitted: onAdmitted)
    }

    // MARK: - Anexos

    /// Itens do app pendurados na conversa atual. Duram a conversa inteira, não só uma mensagem:
    /// o follow-up ("e essa outra?") precisa do mesmo material na mão.
    @Published private(set) var attachments: [ChatAttachment] = []

    func attach(_ attachment: ChatAttachment) {
        guard !attachments.contains(where: { $0.id == attachment.id && $0.kind == attachment.kind }) else { return }
        attachments.append(attachment)
    }

    func removeAttachment(_ attachment: ChatAttachment) {
        attachments.removeAll { $0.id == attachment.id && $0.kind == attachment.kind }
    }

    private enum SendTarget {
        case home
        case chat
    }

    private func send(
        userPrompt: String,
        target: SendTarget,
        context: VoizChatContext,
        onAdmitted: @MainActor () -> Void
    ) async {
        guard !isSending, !userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let originalHomeSessionID = homeSessionId
        let originalActiveSessionID = activeSessionId
        let originalRevision = conversationRevision
        let submittedAttachments = attachments
        isSending = true
        defer { isSending = false }
        guard await VoizAccessStore.shared.authorizeNewOperation(kind: .ai) else {
            if !Task.isCancelled {
                errorMessage = VoizAccessStore.shared.lastError ?? VoizAccessMessages.libraryUnavailable
            }
            return
        }
        guard !Task.isCancelled, conversationRevision == originalRevision else { return }
        let workActivity = VoizWorkTracker.shared.beginActivity()
        defer { workActivity.finish() }
        let settings: AppSettings
        do {
            settings = try await settingsStore.settingsForAIUse()
        } catch {
            if !Task.isCancelled, conversationRevision == originalRevision {
                errorMessage = error.localizedDescription
            }
            return
        }
        guard !Task.isCancelled, conversationRevision == originalRevision else { return }
        switch target {
        case .home: guard homeSessionId == originalHomeSessionID else { return }
        case .chat: guard activeSessionId == originalActiveSessionID else { return }
        }
        onAdmitted()
        let existing: [ChatMessage]
        switch target {
        case .home: existing = homeMessages
        case .chat: existing = activeSession?.messages ?? []
        }
        // An unanswered visible user turn is the durable identity of a retry.
        let retry = existing.last.flatMap { $0.role == .user && $0.content == userPrompt ? $0 : nil }
        let userMessage = retry ?? ChatMessage(role: .user, content: userPrompt)
        let priorHistory = retry == nil ? existing : Array(existing.dropLast())
        let targetSessionID: UUID?
        switch target {
        case .home:
            ensureHomeSession(seedTitle: userPrompt)
            targetSessionID = homeSessionId
            if retry == nil { homeMessages.append(userMessage) }
        case .chat:
            ensureActiveSession(seedTitle: userPrompt)
            targetSessionID = activeSessionId
        }
        guard let targetSessionID, appendMessage(userMessage, to: targetSessionID) else { return }

        errorMessage = nil

        aiService.apply(settings, choice: modelChoice)

        do {
            let answer = try await aiService.complete(
                messages: buildMessages(
                    userPrompt: MeetingAIRecipe.expanded(userPrompt, recipes: meetingWorkspace.recipes),
                    history: priorHistory,
                    context: context,
                    attachments: submittedAttachments
                ),
                temperature: 0.4
            )
            let assistantMessage = ChatMessage(role: .assistant, content: answer)

            if case .home = target, homeSessionId == targetSessionID,
               !homeMessages.contains(where: { $0.id == assistantMessage.id }) { homeMessages.append(assistantMessage) }
            guard appendMessage(assistantMessage, to: targetSessionID) else { return }
        } catch {
            errorMessage = error.localizedDescription
        }

    }

    private func ensureHomeSession(seedTitle: String) {
        if homeSessionId == nil {
            let session = makeSession(seedTitle: seedTitle)
            homeSessionId = session.id
            sessions.insert(session, at: 0)
        }
    }

    private func ensureActiveSession(seedTitle: String) {
        if activeSessionId == nil {
            let session = makeSession(seedTitle: seedTitle)
            activeSessionId = session.id
            sessions.insert(session, at: 0)
        }
    }

    private func makeSession(seedTitle: String) -> ChatSession {
        ChatSession(
            id: UUID(),
            title: String(seedTitle.prefix(72)),
            messages: [],
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    @discardableResult
    private func appendMessage(_ message: ChatMessage, to sessionId: UUID) -> Bool {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return false }
        if let existing = sessions[index].messages.firstIndex(where: { $0.id == message.id }) {
            sessions[index].messages[existing] = message
        } else { sessions[index].messages.append(message) }
        sessions[index].updatedAt = Date()

        if sessions[index].title.isEmpty,
           message.role == .user {
            sessions[index].title = String(message.content.prefix(72))
        }

        let updated = sessions.remove(at: index)
        sessions.insert(updated, at: 0)
        return persist()
    }

    private func buildMessages(
        userPrompt: String,
        history: [ChatMessage],
        context: VoizChatContext,
        attachments: [ChatAttachment]
    ) -> [AICompletionService.ChatTurn] {
        var turns: [AICompletionService.ChatTurn] = [
            AICompletionService.ChatTurn(
                role: "system",
                content: VoizChatPromptBuilder.systemPrompt(
                    context: context,
                    attachments: attachments,
                    answerLanguage: Self.answerLanguage
                )
            )
        ]

        // Carry recent conversation so follow-ups ("uma legal", "e essa?") keep context.
        for message in history.suffix(12) {
            turns.append(
                AICompletionService.ChatTurn(
                    role: message.role == .user ? "user" : "assistant",
                    content: message.content
                )
            )
        }

        turns.append(AICompletionService.ChatTurn(role: "user", content: userPrompt))
        return turns
    }

    /// Idioma pedido ao modelo, escrito no próprio idioma para o prompt ficar coerente. Antes era
    /// "português" fixo: com a interface em inglês, os atalhos apareciam em inglês e a resposta
    /// voltava em português.
    private static var answerLanguage: String {
        String(localized: "português")
    }
}

struct ChatMessageBubble: View {
    let message: ChatMessage
    var citations: MarkdownCitations?

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user {
                Spacer(minLength: 80)
            }

            bubbleContent
                .padding(12)
                .background(message.role == .user ? VoizTheme.accent.opacity(0.18) : VoizTheme.assistantBubbleBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(VoizTheme.border)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14))

            if message.role == .assistant {
                Spacer(minLength: 80)
            }
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        if message.role == .assistant {
            MarkdownText(
                markdown: message.content,
                font: .system(size: 14),
                color: VoizTheme.primaryText,
                lineSpacing: 4,
                citations: citations
            )
            .textSelection(.enabled)
        } else {
            Text(message.content)
                .font(.system(size: 14))
                .foregroundColor(VoizTheme.primaryText)
                .textSelection(.enabled)
        }
    }
}

/// "Mandei, e agora estou esperando": três pontos pulsando no lugar exato onde a resposta vai
/// nascer, com o rótulo "Pensando…" ao lado.
///
/// Fica no fluxo das mensagens, e não só no botão de enviar, porque é lá que o olho está depois
/// do Enter — e porque o LLM pode levar dezenas de segundos com raciocínio alto, tempo suficiente
/// para a tela parada parecer travada.
struct ChatThinkingIndicator: View {
    /// Desenha o balão do assistente em volta. Na Home as respostas são balões; na conversa do
    /// Chat elas são texto solto, e lá o indicador também fica sem moldura.
    var bubbled = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        content
            .padding(.horizontal, bubbled ? 12 : 0)
            .padding(.vertical, bubbled ? 10 : 0)
            .background(bubbled ? VoizTheme.assistantBubbleBackground : Color.clear)
            .overlay(
                bubbled
                    ? RoundedRectangle(cornerRadius: 14).stroke(VoizTheme.border)
                    : nil
            )
            .clipShape(RoundedRectangle(cornerRadius: bubbled ? 14 : 0))
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { isPulsing = true }
            .accessibilityLabel(Text("Pensando…"))
    }

    private var content: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(VoizTheme.mutedText)
                        .frame(width: 6, height: 6)
                        .opacity(dimmed(index) ? 0.3 : 1)
                        .scaleEffect(dimmed(index) ? 0.7 : 1)
                        .animation(pulse(delay: Double(index) * 0.16), value: isPulsing)
                }
            }

            Text("Pensando…")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(VoizTheme.mutedText)
        }
    }

    /// Com "reduzir movimento" ligado os pontos ficam parados e apagados — o rótulo já entrega o
    /// estado sem a animação.
    private func dimmed(_ index: Int) -> Bool {
        reduceMotion ? true : !isPulsing
    }

    private func pulse(delay: TimeInterval) -> Animation? {
        guard !reduceMotion else { return nil }
        return .easeInOut(duration: 0.5).repeatForever(autoreverses: true).delay(delay)
    }
}

struct ChatRecentDisplayRow: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let detail: String
}

struct ChatRecentRow: View {
    let icon: String
    let title: String
    let detail: String
    var isSelected = false
    var action: (() -> Void)? = nil
    @State private var isHovering = false

    var body: some View {
        Group {
            if let action {
                Button(action: action) {
                    rowContent
                }
                .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(backgroundColor)
        .cornerRadius(10)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { isHovering = $0 }
    }

    private var backgroundColor: Color {
        if isSelected {
            return VoizTheme.selectedBackground
        }
        if isHovering && action != nil {
            return VoizTheme.hoverBackground
        }
        return Color.clear
    }

    private var rowContent: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 8)
                .fill(VoizTheme.iconBackground)
                .frame(width: 34, height: 34)
                .overlay(
                    Image(systemName: icon)
                        .foregroundColor(VoizTheme.mutedText)
                )

            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(VoizTheme.primaryText)
                .lineLimit(1)

            Spacer()

            Text(detail)
                .font(.system(size: 12))
                .foregroundColor(VoizTheme.mutedText)
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, proposalWidth: proposal.width ?? 600)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(CGFloat.zero) { $0 + $1.height } + rowSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(for: subviews, proposalWidth: bounds.width)
        var y = bounds.minY

        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + rowSpacing
        }
    }

    private func rows(for subviews: Subviews, proposalWidth: CGFloat) -> [FlowRow] {
        var rows: [FlowRow] = []
        var current = FlowRow()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let proposedWidth = current.width == 0 ? size.width : current.width + spacing + size.width

            if proposedWidth > proposalWidth && !current.indices.isEmpty {
                rows.append(current)
                current = FlowRow()
            }

            current.indices.append(index)
            current.width = current.width == 0 ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
        }

        if !current.indices.isEmpty {
            rows.append(current)
        }

        return rows
    }

    private struct FlowRow {
        var indices: [Subviews.Index] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }
}

/*
struct LegacyTabbedContentView: View {
    @EnvironmentObject var viewModel: TranscriptionViewModel
    @ObservedObject var translationViewModel: TranslationViewModel
    @ObservedObject var meetingViewModel: MeetingViewModel
    @Binding var selectedTab: Int

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(selectedTab: $selectedTab)

            TabView(selection: $selectedTab) {
                TranscriptionTab()
                    .tag(0)
                
                TranslationView()
                    .environmentObject(translationViewModel)
                    .tag(1)

                MeetingView()
                    .environmentObject(meetingViewModel)
                    .tag(2)
                
                TranscriptionHistoryView(historyStore: viewModel.historyStore)
                    .tag(3)
            }
            .tabViewStyle(.automatic)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
*/

struct TranscriptionTab: View {
    @EnvironmentObject var viewModel: TranscriptionViewModel
    @EnvironmentObject var navigation: VoizNavigation
    @State private var showDebugConsole = false
    @State private var expandedRecentID: UUID?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 26) {
                    DictationFlowHeader()

                    // Without activity or Dev diagnostics there is nothing to show, so no empty row.
                    if viewModel.state != .idle || AppEnvironment.current.isDevelopment {
                    HStack {
                        if viewModel.state != .idle { StatusBarView() } else { Spacer() }

                        // Diagnostics stay in Dev builds; the shipped app never shows raw logs.
                        if AppEnvironment.current.isDevelopment {
                            Button(action: { showDebugConsole.toggle() }) {
                                Image(systemName: showDebugConsole ? "terminal.fill" : "terminal")
                                    .font(.caption)
                                    .foregroundColor(VoizTheme.mutedText)
                            }
                            .buttonStyle(.plain)
                            .help(showDebugConsole ? "Ocultar Console" : "Mostrar Console")
                            .accessibilityLabel(showDebugConsole ? Text("Ocultar Console") : Text("Mostrar Console"))
                        }
                    }
                    }

                    if showDebugConsole && AppEnvironment.current.isDevelopment {
                        TranscriptionDebugConsole()
                    }

                    DictationRecentsSection(store: viewModel.historyStore, expandedID: $expandedRecentID)

                    Spacer(minLength: 20)
                }
                .frame(maxWidth: 760)
                .padding(.top, 24)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity)
            }
            // Resultado escolhido na busca global (⌘K): expande o ditado e rola até ele.
            .onAppear { consumePendingOpen(proxy) }
            .onChange(of: navigation.pendingOpen, initial: false) { _, _ in consumePendingOpen(proxy) }
        }
    }

    private func consumePendingOpen(_ proxy: ScrollViewProxy) {
        guard let id = navigation.pending(.dictation) else { return }
        guard viewModel.historyStore.revealEntry(id: id) else { navigation.clear(); return }
        expandedRecentID = id
        navigation.clear()
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }
}

/// O ditado acontece pelo atalho global, como no Wispr Flow. Idioma, engine e atalhos ficam nas
/// Configurações; esta tela serve para orientar rapidamente e consultar o histórico.
struct DictationFlowHeader: View {
    @EnvironmentObject var viewModel: TranscriptionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if viewModel.settings.dictationHotkeysEnabled {
                    Text("Segure para ditar")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(VoizTheme.primaryText)
                    Text(verbatim: viewModel.settings.pushToTalkShortcut.displayString)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(VoizTheme.accentGradient)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Color.white.opacity(0.16))
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                } else {
                    Text("Atalhos de ditado desativados")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(VoizTheme.primaryText)
                    Button("Ativar") { viewModel.settings.dictationHotkeysEnabled = true }
                        .buttonStyle(GranolaPillButtonStyle())
                }
                Spacer(minLength: 0)
            }
            if viewModel.settings.dictationHotkeysEnabled {
                Text("Solte para colar o texto em qualquer app.")
                    .font(.system(size: 13))
                    .foregroundColor(VoizTheme.mutedText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

struct DictationRecentsSection: View {
    @ObservedObject var store: TranscriptionHistoryStore
    /// Vive na aba para a busca global poder expandir um ditado específico.
    @Binding var expandedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let error = store.storageError { Text(error).font(.caption).foregroundStyle(.orange) }
            if store.entries.isEmpty {
                HomeSectionTitle("Recentes")
                HomeRecentRow(
                    icon: "waveform",
                    title: String(localized: "Seus ditados vão aparecer aqui"),
                    subtitle: String(localized: "Dite algo para criar histórico"),
                    detail: ""
                )
            } else {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(groupedEntries, id: \.day) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(dayLabel(group.day))
                                .font(.system(size: 11, weight: .semibold))
                                .tracking(0.8)
                                .foregroundColor(VoizTheme.mutedText)
                                .textCase(.uppercase)

                            VStack(spacing: 0) {
                                ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                                    DictationRecentRow(
                                        entry: entry,
                                        isExpanded: expandedID == entry.id,
                                        onToggle: {
                                            withAnimation(.easeInOut(duration: 0.15)) {
                                                expandedID = expandedID == entry.id ? nil : entry.id
                                            }
                                        },
                                        onCopy: { copyToClipboard(entry.text) },
                                        onDelete: { VoizEditingGate.shared.submit { store.deleteEntry(entry) } }
                                    )
                                    .id(entry.id)

                                    if index < group.entries.count - 1 {
                                        Divider()
                                            .padding(.leading, 82)
                                    }
                                }
                            }
                            .background(VoizTheme.surfaceBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(VoizTheme.border)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                    if store.hasMoreEntries {
                        Button("Carregar mais") { store.loadMore() }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var groupedEntries: [(day: Date, entries: [TranscriptionEntry])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: store.entries) {
            calendar.startOfDay(for: $0.timestamp)
        }
        return groups.keys.sorted(by: >).map { day in
            (day: day, entries: (groups[day] ?? []).sorted { $0.timestamp > $1.timestamp })
        }
    }

    private func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "Hoje") }
        if calendar.isDateInYesterday(day) { return String(localized: "Ontem") }

        let formatter = DateFormatter()
        formatter.locale = .voizInterface
        formatter.setLocalizedDateFormatFromTemplate("d MMMM yyyy")
        return formatter.string(from: day)
    }
}

struct DictationRecentRow: View {
    let entry: TranscriptionEntry
    let isExpanded: Bool
    let onToggle: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void
    @State private var isHovering = false
    @State private var didCopy = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Text(timeLabel)
                .font(.system(size: 12).monospacedDigit())
                .foregroundColor(VoizTheme.mutedText)
                .frame(width: 54, alignment: .leading)
                .help("\(entry.formattedDate) • \(entry.language.displayName)")

            Text(displayText.isEmpty ? String(localized: "Nenhum texto reconhecido.") : displayText)
                .font(.system(size: 14))
                .foregroundColor(displayText.isEmpty ? VoizTheme.mutedText : VoizTheme.primaryText)
                .lineSpacing(3)
                .lineLimit(isExpanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                Button {
                    onCopy()
                    withAnimation(.easeOut(duration: 0.15)) { didCopy = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        withAnimation(.easeOut(duration: 0.2)) { didCopy = false }
                    }
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: didCopy ? .bold : .regular))
                        .foregroundColor(didCopy ? .green : VoizTheme.mutedText)
                }
                .buttonStyle(GranolaIconButtonStyle())
                .help("Copiar ditado")

                Menu {
                    Button(role: .destructive, action: onDelete) {
                        Label("Apagar", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(VoizTheme.mutedText)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            // O espaço das ações existe sempre; só sua visibilidade muda. Assim o hover não
            // recalcula a altura nem desloca o divisor e as linhas vizinhas.
            .frame(width: 64, height: 30)
            .opacity(showsActions ? 1 : 0)
            .allowsHitTesting(showsActions)
            .accessibilityHidden(!showsActions)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isHovering ? VoizTheme.hoverBackground : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { isHovering = $0 }
    }

    // Remove somente margens vazias da apresentação; o texto salvo e copiado é preservado.
    private var displayText: String { entry.text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var showsActions: Bool { isHovering || isExpanded }

    private var timeLabel: String {
        let formatter = DateFormatter()
        formatter.locale = .voizInterface
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: entry.timestamp)
    }
}

struct HeaderView: View {
    @State private var showingSettings = false
    @Binding var selectedTab: Int
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.blue.gradient)
                
                VStack(alignment: .leading) {
                    Text("Voiz")
                        .font(.title)
                        .fontWeight(.bold)
                    
                    Text("Ditado, tradução e notas de reuniões")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button(action: { showingSettings = true }) {
                    Image(systemName: "gearshape.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Configurações")
            }
            .padding()
            
            Picker("", selection: $selectedTab) {
                Label("Ditado", systemImage: "waveform").tag(0)
                Label("Tradução", systemImage: "translate").tag(1)
                Label("Reuniões", systemImage: "person.2.wave.2").tag(2)
                Label("Histórico", systemImage: "clock.arrow.circlepath").tag(3)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .background(Color.secondary.opacity(0.05))
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }
}

struct AudioLevelIndicator: View {
    let level: Float
    /// Fora da gravação o trilho fica apagado, em vez de mostrar um nível parado do último uso.
    var isActive = true

    private var normalized: CGFloat {
        isActive ? CGFloat(min(max(level * 10, 0), 1)) : 0
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(VoizTheme.iconBackground)
                    .frame(height: 5)

                Capsule()
                    .fill(VoizTheme.accentGradient)
                    .frame(width: geometry.size.width * normalized, height: 5)
                    .animation(.easeOut(duration: 0.1), value: normalized)
            }
            .frame(height: 5)
            .frame(maxHeight: .infinity)
        }
        .frame(height: 5)
        .opacity(isActive ? 1 : 0.55)
        .animation(.easeOut(duration: 0.2), value: isActive)
    }
}

struct StatusBarView: View {
    @EnvironmentObject var viewModel: TranscriptionViewModel
    
    var body: some View {
        // Idle needs no line ("Pronto"); the row appears only while something happens.
        HStack(spacing: 7) {
            Image(systemName: statusIcon)
                .font(.system(size: 9))
                .foregroundColor(statusColor)

            Text(statusText)
                .font(.system(size: 11))
                .foregroundColor(VoizTheme.mutedText)

            Spacer()
        }
    }
    
    private var statusIcon: String {
        switch viewModel.state {
        case .idle:
            return "circle.fill"
        case .listening:
            return "mic.fill"
        case .processing:
            return "gearshape.fill"
        case .error:
            return "exclamationmark.circle.fill"
        }
    }
    
    private var statusColor: Color {
        switch viewModel.state {
        case .idle:
            return .gray
        case .listening:
            return .green
        case .processing:
            return .orange
        case .error:
            return .red
        }
    }
    
    private var statusText: String {
        switch viewModel.state {
        case .idle:
            return String(localized: "Pronto")
        case .listening:
            return String(localized: "Ouvindo…")
        case .processing:
            return String(localized: "Processando…")
        case let .error(message):
            return message
        }
    }
}

struct TranscriptionDebugConsole: View {
    @EnvironmentObject var viewModel: TranscriptionViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Console de Debug")
                    .font(.caption)
                    .fontWeight(.semibold)
                
                Spacer()
                
                Button("Limpar") {
                    viewModel.debugLogs.removeAll()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundColor(.blue)
            }
            
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(viewModel.debugLogs.enumerated()), id: \.offset) { _, log in
                        Text(log)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(logColor(for: log))
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 120)
            .padding(8)
            .background(Color.black.opacity(0.05))
            .cornerRadius(8)
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(12)
    }
    
    private func logColor(for log: String) -> Color {
        if log.contains("❌") {
            return .red
        } else if log.contains("✅") {
            return .green
        } else if log.contains("⚠️") {
            return .orange
        } else if log.contains("🎙️") || log.contains("🎯") || log.contains("📋") || log.contains("⌨️") {
            return .blue
        } else {
            return .primary
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(TranscriptionViewModel())
        .frame(width: 650, height: 550)
}
