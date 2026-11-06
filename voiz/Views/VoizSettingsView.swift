import SwiftUI

/// Granola-style settings, rendered inline in the app shell instead of a popup window.
struct VoizSettingsView: View {
    @Environment(\.voizCompactLayout) private var compactLayout
    @EnvironmentObject var viewModel: TranscriptionViewModel
    @ObservedObject var calendarService: MeetingCalendarService
    let onOpenProfile: () -> Void
    @ObservedObject private var updater = AppUpdateService.shared
    @ObservedObject private var hotKeyEngine = DictationHotKeyService.shared
    @ObservedObject private var profileStore = UserProfileStore.shared
    @State private var showsOnboarding = false
    @State private var visibleHeight: CGFloat = 660
    @State private var accessibilityTrusted = AccessibilityPermissionService.shared.isTrusted
    @State private var screenRecordingGranted = ScreenRecordingPermissionService.shared.isGranted
    @State private var interfaceLanguagePending = false
    @State private var notionToken = ""
    @State private var notionDestination = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                Text("Configurações")
                    .font(.system(size: 34, weight: .regular, design: .serif))
                    .foregroundColor(VoizTheme.primaryText)
                    .padding(.top, 8)

                VoizAccountSummaryRow(action: onOpenProfile)
                generalGroup
                dictationGroup
                DictationPreferencesView(settings: $viewModel.settings)
                transcriptionGroup
                meetingsGroup
                CalendarSettingsGroupView(service: calendarService)
                MCPSettingsGroupView()
                notionGroup
                aiGroup
                permissionsGroup
                aboutGroup

