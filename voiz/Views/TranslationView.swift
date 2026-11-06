import SwiftUI

struct TranslationView: View {
    @EnvironmentObject var viewModel: TranslationViewModel
    @EnvironmentObject var navigation: VoizNavigation
    @State private var viewingEntry: TranslationEntry?

    var body: some View {
        Group {
            if let entry = viewingEntry {
                TranslationReviewView(entry: entry, onBack: { viewingEntry = nil })
            } else {
                TranslationWorkspaceView(onOpen: { viewingEntry = $0 })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Resultado escolhido na busca global (⌘K).
        .onAppear(perform: consumePendingOpen)
        .onChange(of: navigation.pendingOpen, initial: false) { _, _ in consumePendingOpen() }
    }

    private func consumePendingOpen() {
        guard let id = navigation.pending(.translation),
              let entry = viewModel.historyStore.visibleEntry(id: id) else { return }
        viewingEntry = entry
        navigation.clear()
    }
}

private enum TranslationLayout {
    static let maxWidth: CGFloat = 900
    static let horizontalPadding: CGFloat = 56
    static let panelsHeight: CGFloat = 420
}

// MARK: - Workspace

struct TranslationWorkspaceView: View {
    @EnvironmentObject var viewModel: TranslationViewModel
    let onOpen: (TranslationEntry) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center, spacing: 12) {
                    Text("Tradução")
                        .font(.system(size: 34, weight: .regular, design: .serif))
                        .foregroundColor(VoizTheme.primaryText)

                    Spacer()

                    TranslationLanguagePill()
                        .disabled(viewModel.isPreparingRecording || viewModel.state == .listening || viewModel.state == .processing)
                    ModelIndicatorBadge()
                }
                .padding(.top, 16)

                TranslationPanels()
                    .frame(height: TranslationLayout.panelsHeight)

                TranslationControlsBar()

                if let issue = viewModel.visibleTranslationIssue {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Tradução indisponível").font(.system(size: 13, weight: .semibold))
                            Text(issue.message).font(.system(size: 12)).foregroundStyle(VoizTheme.mutedText)
                        }
                        Spacer(minLength: 8)
                        if issue != .speechDetectionUnavailable && issue != .audioProcessingFailed {
                            Button("Configurar IA") {
                                NotificationCenter.default.post(name: Notification.Name("OpenVoizSettings"), object: nil)
                            }
                            .buttonStyle(GranolaPillButtonStyle())
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(VoizTheme.surfaceBackground, in: RoundedRectangle(cornerRadius: 12))
                }

                if viewModel.showDebugConsole && AppEnvironment.current.isDevelopment {
                    DebugConsoleSection()
                }

                TranslationRecentsList(store: viewModel.historyStore, onOpen: onOpen)

                Spacer(minLength: 40)
            }
            .frame(maxWidth: TranslationLayout.maxWidth)
            .padding(.horizontal, TranslationLayout.horizontalPadding)
            .frame(maxWidth: .infinity)
        }
        .onAppear(perform: viewModel.reloadSettings)
        .onDisappear(perform: viewModel.cancelRecordingStart)
    }
}

// MARK: - Language pill

struct TranslationLanguagePill: View {
    @EnvironmentObject var viewModel: TranslationViewModel

    var body: some View {
        HStack(spacing: 8) {
            languageMenu("Idioma de origem", selection: $viewModel.sourceLanguage)

            Button(action: viewModel.swapLanguages) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(VoizTheme.mutedText)
            }
            .buttonStyle(.plain)
            .help("Inverter idiomas")
            .accessibilityLabel("Inverter idiomas")

            languageMenu("Idioma de destino", selection: $viewModel.targetLanguage)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(VoizTheme.elevatedBackground)
        .overlay(Capsule().stroke(VoizTheme.border))
        .clipShape(Capsule())
    }

