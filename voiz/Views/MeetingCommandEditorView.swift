import SwiftUI

/// Editor dos comandos "/" do chat: lista à esquerda, formulário do comando escolhido à direita,
/// no mesmo desenho do editor de modelos de reunião. As edições ficam num rascunho e só vão para
/// o `MeetingWorkspaceStore` no "Salvar" — o atalho precisa ser único e válido, então salvar a
/// cada tecla deixaria a lista num estado que o chat não aceita.
///
/// Também é aberto pelo seletor "/" do chat (`ChatSlashCommandPicker`), por isso não é privado.
struct MeetingRecipeEditor: View {
    @Environment(\.dismiss) private var dismiss
    private let workspace: MeetingWorkspaceStore
    @State private var recipes: [MeetingAIRecipe]
    @State private var selectedID: UUID?
    /// Atalhos que o usuário editou à mão. Nos demais, o atalho segue o nome ("Preparar
    /// follow-up" → `preparar-follow-up`) até a pessoa mexer no campo.
    @State private var customizedCommands: Set<UUID> = []
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case name, command, instruction
    }

    /// `startsWithNewCommand` abre já num comando em branco, com o foco no nome, para o "Novo
    /// comando" do seletor "/" levar direto ao formulário.
    init(startsWithNewCommand: Bool = false) {
        let workspace = MeetingWorkspaceStore.shared
        self.workspace = workspace
        var recipes = workspace.recipes
        var selected = recipes.first?.id
        if startsWithNewCommand {
            let new = MeetingAIRecipe(command: "", title: "", instruction: "")
            recipes.append(new)
            selected = new.id
        }
        _recipes = State(initialValue: recipes)
        _selectedID = State(initialValue: selected)
        // Atalhos já existentes não devem ser reescritos ao renomear.
        _customizedCommands = State(initialValue: Set(recipes.filter { !$0.command.isEmpty }.map(\.id)))
    }

    private var selectedIndex: Int? {
        recipes.firstIndex { $0.id == selectedID }
    }

    private var isValid: Bool {
        recipes.allSatisfy { problems(of: $0).isEmpty }
    }

    /// Um comando em que a pessoa ainda não digitou nada. Fica inválido (não dá para salvar), mas
    /// não merece aviso em laranja antes de qualquer tecla.
    private static func isBlank(_ recipe: MeetingAIRecipe) -> Bool {
        recipe.title.isEmpty && recipe.command.isEmpty && recipe.instruction.isEmpty
    }

    /// Há algo a corrigir em um comando que a pessoa já começou a preencher.
    private var hasVisibleProblem: Bool {
        recipes.contains { !Self.isBlank($0) && !problems(of: $0).isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                list
                    .frame(width: 248)
                    .background(VoizTheme.sidebarBackground)

                Rectangle()
                    .fill(VoizTheme.border)
                    .frame(width: 1)

                if let index = selectedIndex {
                    detail(for: index)
                        .frame(maxWidth: .infinity)
                } else {
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            Rectangle()
                .fill(VoizTheme.border)
                .frame(height: 1)

            footer
        }
        .frame(width: 880, height: 620)
        .background(VoizTheme.appBackground)
        .onAppear {
            if let index = selectedIndex, recipes[index].title.isEmpty {
                focus = .name
            }
        }
    }

    // MARK: - Lista

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                SlashCommandGlyph(size: 15)
                    .foregroundColor(VoizTheme.mutedText)
                Text("Comandos")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(VoizTheme.primaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 10)

            Button(action: addCommand) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(VoizTheme.elevatedBackground)
                        .frame(width: 30, height: 30)
                        .overlay(
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(VoizTheme.primaryText)
                        )
                    Text("Novo comando")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(VoizTheme.primaryText)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(recipes) { recipe in
                            CommandListRow(
                                recipe: recipe,
                                isSelected: recipe.id == selectedID,
                                hasProblem: !Self.isBlank(recipe) && !problems(of: recipe).isEmpty,
                                action: { select(recipe.id) }
                            )
                            .id(recipe.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 12)
                }
                .onChange(of: selectedID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    // MARK: - Formulário

    private func detail(for index: Int) -> some View {
        let recipe = $recipes[index]
        let problems = problems(of: recipes[index])

        return VStack(spacing: 0) {
            detailHeader(for: recipes[index])

            Rectangle()
                .fill(VoizTheme.border)
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    fieldLabel("Nome")
                    TextField("Ex.: Preparar follow-up", text: recipe.title)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .foregroundColor(VoizTheme.primaryText)
                        .focused($focus, equals: .name)
                        .onSubmit { focus = .command }
                        .modifier(FieldBox())
                        .onChange(of: recipes[index].title) { _, title in
                            guard !customizedCommands.contains(recipes[index].id) else { return }
                            recipes[index].command = Self.slug(from: title)
                        }
                }

                VStack(alignment: .leading, spacing: 8) {
                    fieldLabel("Comando")
                    HStack(spacing: 6) {
                        Text("/")
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundColor(VoizTheme.mutedText)
                        TextField("", text: recipe.command, prompt: Text(verbatim: "preparar-follow-up"))
                            .textFieldStyle(.plain)
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(VoizTheme.primaryText)
                            .focused($focus, equals: .command)
                            .onSubmit { focus = .instruction }
                            .onChange(of: recipes[index].command) { old, new in
                                // Só conta como edição manual o que veio do campo em foco; a
                                // derivação do nome também passa por aqui.
                                if focus == .command, old != new {
                                    customizedCommands.insert(recipes[index].id)
                                }
                            }
                    }
                    .modifier(FieldBox())
                    if !Self.isBlank(recipes[index]), let problem = problems.first(where: { $0.isAboutCommand }) {
                        fieldHint(problem.message, isError: true)
                    } else {
                        fieldHint("Use /comando no chat ou durante uma reunião. Comandos usam letras minúsculas, números, - ou _.")
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    fieldLabel("Instrução")
                    ZStack(alignment: .topLeading) {
                        if recipes[index].instruction.isEmpty {
                            Text("Ex.: Liste as decisões confirmadas, separando propostas ainda abertas.")
                                .font(.system(size: 14))
                                .foregroundColor(VoizTheme.mutedText.opacity(0.7))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: recipe.instruction)
                            .font(.system(size: 14))
                            .foregroundColor(VoizTheme.primaryText)
                            .lineSpacing(3)
                            .scrollContentBackground(.hidden)
                            .focused($focus, equals: .instruction)
                    }
                    .frame(maxHeight: .infinity)
                    .modifier(FieldBox(vertical: 10))
                    fieldHint("O que a IA deve fazer ao receber este comando. O texto digitado depois do comando entra como complemento.")
                }
            }
            .padding(24)
        }
    }

    private func detailHeader(for recipe: MeetingAIRecipe) -> some View {
        HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(VoizTheme.accentGradient)
                .frame(width: 34, height: 34)
                .overlay(
                    SlashCommandGlyph(size: 18)
                        .foregroundColor(.white)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(recipe.title.isEmpty ? String(localized: "Novo comando") : recipe.title)
                    .font(.system(size: 21, weight: .regular, design: .serif))
                    .foregroundColor(recipe.title.isEmpty ? VoizTheme.mutedText : VoizTheme.primaryText)
                    .lineLimit(1)
                if !recipe.command.isEmpty {
                    Text("/" + recipe.command)
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundColor(VoizTheme.mutedText)
                }
            }

            Spacer(minLength: 8)

            Button(action: { remove(recipe.id) }) {
                Label("Remover comando", systemImage: "trash")
            }
            .buttonStyle(GranolaPillButtonStyle(destructive: true))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            SlashCommandGlyph(size: 28)
                .foregroundColor(VoizTheme.mutedText)
            Text("Nenhum comando")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(VoizTheme.primaryText)
            Text("Crie um comando para usar com / no chat.")
                .font(.system(size: 12))
                .foregroundColor(VoizTheme.mutedText)
            Button(action: addCommand) {
                Label("Novo comando", systemImage: "plus")
            }
            .buttonStyle(GranolaPillButtonStyle())
            .padding(.top, 6)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if hasVisibleProblem {
                Text("Preencha nome e instrução e use comandos válidos e únicos.")
                    .font(.system(size: 11.5))
                    .foregroundColor(.orange)
                    .lineLimit(1)
            }
            Spacer()
            Button("Cancelar") { dismiss() }
                .buttonStyle(GranolaPillButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("Salvar") {
                workspace.saveRecipes(recipes)
                dismiss()
            }
            .buttonStyle(VoizPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(!isValid)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Peças

    private func fieldLabel(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(VoizTheme.mutedText)
            .textCase(.uppercase)
    }

    private func fieldHint(_ text: LocalizedStringKey, isError: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundColor(isError ? .orange : VoizTheme.mutedText)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Caixa dos campos: mesma superfície e borda do editor de modelos.
    private struct FieldBox: ViewModifier {
        var vertical: CGFloat = 9

        func body(content: Content) -> some View {
            content
                .padding(.horizontal, 12)
                .padding(.vertical, vertical)
                .background(VoizTheme.surfaceBackground)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(VoizTheme.border))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - Ações

    private func select(_ id: UUID) {
        selectedID = id
        focus = nil
    }

    private func addCommand() {
        let new = MeetingAIRecipe(command: "", title: "", instruction: "")
        recipes.append(new)
        selectedID = new.id
        focus = .name
    }

    private func remove(_ id: UUID) {
        guard let index = recipes.firstIndex(where: { $0.id == id }) else { return }
        recipes.remove(at: index)
        customizedCommands.remove(id)
        if selectedID == id {
            selectedID = recipes.indices.contains(index) ? recipes[index].id : recipes.last?.id
        }
    }

    // MARK: - Validação

    private enum Problem {
        case emptyTitle, emptyInstruction, invalidCommand, duplicateCommand

        var isAboutCommand: Bool {
            self == .invalidCommand || self == .duplicateCommand
        }

        var message: LocalizedStringKey {
            switch self {
            case .invalidCommand: "Use só letras minúsculas, números, - ou _."
            case .duplicateCommand: "Já existe um comando com esse atalho."
            case .emptyTitle, .emptyInstruction: "Preencha nome e instrução e use comandos válidos e únicos."
            }
        }
    }

    private func problems(of recipe: MeetingAIRecipe) -> [Problem] {
        var result: [Problem] = []
        if recipe.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(.emptyTitle) }
        if recipe.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(.emptyInstruction) }
        if !MeetingAIRecipe.validCommand(recipe.command) {
            result.append(.invalidCommand)
        } else if recipes.contains(where: { $0.id != recipe.id && $0.command == recipe.command }) {
            result.append(.duplicateCommand)
        }
        return result
    }

    /// Atalho sugerido a partir do nome: sem acentos, minúsculo, espaços viram "-", e só o que
    /// `validCommand` aceita ("Preparar follow-up" → "preparar-follow-up").
    static func slug(from title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        var result = ""
        var pendingSeparator = false
        for scalar in folded.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "_" {
                if pendingSeparator, !result.isEmpty { result.append("-") }
                pendingSeparator = false
                result.unicodeScalars.append(scalar)
            } else if scalar == "-" || scalar == " " {
                pendingSeparator = true
            }
        }
        return String(result.prefix(32))
    }
}

private struct CommandListRow: View {
    let recipe: MeetingAIRecipe
    let isSelected: Bool
    let hasProblem: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? VoizTheme.accent.opacity(0.22) : VoizTheme.elevatedBackground)
                    .frame(width: 30, height: 30)
                    .overlay(
                        SlashCommandGlyph(size: 15)
                            .foregroundColor(isSelected ? VoizTheme.primaryText : VoizTheme.mutedText)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(recipe.title.isEmpty ? String(localized: "Novo comando") : recipe.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(recipe.title.isEmpty ? VoizTheme.mutedText : VoizTheme.primaryText.opacity(isSelected ? 1 : 0.85))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(VoizTheme.mutedText)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if hasProblem {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                        .help("Preencha nome e instrução e use comandos válidos e únicos.")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var subtitle: String {
        let command = recipe.command.isEmpty ? "/…" : "/" + recipe.command
        let firstLine = recipe.instruction
            .split(whereSeparator: \.isNewline)
            .first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return firstLine.isEmpty ? command : "\(command) · \(firstLine)"
    }

    private var background: Color {
        if isSelected { return VoizTheme.selectedBackground }
        if isHovering { return VoizTheme.hoverBackground }
        return .clear
    }
}
