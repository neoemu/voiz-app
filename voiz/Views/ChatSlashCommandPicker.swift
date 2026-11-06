import SwiftUI

/// Seletor de comandos do chat, no estilo das "recipes" do Granola: abre ao digitar "/" no
/// composer (ou pelo botão "Comandos"), filtra pelo que vem depois da barra e devolve o comando
/// escolhido para o prompt.
///
/// É um overlay do próprio composer, e não um `Menu` nativo, porque precisa acompanhar a digitação
/// e responder a ↑ ↓ ↵ Tab Esc enquanto o foco continua no campo de texto. O `onSubmit` do campo
/// passa por aqui: com o seletor aberto, ↵ escolhe o comando; fechado, envia a mensagem.
struct ChatSlashCommandPickerModifier: ViewModifier {
    /// Espaço de coordenadas da área de conteúdo (declarado em `ContentView`). O composer mede o
    /// que há acima e abaixo de si dentro dele para escolher o lado e o teto do painel.
    nonisolated static let containerSpace = "voiz.chatSlashCommand.container"

    @Binding var prompt: String
    /// Aberto pelo botão, mesmo sem "/" no campo. Fecha na escolha, no Esc ou quando o usuário
    /// começa a digitar texto comum.
    @Binding var requested: Bool
    /// Lado preferido do composer para o painel. `.top` (acima) quando o composer está no rodapé
    /// da tela; `.bottom` (abaixo) quando ele está no topo, como na abertura do Chat. Se não
    /// couber desse lado e o outro tiver mais espaço, o painel vira.
    let edge: VerticalEdge
    let onSend: () -> Void

    @ObservedObject private var store = MeetingWorkspaceStore.shared
    @State private var selection = 0
    /// Prompt no momento do Esc: o seletor fica fechado até o texto mudar, senão a barra que
    /// continua no campo o reabriria no mesmo instante.
    @State private var dismissedPrompt: String?
    /// Pedido de abertura do editor. É `sheet(item:)` e não `sheet(isPresented:)` com um flag ao
    /// lado porque o conteúdo do sheet pode ser construído com o flag ainda antigo; com o item, o
    /// que abriu o editor é o que ele recebe.
    @State private var editorRequest: EditorRequest?

    private struct EditorRequest: Identifiable {
        /// Abre com um comando em branco no fim, caso do "Novo comando".
        let startsWithNewCommand: Bool
        var id: Bool { startsWithNewCommand }
    }
    @State private var room = Room()
    @State private var panelHeight: CGFloat = 0

    /// Espaço livre acima e abaixo do composer dentro da área de conteúdo.
    nonisolated private struct Room: Equatable, Sendable {
        var above: CGFloat = .greatestFiniteMagnitude
        var below: CGFloat = .greatestFiniteMagnitude

        init() {}

        init(_ proxy: GeometryProxy) {
            let space = NamedCoordinateSpace.named(ChatSlashCommandPickerModifier.containerSpace)
            guard let container = proxy.bounds(of: space) else { return }
            let frame = proxy.frame(in: space)
            above = max(0, frame.minY - container.minY)
            below = max(0, container.maxY - frame.maxY)
        }

        func available(at edge: VerticalEdge) -> CGFloat {
            edge == .top ? above : below
        }
    }

    /// Distância entre o composer e o painel, mais a folga até a borda da área de conteúdo.
    private static let gap: CGFloat = 8
    private static let margin: CGFloat = 12

    private var typedQuery: String? {
        ChatSlashCommand.query(in: prompt)
    }

    private var isPresented: Bool {
        if requested { return true }
        guard typedQuery != nil else { return false }
        return dismissedPrompt != prompt
    }

    private var matches: [MeetingAIRecipe] {
        ChatSlashCommand.matches(store.recipes, query: typedQuery ?? "")
    }

    /// Lado em que o painel abre de fato. Decide pela altura *natural* (sem teto), e não pela
    /// medida, para não oscilar: a medida depende do teto, que depende do lado.
    private var resolvedEdge: VerticalEdge {
        let needed = ChatSlashCommandPanel.naturalHeight(rows: matches.count) + Self.gap + Self.margin
        let other: VerticalEdge = edge == .top ? .bottom : .top
        if room.available(at: edge) >= needed || room.available(at: edge) >= room.available(at: other) {
            return edge
        }
        return other
    }

    private var availableHeight: CGFloat {
        max(0, room.available(at: resolvedEdge) - Self.gap - Self.margin)
    }

