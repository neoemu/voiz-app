import SwiftUI

/// Paleta da busca global (⌘K): campo no topo, resultados abaixo, navegação por teclado.
/// Aparece sobreposta ao app inteiro — é a única tela do Voiz que atravessa as abas, então vive
/// em `ContentView` e devolve o item escolhido por `onOpen`.
struct VoizSearchPalette: View {
    @ObservedObject var transcriptionViewModel: TranscriptionViewModel
    @ObservedObject var meetingViewModel: MeetingViewModel
    @ObservedObject var translationStore: TranslationHistoryStore
    @ObservedObject private var library = LocalLibraryRuntime.shared

    let onOpen: (VoizSearchResult) -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var selection = 0
    /// Só a navegação por teclado rola a lista. Seguir o hover também faria a paleta abrir no meio
    /// dos resultados quando o cursor já estivesse parado sobre ela.
    @State private var scrollTarget: UUID?
    @FocusState private var fieldFocused: Bool

    private static let rowHeight: CGFloat = 50
    private static let rowSpacing: CGFloat = 2
    private static let listPadding: CGFloat = 16
    private static let maxListHeight: CGFloat = 380

    private var listHeight: CGFloat {
        let count = CGFloat(results.count)
        let content = count * Self.rowHeight
            + max(0, count - 1) * Self.rowSpacing
            + Self.listPadding
        return min(content, Self.maxListHeight)
    }

    /// Recalculado a cada tecla, não a cada avaliação do `body` — a varredura passa por todas as
    /// transcrições, e `listHeight`, a lista e o teclado leem os resultados várias vezes por render.
    @State private var results: [VoizSearchResult] = []
    @State private var scanningArchive = false
    @State private var searchError: String?

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Sem termo digitado a paleta abre com os itens mais recentes, em vez de um painel vazio.
    private func runSearch() async {
        let capturedQuery = query
        let libraryRevision = library.revision
        let dictationStore = transcriptionViewModel.historyStore
        let capturedTranslationStore = translationStore
        let meetings = meetingViewModel.sessions
        searchError = nil
        selection = 0
        scrollTarget = nil
        guard isSearching else {
            scanningArchive = false
            results = VoizSearch.recents(dictations: dictationStore.entries, meetings: meetings, translations: capturedTranslationStore.entries)
            scrollTarget = results.first?.id
            return
        }
        results = []
        scanningArchive = true
        do {
            try await Task.sleep(for: .milliseconds(150))
            let found = try await VoizSearch.archivedResults(query: capturedQuery, meetings: meetings,
                dictationPage: { try dictationStore.page(afterID: $0) },
                translationPage: { try capturedTranslationStore.page(afterID: $0) })
            try Task.checkCancellation()
            guard query == capturedQuery, library.revision == libraryRevision else { return }
            results = found
            scanningArchive = false
            scrollTarget = found.first?.id
        } catch is CancellationError { return }
        catch {
            guard !Task.isCancelled, query == capturedQuery, library.revision == libraryRevision else { return }
            scanningArchive = false
            searchError = String(localized: "Não foi possível concluir a busca. Tente de novo.")
        }
    }

    var body: some View {
        ZStack {
            // Clicar fora fecha. O desfoque do conteúdo fica na `ContentView` — aqui só o
            // escurecimento, senão a própria paleta sairia borrada junto.
            Color.black.opacity(0.34)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            panel
        }
        .transition(.opacity)
        .onExitCommand(perform: onDismiss)
        .task(id: library.revision.uuidString + ":" + query) { await runSearch() }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            field

            Divider().overlay(VoizTheme.border)

            if results.isEmpty {
                emptyState
            } else {
                sectionHeader
                resultsList
            }

            Divider().overlay(VoizTheme.border)

            footer
        }
        .frame(width: 620)
        .background(VoizTheme.chatPanelBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(VoizTheme.borderStrong)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 40, y: 18)
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.downArrow) { move(1) }
    }

    private var sectionHeader: some View {
        HStack {
            Text(isSearching ? "Resultados" : "Recentes")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(VoizTheme.mutedText)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 2)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint(keys: ["↑", "↓"], label: "Navegar")
            hint(keys: ["↵"], label: "Abrir")
            hint(keys: ["esc"], label: "Fechar")
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func hint(keys: [String], label: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(VoizTheme.mutedText)
                    .frame(minWidth: 18, minHeight: 17)
                    .background(VoizTheme.elevatedBackground)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(VoizTheme.border))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(VoizTheme.mutedText)
        }
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundColor(VoizTheme.mutedText)

            TextField("Buscar em reuniões, ditados e traduções…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundColor(VoizTheme.primaryText)
                .focused($fieldFocused)
                .onSubmit(openSelected)


            if !query.isEmpty {
                Button(action: { query = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(VoizTheme.mutedText)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Limpar")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .onAppear {
            fieldFocused = true
        }
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Self.rowSpacing) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                        VoizSearchResultRow(
                            result: result,
                            isSelected: index == selection,
                            onHover: { selection = index },
                            action: { onOpen(result) }
                        )
                        .frame(height: Self.rowHeight)
                        .id(result.id)
                    }
                }
                .padding(Self.listPadding / 2)
            }
            // `ScrollView` é guloso no eixo de rolagem: com `maxHeight` a paleta ficaria sempre
            // com 380 pt, sobrando vazio embaixo de 2 ou 3 resultados. As linhas têm altura fixa
            // (título + trecho), então dá para calcular.
            .frame(height: listHeight)
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(target, anchor: .center)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            if scanningArchive { ProgressView().controlSize(.small) }
            Text(scanningArchive ? "Buscando em todo o histórico…" : searchError != nil ? "Busca incompleta" : isSearching ? "Nada encontrado" : "Nada gravado por aqui ainda")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(VoizTheme.primaryText)
            // Literals inside `??` become plain Strings; localize them explicitly.
            Text(searchError ?? (scanningArchive ? "" : isSearching
                 ? String(localized: "A busca cobre título, transcrição, resumo e notas.")
                 : String(localized: "Reuniões, ditados e traduções aparecem aqui.")))
                .font(.system(size: 11.5))
                .foregroundColor(VoizTheme.mutedText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    /// Move a seleção sem sair das bordas da lista. Devolve `.ignored` com a lista vazia para o
    /// campo de texto seguir tratando as setas normalmente.
    private func move(_ delta: Int) -> KeyPress.Result {
        let count = results.count
        guard count > 0 else { return .ignored }
        selection = min(max(selection + delta, 0), count - 1)
        scrollTarget = results[selection].id
        return .handled
    }

    private func openSelected() {
        guard results.indices.contains(selection) else { return }
        onOpen(results[selection])
    }
}

private struct VoizSearchResultRow: View {
    let result: VoizSearchResult
    let isSelected: Bool
    let onHover: () -> Void
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? VoizTheme.accent.opacity(0.22) : VoizTheme.elevatedBackground)
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: result.kind.systemImage)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(isSelected ? VoizTheme.accent : VoizTheme.mutedText)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundColor(VoizTheme.primaryText)
                        .lineLimit(1)
                    if !result.snippet.isEmpty {
                        Text(result.snippet)
                            .font(.system(size: 11.5))
                            .foregroundColor(VoizTheme.mutedText)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(result.kind.label)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(VoizTheme.mutedText)
                    Text(Self.dateFormatter.string(from: result.date))
                        .font(.system(size: 10.5))
                        .foregroundColor(VoizTheme.mutedText.opacity(0.8))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? VoizTheme.selectedBackground : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { if $0 { onHover() } }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .voizInterface
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}