                Spacer(minLength: 60)
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, compactLayout ? 24 : 56)
            .frame(maxWidth: .infinity)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { visibleHeight = $0 }
        .sheet(isPresented: $showsOnboarding) {
            VoizOnboardingView(profileStore: profileStore, isReview: true) {
                showsOnboarding = false
            }
            // A folha não passa da borda da janela: numa janela baixa, o onboarding rola.
            .frame(width: 700, height: min(660, max(460, visibleHeight)))
        }
        .onAppear {
            accessibilityTrusted = AccessibilityPermissionService.shared.isTrusted
            screenRecordingGranted = ScreenRecordingPermissionService.shared.isGranted
            interfaceLanguagePending = InterfaceLanguageService.isPending(viewModel.settings.interfaceLanguage)
            notionToken = NotionCredentialsStore.shared.token()
            notionDestination = NotionCredentialsStore.shared.destination()
        }
        .onChange(of: viewModel.settings.interfaceLanguage) { _, language in
            InterfaceLanguageService.apply(language)
            interfaceLanguagePending = InterfaceLanguageService.isPending(language)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityTrusted = AccessibilityPermissionService.shared.isTrusted
            screenRecordingGranted = ScreenRecordingPermissionService.shared.isGranted
        }
        // A tela de Configurações edita a cópia de settings do TranscriptionViewModel
        // e persiste no disco. Os outros view models (Tradução, Reunião) só recarregam
        // ao receber esta notificação — sem ela, ficam com provider/modelo/API key
        // desatualizados (ex.: troca para xAI/Grok não tinha efeito na Tradução).
        .onChange(of: viewModel.settings) { _, _ in
            NotificationCenter.default.post(name: NSNotification.Name("SettingsChanged"), object: nil)
        }
    }

    // MARK: - Geral

    private var generalGroup: some View {
        SettingsGroup(title: "Geral") {
            SettingsRow(icon: "character.bubble", title: "Idioma da interface") {
                SettingsDropdown(
                    options: AppSettings.InterfaceLanguage.allCases.map { ($0, $0.displayName) },
                    selection: $viewModel.settings.interfaceLanguage
                )
            }
            if interfaceLanguagePending {
                restartNotice
            }
            SettingsDivider()
            SettingsRow(icon: "circle.lefthalf.filled", title: "Aparência") {
                SettingsDropdown(
                    options: AppSettings.InterfaceAppearance.allCases.map { ($0, $0.displayName) },
                    selection: $viewModel.settings.appearance
                )
            }
            SettingsDivider()
            SettingsRow(icon: "waveform", title: "Indicador de gravação",
                        subtitle: "Aparece sobre outros apps durante ditados e reuniões") {
                settingsToggle($viewModel.settings.showRecordingHUD)
            }
            SettingsDivider()
            SettingsRow(icon: "macbook", title: "Status no notch",
                        subtitle: "Experimental. Gravação e avisos no topo da tela.") {
                settingsToggle($viewModel.settings.notchOverlayEnabled)
            }
            SettingsDivider()
            SettingsRow(icon: "text.cursor", title: "Inserir texto automaticamente",
                        subtitle: "Cola o resultado no app ativo após o ditado") {
                settingsToggle($viewModel.settings.autoInsertText)
            }
            SettingsDivider()
            SettingsRow(icon: "gauge.with.dots.needle.50percent", title: "Mostrar confiança da transcrição") {
                settingsToggle($viewModel.settings.showConfidence)
            }
        }
    }

    // MARK: - Reuniões

    private var meetingsGroup: some View {
        SettingsGroup(title: "Reuniões") {
            SettingsRow(icon: "waveform.path.badge.plus", title: "Modo de reunião",
                        subtitle: $viewModel.settings.meetingMode.wrappedValue == .granola
                            ? "Transcreve durante a reunião e fica pronto ao encerrar."
                            : "Processa ao final, com mais precisão e separação de vozes.") {
                SettingsDropdown(
                    options: AppSettings.MeetingMode.allCases.map { ($0, $0.menuLabel) },
                    selection: $viewModel.settings.meetingMode
                )
            }
            SettingsDivider()
            SettingsRow(icon: "bell.badge", title: "Detectar reuniões",
                        subtitle: "Sugere gravar ao entrar no Teams, Meet ou Zoom.") {
                settingsToggle($viewModel.settings.meetingDetectionEnabled)
            }
            if viewModel.settings.meetingMode != .granola {
                SettingsDivider()
                SettingsRow(icon: "captions.bubble", title: "Prévia ao vivo",
                            subtitle: "Usa mais CPU e bateria.") {
                    settingsToggle($viewModel.settings.meetingLivePreviewEnabled)
                }
            }
            SettingsDivider()
            SettingsRow(icon: "text.quote", title: "Idioma das notas",
                        subtitle: "Resumo, capítulos e respostas da IA.") {
                SettingsDropdown(
                    options: AppSettings.NotesLanguage.allCases.map { ($0, $0.displayName) },
                    selection: $viewModel.settings.notesLanguage
                )
            }
        }
    }

    // MARK: - Notion

    private var notionGroup: some View {
        SettingsGroup(title: "Notion") {
            SettingsRow(
                icon: "key",
                title: "Token do Notion",
                subtitle: "Token da sua integração interna."
            ) {
                apiKeyField($notionToken, placeholder: "secret_…")
            }
            SettingsDivider()
            SettingsRow(
                icon: "link",
                title: "Destino no Notion",
                subtitle: "Página ou database compartilhada com a integração."
            ) {
                plainField($notionDestination, placeholder: "https://www.notion.so/…")
            }
        }
        .onChange(of: notionToken) { _, value in
            NotionCredentialsStore.shared.setToken(value)
        }
        .onChange(of: notionDestination) { _, value in
            NotionCredentialsStore.shared.setDestination(value)
        }
    }

    // MARK: - Transcrição

    private var transcriptionGroup: some View {
        SettingsGroup(title: "Transcrição") {
            SettingsRow(icon: "waveform.badge.mic", title: "Motor de transcrição",
                        subtitle: "Para ditado e reuniões no modo Qualidade.") {
                SettingsDropdown(
                    // Só o que roda com o idioma escolhido: o Parakeet é pt-BR-only, e o Apple
                    // exige idioma definido. Oferecer o resto seria oferecer escolha que o
                    // roteador ignora.
                    options: AppSettings.TranscriptionEngine
                        .selectable(for: viewModel.settings.selectedLanguage)
                        .map { ($0, $0.displayName) },
                    selection: $viewModel.settings.transcriptionEngine
                )
            }
            if viewModel.settings.transcriptionEngine == .whisper {
                SettingsDivider()
                SettingsRow(icon: "cpu", title: "Modelo de transcrição",
                            subtitle: "Baixado no primeiro uso.") {
                    SettingsDropdown(
                        options: AppSettings.ModelSize.allCases.map { ($0, $0.displayName) },
                        selection: $viewModel.settings.modelSize
                    )
                }
            }
            modelStatusView
        }
    }

    // MARK: - Ditado

    /// Os atalhos moravam em "Transcrição", junto de idioma/engine/modelo — que valem para ditado **e**
    /// reuniões. Separar deixa claro o que é exclusivo do ditado.
    private var dictationGroup: some View {
        SettingsGroup(title: "Ditado") {
            SettingsRow(icon: "globe", title: "Idioma do ditado",
                        subtitle: "Também vale para reuniões.") {
                SettingsDropdown(
                    options: Language.allCases.map { ($0, $0.displayName) },
                    selection: $viewModel.settings.selectedLanguage
                )
                .onChange(of: viewModel.settings.selectedLanguage) { _, _ in
                    // Trocar o idioma pode invalidar o motor escolhido; mantém a escolha visível
                    // alinhada ao engine que o app realmente consegue executar.
                    viewModel.settings.realignTranscriptionEngineWithLanguage()
                }
            }
            SettingsDivider()
            SettingsRow(icon: "keyboard", title: "Atalhos de ditado",
                        subtitle: "Segure Fn para falar ou toque para mãos livres.") {
                settingsToggle($viewModel.settings.dictationHotkeysEnabled)
            }
            if viewModel.settings.dictationHotkeysEnabled {
                shortcutBlock(
                    title: "Segurar para falar",
                    subtitle: "Solte para parar e colar.",
                    binding: $viewModel.settings.pushToTalkShortcut,
                    defaultValue: .fnPushToTalk
                )
                shortcutBlock(
                    title: "Mãos livres",
                    subtitle: "Toque para começar e de novo para parar.",
                    binding: $viewModel.settings.handsFreeShortcut,
                    defaultValue: .fnSpaceHandsFree
                )
                SettingsRow(icon: "bolt.horizontal.circle", title: "Motor de atalhos",
                            subtitle: hotKeyEngineSubtitle) {
                    Label(
                        hotKeyEngine.isEngineActive ? "Ativo" : "Inativo",
                        systemImage: hotKeyEngine.isEngineActive ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(hotKeyEngine.isEngineActive ? .green : .orange)
                }
                Text("Se a Fn não responder, vá em Ajustes do Sistema → Teclado → \"Pressionar 🌐 para: Não fazer nada\".")
                    .font(.system(size: 11))
                    .foregroundColor(VoizTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
    }

    /// Faixa de "reinicie para aplicar". Aparece só quando a escolha difere do idioma em execução —
    /// o macOS resolve a localização do bundle no launch e não há troca a quente.
    private var restartNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.clockwise.circle")
                .foregroundColor(VoizTheme.accent)
            Text("Reinicie o Voiz para aplicar o novo idioma.")
                .font(.system(size: 12))
                .foregroundColor(VoizTheme.mutedText)
            Spacer()
            Button("Reiniciar agora") { InterfaceLanguageService.relaunch() }
                .buttonStyle(GranolaPillButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .padding(.leading, 48)
    }

    /// O motivo do motor estar parado já chega traduzido do serviço; embrulhar em `LocalizedStringKey`
    /// só falha a busca e exibe o próprio texto, que é o comportamento desejado.
    private var hotKeyEngineSubtitle: LocalizedStringKey {
        if let issue = hotKeyEngine.lastIssue { return LocalizedStringKey(issue) }
        return "Capturando as teclas globalmente"
    }

    /// Bloco de um atalho editável (rótulo + "Padrão" + recorder de largura total).
    @ViewBuilder
    private func shortcutBlock(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        binding: Binding<KeyboardShortcut>,
        defaultValue: KeyboardShortcut
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(VoizTheme.primaryText)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(VoizTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Padrão") { binding.wrappedValue = defaultValue }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(VoizTheme.accent)
            }
            HotKeyRecorder(shortcut: binding)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// Mostra o estado do modelo Whisper: baixando (com %), carregando, pronto ou erro.
    @ViewBuilder
    private var modelStatusView: some View {
        switch viewModel.modelLoadState {
        case .idle:
            EmptyView()
        case .ready:
            modelStatusStrip(tint: .green) {
                EmptyView()
            } label: {
                Label("Modelo pronto", systemImage: "checkmark.circle")
            }
        case .downloading(let progress):
            modelStatusStrip {
                HStack(spacing: 10) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: .infinity)
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundColor(VoizTheme.mutedText)
                }
            } label: {
                Label("Baixando modelo…", systemImage: "arrow.down.circle")
            }
        case .loading:
            modelStatusStrip {
                ProgressView().controlSize(.small)
            } label: {
                Label("Carregando modelo…", systemImage: "cpu")
            }
        case .failed(let message):
            modelStatusStrip(tint: .red) {
                EmptyView()
            } label: {
                Label(message, systemImage: "exclamationmark.triangle")
            }
        }
    }

    /// Faixa fina sob o seletor de modelo, alinhada ao recuo das outras linhas.
    @ViewBuilder
    private func modelStatusStrip<Trailing: View, LabelView: View>(
        tint: Color = VoizTheme.accent,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder label: () -> LabelView
    ) -> some View {
        HStack(spacing: 10) {
            label()
                .font(.system(size: 12))
                .foregroundColor(tint)
                .labelStyle(.titleAndIcon)
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .padding(.leading, 48)
    }

    // MARK: - IA & Tradução

    private var aiGroup: some View {
        SettingsGroup(title: "IA & Tradução") {
            if viewModel.hasCredentialDrafts {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: viewModel.credentialDraftMessage)
                    Button(action: viewModel.saveCredentialEdits) {
                        Text(verbatim: viewModel.credentialSaveTitle)
                    }
                    .disabled(viewModel.isSavingCredentials)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 16)
            }
            if viewModel.isSavingCredentials {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(verbatim: viewModel.credentialSavingTitle)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 16)
            }
            if viewModel.hasCredentialError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: viewModel.credentialErrorMessage)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(action: viewModel.retryCredentialAccess) {
                        Text(verbatim: viewModel.credentialRetryTitle)
                    }
                    .disabled(viewModel.isSavingCredentials)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 16)
            }
            SettingsRow(icon: "server.rack", title: "Provedor",
                        subtitle: "Usado no chat e na tradução") {
                SettingsDropdown(
                    options: AppSettings.TranslationProvider.allCases.map { ($0, $0.displayName) },
                    selection: Binding(get: { viewModel.settings.translationProvider }, set: {
                        viewModel.settings.translationProvider = $0
                    })
                )
            }
            SettingsDivider()

            switch viewModel.settings.translationProvider {
            case .openai:
                SettingsRow(icon: "key", title: "OpenAI API Key", subtitle: "Obtenha em platform.openai.com") {
                    apiKeyField(viewModel.credentialBinding(.openAIKey), placeholder: "sk-…")
                }
                SettingsDivider()
                SettingsRow(icon: "brain", title: "Modelo", subtitle: LocalizedStringKey(currentModelDescription)) {
                    SettingsDropdown(
                        options: AppSettings.TranslationModel.allCases.map { ($0, $0.displayName) },
                        selection: $viewModel.settings.translationModel
                    )
                }
            case .anthropic:
                SettingsRow(icon: "key", title: "Anthropic API Key", subtitle: "Obtenha em console.anthropic.com") {
                    apiKeyField(viewModel.credentialBinding(.anthropicKey), placeholder: "sk-ant-…")
                }
                SettingsDivider()
                SettingsRow(icon: "brain", title: "Modelo", subtitle: LocalizedStringKey(currentModelDescription)) {
                    SettingsDropdown(
                        options: AppSettings.AnthropicModel.allCases.map { ($0, $0.displayName) },
                        selection: $viewModel.settings.anthropicModel
                    )
                }
            case .xai:
                SettingsRow(icon: "key", title: "xAI API Key", subtitle: "Obtenha em console.x.ai") {
                    apiKeyField(viewModel.credentialBinding(.xaiKey), placeholder: "xai-…")
                }
                SettingsDivider()
                SettingsRow(icon: "brain", title: "Modelo", subtitle: LocalizedStringKey(currentModelDescription)) {
                    SettingsDropdown(
                        options: AppSettings.XAIModel.allCases.map { ($0, $0.displayName) },
                        selection: $viewModel.settings.xaiModel
                    )
                }
            case .gemini:
                SettingsRow(icon: "key", title: "Gemini API Key", subtitle: "Obtenha em aistudio.google.com/apikey") {
                    apiKeyField(viewModel.credentialBinding(.geminiKey), placeholder: "AIza…")
                }
                SettingsDivider()
                SettingsRow(icon: "brain", title: "Modelo", subtitle: LocalizedStringKey(currentModelDescription)) {
                    SettingsDropdown(
                        options: AppSettings.GeminiModel.allCases.map { ($0, $0.displayName) },
                        selection: $viewModel.settings.geminiModel
                    )
                }
            case .custom:
                SettingsRow(icon: "link", title: "Endpoint", subtitle: "URL OpenAI-compatible (ex.: seu LiteLLM)") {
                    plainField($viewModel.settings.customBaseURL, placeholder: "http://localhost:4000")
                }
                SettingsDivider()
                SettingsRow(icon: "key", title: "API Key", subtitle: "Chave do seu endpoint") {
                    apiKeyField(viewModel.credentialBinding(.customKey), placeholder: "sk-…")
                }
                SettingsDivider()
                SettingsRow(icon: "brain", title: "Modelo", subtitle: "Nome exato do modelo no seu endpoint") {
                    plainField($viewModel.settings.customModel, placeholder: "gpt-5.6-luna")
                }
            }

            reasoningEffortRow
        }
    }

    /// Linha do `reasoning_effort`. Some quando o modelo ativo não tem o parâmetro (os slugs
    /// `grok-4.20`, por exemplo, já trazem a decisão no nome).
    @ViewBuilder
    private var reasoningEffortRow: some View {
        let supported = viewModel.settings.supportedReasoningEfforts
        if !supported.isEmpty {
            // Lê o esforço já grampeado na faixa do modelo: o guardado pode estar fora dela
            // (troca de modelo depois da escolha) e o dropdown ficaria sem rótulo.
            let effort = Binding(
                get: { viewModel.settings.effectiveReasoningEffort },
                set: { viewModel.settings.reasoningEffort = $0 }
            )
            SettingsDivider()
            SettingsRow(icon: "gauge.with.needle", title: "Raciocínio",
                        subtitle: LocalizedStringKey(effort.wrappedValue.description)) {
                SettingsDropdown(
                    options: ([.auto] + supported).map { ($0, $0.displayName) },
                    selection: effort
                )
            }
        }
    }

    private var currentModelDescription: String {
        viewModel.settings.currentModelDescription
    }

    // MARK: - Permissões

    private var permissionsGroup: some View {
        SettingsGroup(title: "Permissões") {
            SettingsRow(icon: "lock.shield", title: "Acessibilidade",
                        subtitle: accessibilityTrusted ? nil : "Para colar o texto ditado.") {
                if accessibilityTrusted {
                    Label("Ativa", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.green)
                } else {
                    Button("Abrir Ajustes") {
                        AccessibilityPermissionService.shared.openAccessibilitySettings()
                    }
                    .buttonStyle(GranolaPillButtonStyle())
                }
            }

            SettingsDivider()

            SettingsRow(icon: "waveform.badge.mic", title: "Gravação de Tela",
                        subtitle: screenRecordingGranted ? nil : "Para gravar o áudio dos participantes.") {
                if screenRecordingGranted {
                    Label("Ativa", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.green)
                } else {
                    Button("Abrir Ajustes") {
                        ScreenRecordingPermissionService.shared.requestAccess()
                        ScreenRecordingPermissionService.shared.openScreenRecordingSettings()
                    }
                    .buttonStyle(GranolaPillButtonStyle())
                }
            }
        }
    }

    // MARK: - Sobre

    private var aboutGroup: some View {
        SettingsGroup(title: "Sobre") {
            SettingsRow(icon: "info.circle", title: "Versão") {
                Text(appVersion)
                    .font(.system(size: 13))
                    .foregroundColor(VoizTheme.mutedText)
            }
            SettingsDivider()
            SettingsRow(icon: "arrow.triangle.2.circlepath", title: "Buscar atualizações automaticamente",
                        subtitle: updater.isConfigured ? nil : "Indisponível nesta versão") {
                settingsToggle(Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: updater.setAutomaticallyChecksForUpdates
                ))
                .accessibilityLabel(Text("Buscar atualizações automaticamente"))
                .disabled(!updater.isConfigured)
            }
            SettingsDivider()
            SettingsRow(icon: "arrow.down.circle", title: "Atualizações") {
                CheckForUpdatesButton()
                    .buttonStyle(GranolaPillButtonStyle())
            }
            SettingsDivider()
            SettingsRow(icon: "sparkles", title: "Apresentação do Voiz") {
                Button("Rever") { showsOnboarding = true }
                    .buttonStyle(GranolaPillButtonStyle())
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    // MARK: - Helpers

    private func settingsToggle(_ binding: Binding<Bool>) -> some View {
        Toggle("", isOn: binding)
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(VoizTheme.accent)
    }

    private func apiKeyField(_ binding: Binding<String>, placeholder: String) -> some View {
        SecureField(placeholder, text: binding)
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .foregroundColor(VoizTheme.primaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(width: 260)
            .background(VoizTheme.elevatedBackground)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(VoizTheme.border))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func plainField(_ binding: Binding<String>, placeholder: String) -> some View {
        TextField(placeholder, text: binding)
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .foregroundColor(VoizTheme.primaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(width: 260)
            .background(VoizTheme.elevatedBackground)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(VoizTheme.border))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Reusable building blocks

struct SettingsGroup<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(VoizTheme.mutedText)

            VStack(spacing: 0) {
                content
            }
            .background(VoizTheme.surfaceBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(VoizTheme.border)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }
}

struct SettingsRow<Trailing: View>: View {
    let icon: String
    let title: Text
    var subtitle: Text? = nil
    let trailing: Trailing

    /// `LocalizedStringKey` para os literais localizarem sozinhos; textos já resolvidos em runtime
    /// (ex.: descrição do modelo ativo) passam batido — a busca falha e o próprio texto é exibido.
    init(icon: String, title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil,
         @ViewBuilder trailing: () -> Trailing) {
        self.init(icon: icon, title: Text(title), subtitle: subtitle.map { Text($0) }, trailing: trailing)
    }

    /// Dados do usuário/serviço (e-mail, datas) entram como `Text(verbatim:)` ou interpolados.
    init(icon: String, title: Text, subtitle: Text? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 8)
                .fill(VoizTheme.iconBackground)
                .frame(width: 34, height: 34)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(VoizTheme.mutedText)
                )

            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(VoizTheme.primaryText)
                if let subtitle {
                    subtitle
                        .font(.system(size: 12))
                        .foregroundColor(VoizTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Linha que abre um painel, como nos Ajustes do Sistema: valor atual + chevron.
struct SettingsNavigationRow: View {
    let icon: String
    let title: Text
    var subtitle: Text? = nil
    var value: Text? = nil
    let action: () -> Void
    @State private var isHovering = false

    init(icon: String, title: LocalizedStringKey, subtitle: Text? = nil, value: Text? = nil,
         action: @escaping () -> Void) {
        self.icon = icon
        self.title = Text(title)
        self.subtitle = subtitle
        self.value = value
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            SettingsRow(icon: icon, title: title, subtitle: subtitle) {
                HStack(spacing: 8) {
                    if let value {
                        value
                            .font(.system(size: 13))
                            .foregroundColor(VoizTheme.mutedText)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(VoizTheme.mutedText)
                }
            }
            .background(isHovering ? VoizTheme.hoverBackground : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(VoizTheme.border)
            .frame(height: 1)
            .padding(.leading, 64)
    }
}

struct SettingsDropdown<T: Hashable>: View {
    let options: [(value: T, label: String)]
    @Binding var selection: T

    var body: some View {
        Menu {
            ForEach(options, id: \.value) { option in
                Button(action: { selection = option.value }) {
                    HStack {
                        Text(option.label)
                        if option.value == selection {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            // O fundo/borda vêm do `ButtonStyle`: com `.menuStyle(.borderlessButton)` o macOS
            // descarta o que for aplicado aqui dentro e sobra só o texto.
            HStack(spacing: 6) {
                Text(currentLabel)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .opacity(0.7)
                    .accessibilityHidden(true)
            }
        }
        .menuStyle(.button)
        .buttonStyle(VoizDropdownButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var currentLabel: String {
        options.first(where: { $0.value == selection })?.label ?? ""
    }
}