    private func languageMenu(_ title: LocalizedStringKey, selection: Binding<Language>) -> some View {
        Menu {
            Picker(title, selection: selection) {
                ForEach(Language.allCases) { language in
                    Text(verbatim: "\(language.flag)  \(language.displayName)").tag(language)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(selection.wrappedValue.flag)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(VoizTheme.primaryText)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(Text(selection.wrappedValue.displayName))
    }
}

// MARK: - Two panels card

struct TranslationPanels: View {
    @EnvironmentObject var viewModel: TranslationViewModel

    private var isLive: Bool { viewModel.state == .listening }

    var body: some View {
        HStack(spacing: 0) {
            TranslationPanel(
                title: "Original",
                text: viewModel.sourceText,
                placeholder: "Aguardando transcrição…",
                animated: isLive
            )

            Rectangle().fill(VoizTheme.border).frame(width: 1)

            TranslationPanel(
                title: "Tradução",
                text: viewModel.translatedText,
                placeholder: "A tradução aparece aqui…",
                animated: isLive
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VoizTheme.surfaceBackground)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(VoizTheme.border))
        .cornerRadius(12)
    }
}

struct TranslationPanel: View {
    let title: LocalizedStringKey
    let text: String
    let placeholder: LocalizedStringKey
    var animated: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(VoizTheme.mutedText)
                    .textCase(.uppercase)
                Spacer()
                if !text.isEmpty {
                    Button(action: { copyToClipboard(text) }) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundColor(VoizTheme.mutedText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Rectangle().fill(VoizTheme.border).frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        if text.isEmpty {
                            Text(placeholder)
                                .font(.system(size: 16))
                                .foregroundColor(VoizTheme.mutedText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            StreamingText(text: text, animated: animated)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16)
                    .id("bottom")
                }
                .onChange(of: text) { _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Controls

struct TranslationControlsBar: View {
    @EnvironmentObject var viewModel: TranslationViewModel

    private var isListening: Bool { viewModel.state == .listening }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: viewModel.toggleRecording) {
                Label(recordingText, systemImage: recordingIcon)
            }
            .buttonStyle(GranolaPillButtonStyle(accented: isListening))
            .disabled(viewModel.state == .processing || (!isListening && viewModel.translationConfigurationIssue != nil))

            if isListening {
                AudioLevelBar(level: viewModel.audioLevel)
                    .frame(width: 120, height: 5)
            }

            if !viewModel.sourceText.isEmpty {
                Button(action: viewModel.clearTranslation) {
                    Image(systemName: "trash")
                }
                .buttonStyle(GranolaIconButtonStyle())
            }

            Spacer()

            // Confirmação de que a gravação virou entrada em Recentes. Como as caixas são limpas
            // ao parar, sem isto não sobraria sinal nenhum de que algo foi guardado.
            if let notice = viewModel.archiveNotice {
                HStack(spacing: 5) {
                    Image(systemName: notice == .complete
                        ? "checkmark.circle.fill"
                        : "exclamationmark.circle.fill")
                    // "sem o final" quando o teto da espera estourou: o final da fala não entrou
                    // na entrada, e dizer só "Salvo" aqui seria a perda silenciosa de novo.
                    Text(notice.message)
                }
                .font(.system(size: 11))
                .foregroundColor(VoizTheme.mutedText)
                .transition(.opacity)
            }

            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 6, height: 6)
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundColor(VoizTheme.mutedText)
            }

            if AppEnvironment.current.isDevelopment && viewModel.lastTranslationLatency > 0 {
                Text("\(Int(viewModel.lastTranslationLatency * 1000))ms")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundColor(VoizTheme.mutedText)
            }

            if AppEnvironment.current.isDevelopment {
                Button(action: { viewModel.showDebugConsole.toggle() }) {
                    Image(systemName: "terminal")
                }
                .buttonStyle(GranolaIconButtonStyle())
                .help(viewModel.showDebugConsole ? "Ocultar Console" : "Mostrar Console")
                .accessibilityLabel(viewModel.showDebugConsole ? Text("Ocultar Console") : Text("Mostrar Console"))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.archiveNotice)
    }

    private var recordingIcon: String {
        switch viewModel.state {
        case .idle: return "mic.fill"
        case .listening: return "stop.fill"
        case .processing: return "waveform"
        case .error: return "exclamationmark.circle"
        }
    }

    private var recordingText: String {
        if viewModel.isPreparingRecording { return String(localized: "Cancelar preparação") }
        switch viewModel.state {
        case .idle: return String(localized: "Gravar")
        case .listening: return String(localized: "Parar")
        case .processing: return String(localized: "Processando")
        case .error: return String(localized: "Tentar de novo")
        }
    }

    private var statusColor: Color {
        if viewModel.visibleTranslationIssue != nil { return .orange }
        switch viewModel.state {
        case .idle: return .gray
        case .listening: return .green
        case .processing: return .orange
        case .error: return .red
        }
    }

    private var statusText: String {
        if viewModel.isPreparingRecording { return String(localized: "Preparando detecção de fala…") }
        if viewModel.visibleTranslationIssue != nil { return String(localized: "Tradução indisponível") }
        switch viewModel.state {
        case .idle: return String(localized: "Pronto")
        case .listening: return String(localized: "Gravando")
        case .processing: return String(localized: "Processando")
        case .error: return String(localized: "Erro")
        }
    }
}

// MARK: - Recents

struct TranslationRecentsList: View {
    @ObservedObject var store: TranslationHistoryStore
    let onOpen: (TranslationEntry) -> Void
    @State private var entryToRename: TranslationEntry?
    @State private var renameDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HomeSectionTitle("Recentes")
            if let error = store.storageError { Text(error).font(.caption).foregroundStyle(.orange) }

            if store.entries.isEmpty {
                HomeRecentRow(
                    icon: "globe",
                    title: String(localized: "Suas traduções vão aparecer aqui"),
                    subtitle: String(localized: "Grave uma fala para criar histórico"),
                    detail: ""
                )
            } else {
                ForEach(store.entries) { entry in
                    HomeRecentRow(
                        icon: "globe",
                        title: entry.displayTitle,
                        subtitle: "\(entry.sourceLanguage.flag) → \(entry.targetLanguage.flag)",
                        detail: entry.formattedDate,
                        action: { onOpen(entry) },
                        onRename: {
                            entryToRename = entry
                            renameDraft = entry.displayTitle
                        },
                        onDelete: { VoizEditingGate.shared.submit { store.deleteEntry(entry) } }
                    )
                }
                if store.hasMoreEntries {
                    Button("Carregar mais") { store.loadMore() }
                        .buttonStyle(.borderless)
                }
            }
        }
        .sheet(isPresented: renameAlertBinding) {
            RenameSheet(
                title: "Renomear tradução",
                text: $renameDraft,
                onCancel: { entryToRename = nil },
                onSave: {
                    if let entry = entryToRename {
                        let title = renameDraft
                        VoizEditingGate.shared.submit { store.renameEntry(entry, to: title) }
                    }
                    entryToRename = nil
                }
            )
        }
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { entryToRename != nil },
            set: { if !$0 { entryToRename = nil } }
        )
    }
}