    func body(content: Content) -> some View {
        content
            .onSubmit(handleSubmit)
            .onKeyPress(.upArrow) { move(-1) }
            .onKeyPress(.downArrow) { move(1) }
            .onKeyPress(.tab) { choose() }
            .onKeyPress(.escape) { dismiss() }
            .onChange(of: prompt) { _, newValue in
                selection = 0
                if dismissedPrompt != newValue {
                    dismissedPrompt = nil
                }
                // Texto comum depois de abrir pelo botão: o usuário desistiu do comando.
                if requested && !newValue.isEmpty && ChatSlashCommand.query(in: newValue) == nil {
                    requested = false
                }
            }
            .onGeometryChange(for: Room.self) { Room($0) } action: { room = $0 }            .overlay(alignment: resolvedEdge == .top ? .top : .bottom) {
                if isPresented {
                    panel
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
                        // `alignmentGuide` não é respeitado por um overlay condicional; o
                        // deslocamento pela altura medida é.
                        .offset(y: resolvedEdge == .top ? -(panelHeight + Self.gap) : panelHeight + Self.gap)
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: resolvedEdge == .top ? .bottom : .top)))
                }
            }
            .animation(.easeOut(duration: 0.15), value: isPresented)
            .sheet(item: $editorRequest) { MeetingRecipeEditor(startsWithNewCommand: $0.startsWithNewCommand) }
    }

    private var panel: some View {
        ChatSlashCommandPanel(
            recipes: matches,
            query: typedQuery ?? "",
            selection: selection,
            edge: resolvedEdge,
            availableHeight: availableHeight,
            onHover: { selection = $0 },
            onSelect: apply,
            onNew: { editorRequest = EditorRequest(startsWithNewCommand: true) },
            onEdit: { editorRequest = EditorRequest(startsWithNewCommand: false) },
            onClose: { _ = dismiss() }
        )
    }

    private func handleSubmit() {
        if isPresented, matches.indices.contains(selection) {
            apply(matches[selection])
        } else if isPresented, matches.isEmpty {
            // Nada corresponde ao que foi digitado; ↵ manda o texto como está.
            requested = false
            onSend()
        } else {
            onSend()
        }
    }

    private func apply(_ recipe: MeetingAIRecipe) {
        prompt = ChatSlashCommand.apply(recipe, to: prompt)
        requested = false
        dismissedPrompt = nil
    }

    /// Move a seleção sem sair das bordas. Devolve `.ignored` com o seletor fechado para o campo
    /// de texto seguir tratando as setas normalmente.
    private func move(_ delta: Int) -> KeyPress.Result {
        guard isPresented, !matches.isEmpty else { return .ignored }
        selection = min(max(selection + delta, 0), matches.count - 1)
        return .handled
    }

    private func choose() -> KeyPress.Result {
        guard isPresented, matches.indices.contains(selection) else { return .ignored }
        apply(matches[selection])
        return .handled
    }

    private func dismiss() -> KeyPress.Result {
        guard isPresented else { return .ignored }
        requested = false
        dismissedPrompt = prompt
        return .handled
    }
}

extension View {
    /// Liga o seletor de comandos ("/") a um composer de chat. Deve envolver o campo de texto
    /// e ser aplicado **depois** do `clipShape` do composer, para o painel poder sair da caixa.
    func chatSlashCommandPicker(
        prompt: Binding<String>,
        requested: Binding<Bool>,
        edge: VerticalEdge = .top,
        onSend: @escaping () -> Void
    ) -> some View {
        modifier(ChatSlashCommandPickerModifier(prompt: prompt, requested: requested, edge: edge, onSend: onSend))
    }
}

/// Glifo "/" em caixinha: a marca dos comandos. É o mesmo no botão do composer, no cabeçalho do
/// painel e no menu das reuniões, para o usuário ligar a barra à feature sem precisar de texto.
/// Herda a cor do `foregroundColor` de quem o usa.
struct SlashCommandGlyph: View {
    var size: CGFloat = 16

    var body: some View {
        Text("/")
            .font(.system(size: size * 0.62, weight: .semibold, design: .rounded))
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .stroke(lineWidth: 1.2)
            )
    }
}

/// Botão "Comandos" dos composers do chat. Abre o mesmo painel que a barra abre — um só caminho
/// para os comandos, em vez de um `Menu` nativo aqui e um seletor ali.
struct ChatCommandsButton: View {
    var isActive = false
    var showsLabel = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                SlashCommandGlyph(size: 15)
                if showsLabel {
                    Text("Comandos")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .foregroundColor(isActive ? VoizTheme.accent : VoizTheme.mutedText)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(Text("Comandos — ou digite / no campo"))
    }
}

private struct ChatSlashCommandPanel: View {
    let recipes: [MeetingAIRecipe]
    let query: String
    let selection: Int
    let edge: VerticalEdge
    /// Teto para o painel inteiro. A lista encolhe (e rola) para caber; cabeçalho e rodapé não.
    let availableHeight: CGFloat
    let onHover: (Int) -> Void
    let onSelect: (MeetingAIRecipe) -> Void
    let onNew: () -> Void
    let onEdit: () -> Void
    let onClose: () -> Void