// MARK: - Review

struct TranslationReviewView: View {
    @EnvironmentObject var viewModel: TranslationViewModel
    let entry: TranslationEntry
    let onBack: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VoizBackButton(title: "Tradução", action: onBack)
                    .padding(.top, 16)

                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.displayTitle)
                        .font(.system(size: 28, weight: .regular, design: .serif))
                        .foregroundColor(VoizTheme.primaryText)
                        .lineLimit(2)
                    Text("\(entry.formattedDate) • \(entry.sourceLanguage.flag) → \(entry.targetLanguage.flag)")
                        .font(.system(size: 13))
                        .foregroundColor(VoizTheme.mutedText)
                }

                HStack(spacing: 8) {
                    Button(action: { copyToClipboard(entry.translatedText) }) {
                        Label("Copiar tradução", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(GranolaPillButtonStyle())

                    Button(action: { copyToClipboard(entry.sourceText) }) {
                        Label("Copiar original", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(GranolaPillButtonStyle())

                    Spacer()

                    Button(action: {
                        VoizEditingGate.shared.submit {
                            if viewModel.historyStore.deleteEntry(entry) { onBack() }
                        }
                    }) {
                        Label("Apagar", systemImage: "trash")
                    }
                    .buttonStyle(GranolaPillButtonStyle())
                }

                HomeDetailSection(title: "Original") {
                    Text(entry.sourceText.isEmpty ? "—" : entry.sourceText)
                        .font(.system(size: 15))
                        .foregroundColor(VoizTheme.primaryText)
                        .textSelection(.enabled)
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HomeDetailSection(title: "Tradução") {
                    Text(entry.translatedText.isEmpty ? "—" : entry.translatedText)
                        .font(.system(size: 15))
                        .foregroundColor(VoizTheme.primaryText)
                        .textSelection(.enabled)
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer(minLength: 40)
            }
            .frame(maxWidth: TranslationLayout.maxWidth)
            .padding(.horizontal, TranslationLayout.horizontalPadding)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Audio level

struct AudioLevelBar: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(VoizTheme.iconBackground)
                Capsule()
                    .fill(VoizTheme.accent.gradient)
                    .frame(width: geometry.size.width * CGFloat(min(level * 10, 1.0)))
                    .animation(.easeOut(duration: 0.1), value: level)
            }
        }
    }
}

// MARK: - Model badge

struct ModelIndicatorBadge: View {
    @EnvironmentObject var viewModel: TranslationViewModel

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(providerColor)
                .frame(width: 6, height: 6)
            // The model is enough; the provider's full name only made the badge long.
            Text(verbatim: modelName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(VoizTheme.primaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(VoizTheme.elevatedBackground)
        .overlay(Capsule().stroke(VoizTheme.border))
        .clipShape(Capsule())
    }

    private var modelName: String {
        switch viewModel.settings.translationProvider {
        case .openai:
            switch viewModel.settings.translationModel {
            case .gpt56Luna: return "GPT-5.6 Luna"
            case .gpt56Terra: return "GPT-5.6 Terra"
            case .gpt56Sol: return "GPT-5.6 Sol"
            case .gpt6Astra: return "GPT-6 Astra"
            }
        case .anthropic:
            switch viewModel.settings.anthropicModel {
            case .haiku45: return "Haiku 4.5"
            case .sonnet5: return "Sonnet 5"
            case .opus5: return "Opus 5"
            case .fable51: return "Fable 5.1"
            }
        case .xai:
            switch viewModel.settings.xaiModel {
            case .grok420NonReasoning: return "Grok 4.20"
            case .grok45: return "Grok 4.5"
            case .grok46: return "Grok 4.6"
            case .grok43: return "Grok 4.3"
            case .grok420Reasoning: return "Grok 4.20 R"
            case .grokBuild01: return "Grok Build"
            }
        case .gemini:
            switch viewModel.settings.geminiModel {
            case .gemini38Flash: return "Gemini 3.8"
            case .gemini37Flash: return "Gemini 3.7"
            case .gemini31FlashLite: return "Gemini 3.1 Lite"
            case .gemini36Flash: return "Gemini 3.6"
            case .gemini35Flash: return "Gemini 3.5"
            case .gemini35FlashLite: return "Gemini 3.5 Lite"
            case .gemini31ProPreview: return "Gemini 3.1 Pro"
            case .gemini25Flash: return "Gemini 2.5"
            case .gemini25Pro: return "Gemini 2.5 Pro"
            }
        case .custom:
            return viewModel.settings.customModel.isEmpty ? String(localized: "Modelo personalizado") : viewModel.settings.customModel
        }
    }

    private var providerColor: Color {
        switch viewModel.settings.translationProvider {
        case .openai: return .blue
        case .anthropic: return .brown
        case .xai: return .orange
        case .gemini: return .teal
        case .custom: return .purple
        }
    }
}

// MARK: - Helpers

func copyToClipboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

extension Language {
    var flag: String {
        switch self {
        case .portuguese: return "🇧🇷 PT"
        case .english: return "🇺🇸 EN"
        case .spanish: return "🇪🇸 ES"
        case .french: return "🇫🇷 FR"
        case .german: return "🇩🇪 DE"
        case .japanese: return "🇯🇵 JA"
        case .chinese: return "🇨🇳 ZH"
        }
    }
}