    @State private var headerHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0

    /// Cabeçalho + rodapé + as duas divisórias, medidos.
    private var chromeHeight: CGFloat {
        headerHeight + footerHeight + 2
    }

    private static let rowHeight: CGFloat = 50
    private static let rowSpacing: CGFloat = 2
    private static let listPadding: CGFloat = 12
    private static let maxVisibleRows = 6
    /// Cabeçalho + rodapé + divisórias. Estimativa só para decidir o lado antes da primeira
    /// medida; o teto real da lista usa a altura medida.
    private static let estimatedChromeHeight: CGFloat = 80
    private static let emptyStateHeight: CGFloat = 84

    /// Altura que o painel teria sem teto, para o composer decidir de que lado abrir.
    static func naturalHeight(rows: Int) -> CGFloat {
        estimatedChromeHeight + (rows == 0 ? emptyStateHeight : naturalListHeight(rows: rows))
    }

    private static func naturalListHeight(rows: Int) -> CGFloat {
        let count = CGFloat(min(rows, maxVisibleRows))
        return count * rowHeight + max(0, count - 1) * rowSpacing + listPadding
    }

    private var listHeight: CGFloat {
        let natural = Self.naturalListHeight(rows: recipes.count)
        let chrome = headerHeight > 0 && footerHeight > 0 ? chromeHeight : Self.estimatedChromeHeight
        // Pelo menos uma linha e meia: assim fica visível que há mais para rolar.
        let floor = Self.rowHeight * 1.5 + Self.listPadding
        return min(natural, max(floor, availableHeight - chrome))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }

            Divider().overlay(VoizTheme.border)

            if recipes.isEmpty {
                emptyState
            } else {
                list
            }

            Divider().overlay(VoizTheme.border)

            footer
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
        }
        .frame(maxWidth: .infinity)
        .background(VoizTheme.chatPanelBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(VoizTheme.borderStrong)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 28, y: edge == .top ? 12 : -6)
    }

    private var header: some View {
        HStack(spacing: 8) {
            SlashCommandGlyph(size: 15)
                .foregroundColor(VoizTheme.mutedText)
            Text("Comandos")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(VoizTheme.primaryText)

            Spacer()

            Button(action: onNew) {
                Label("Novo comando", systemImage: "plus")
            }
            .buttonStyle(GranolaPillButtonStyle())
            .focusable(false)

            Button(action: onEdit) {
                Label("Editar comandos…", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(GranolaPillButtonStyle())
            .focusable(false)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(VoizTheme.mutedText)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(GranolaIconButtonStyle())
            .focusable(false)
            .help("Fechar")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Self.rowSpacing) {
                    ForEach(Array(recipes.enumerated()), id: \.element.id) { index, recipe in
                        ChatSlashCommandRow(
                            recipe: recipe,
                            isSelected: index == selection,
                            onHover: { onHover(index) },
                            action: { onSelect(recipe) }
                        )
                        .frame(height: Self.rowHeight)
                        .id(recipe.id)
                    }
                }
                .padding(Self.listPadding / 2)
            }
            .scrollIndicators(.visible)
            // `ScrollView` é guloso: sem altura fixa o painel ocuparia tudo que o composer permite,
            // sobrando vazio embaixo de três comandos. As linhas têm altura fixa, então dá para calcular.
            .frame(height: listHeight)
            .onChange(of: selection) { _, index in
                guard recipes.indices.contains(index) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(recipes[index].id, anchor: .center)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("Nenhum comando corresponde a “/\(query)”")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(VoizTheme.primaryText)
                .lineLimit(1)
            Text("Enter envia o texto como está. Crie o seu em “Novo comando”.")
                .font(.system(size: 11.5))
                .foregroundColor(VoizTheme.mutedText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 22)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint(keys: ["↑", "↓"], label: "Navegar")
            hint(keys: ["↵"], label: "Escolher")
            hint(keys: ["esc"], label: "Fechar")
            Spacer()
            Text("Use /comando e complete com o que quiser")
                .font(.system(size: 11))
                .foregroundColor(VoizTheme.mutedText)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
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
}

private struct ChatSlashCommandRow: View {
    let recipe: MeetingAIRecipe
    let isSelected: Bool
    let onHover: () -> Void
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(recipe.title)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundColor(VoizTheme.primaryText)
                        .lineLimit(1)
                    Text(recipe.instruction)
                        .font(.system(size: 11.5))
                        .foregroundColor(VoizTheme.mutedText)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text("/" + recipe.command)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(VoizTheme.mutedText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? VoizTheme.selectedBackground : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { if $0 { onHover() } }
    }
}
