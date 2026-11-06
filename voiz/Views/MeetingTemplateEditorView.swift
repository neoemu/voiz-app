import SwiftUI

/// Edição dos templates de resumo (Feature 4): nome, instruções (o prompt do usuário) e seções
/// dinâmicas. Built-ins são editáveis e restauráveis; customizados podem ser apagados.
/// As mudanças persistem automaticamente no `MeetingTemplateStore`.
///
/// Layout em dois painéis: à esquerda a lista de modelos (com busca e separação entre os seus e os
/// embarcados), à direita o modelo aberto. Antes tudo dividia a mesma coluna e um seletor no topo,
/// o que escondia quantos modelos existiam e fazia o editor parecer um formulário solto.
struct MeetingTemplateEditorView: View {
    @ObservedObject var store: MeetingTemplateStore
    /// 880 × 620 quando cabe; numa janela menor a folha encolhe para não passar da borda.
    var size = CGSize(width: 880, height: 620)
    @Environment(\.dismiss) private var dismiss

    @State private var selectedId: String
    @State private var draft: MeetingTemplate
    @State private var searchText = ""
    @State private var hoveredSectionId: String?
    /// O título só vira campo de texto depois de um clique. Como `TextField`, ele ganhava o foco
    /// inicial da sheet com o texto todo selecionado — a primeira tecla digitada renomeava o
    /// modelo aberto (inclusive um embarcado) sem o usuário pedir.
    @State private var isEditingName = false
    @FocusState private var nameFocused: Bool

    init(store: MeetingTemplateStore, size: CGSize = CGSize(width: 880, height: 620)) {
        self.size = size
        self.store = store
        let initial = store.templates.first ?? MeetingTemplate.daily
        _selectedId = State(initialValue: initial.id)
        _draft = State(initialValue: initial)
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

                detail
                    .frame(maxWidth: .infinity)
            }

            Rectangle()
                .fill(VoizTheme.border)
                .frame(height: 1)

            // Mesma barra do editor de comandos. Aqui só "Concluir": cada edição já foi salva
            // pelo `onChange(of: draft)`, então não existe um "Cancelar" a oferecer.
            HStack(spacing: 10) {
                Text("As alterações são salvas automaticamente.")
                    .font(.system(size: 11.5))
                    .foregroundColor(VoizTheme.mutedText)
                Spacer()
                Button("Concluir") { dismiss() }
                    .buttonStyle(VoizPrimaryButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: size.width, height: size.height)
        .background(VoizTheme.appBackground)
        .onChange(of: draft) { _, newValue in
            // Persiste cada edição do template selecionado.
            store.save(newValue)
        }
    }

    // MARK: - Painel esquerdo

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(VoizTheme.mutedText)
                Text("Modelos")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(VoizTheme.primaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 10)

            Button(action: addTemplate) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(VoizTheme.elevatedBackground)
                        .frame(width: 30, height: 30)
                        .overlay(
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(VoizTheme.primaryText)
                        )
                    Text("Novo modelo")
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

            searchField
                .padding(.horizontal, 14)
                .padding(.top, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    templateGroup(title: String(localized: "Meus modelos"), templates: filtered(builtIn: false))

                    // Built-ins agrupados por categoria (Rotina, Comercial, Produto…) — com ~14
                    // modelos embarcados, uma lista única viraria uma parede de nomes.
                    ForEach(visibleCategories, id: \.self) { category in
                        templateGroup(title: category, templates: filtered(builtIn: true, category: category))
                    }

                    if filtered(builtIn: false).isEmpty && filtered(builtIn: true).isEmpty {
                        Text("Nenhum modelo encontrado.")
                            .font(.system(size: 12))
                            .foregroundColor(VoizTheme.mutedText)
                            .padding(.horizontal, 14)
                            .padding(.top, 12)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 12)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(VoizTheme.mutedText)
            TextField("Buscar modelos…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(VoizTheme.primaryText)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(VoizTheme.appBackground.opacity(0.6))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(VoizTheme.border))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func templateGroup(title: String, templates: [MeetingTemplate]) -> some View {
        if !templates.isEmpty {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(VoizTheme.mutedText)
                .textCase(.uppercase)
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 4)

            ForEach(templates) { template in
                TemplateListRow(
                    template: template,
                    isSelected: template.id == selectedId,
                    action: { select(template.id) }
                )
            }
        }
    }

    /// Categorias de built-ins com pelo menos um modelo visível, na ordem canônica; categorias
    /// desconhecidas (de versões futuras ou edições manuais) entram no fim.
    private var visibleCategories: [String] {
        let present = filtered(builtIn: true).map(\.displayCategory)
        let known = MeetingTemplate.builtInCategoryOrder.filter { present.contains($0) }
        let extras = present.filter { !MeetingTemplate.builtInCategoryOrder.contains($0) }
        var seen = Set<String>()
        return (known + extras).filter { seen.insert($0).inserted }
    }

    private func filtered(builtIn: Bool, category: String? = nil) -> [MeetingTemplate] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return store.templates.filter { template in
            guard template.isBuiltIn == builtIn else { return false }
            if let category, template.displayCategory != category { return false }
            guard !query.isEmpty else { return true }
            return template.name.localizedCaseInsensitiveContains(query)
                || template.displayCategory.localizedCaseInsensitiveContains(query)
                || template.sections.contains { $0.title.localizedCaseInsensitiveContains(query) }
        }
    }

    // MARK: - Painel direito

    private var detail: some View {
        VStack(spacing: 0) {
            detailHeader

            Rectangle()
                .fill(VoizTheme.border)
                .frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    instructionsField
                    sectionsEditor
                    Spacer(minLength: 8)
                }
                .padding(24)
            }
        }
    }

    private var detailHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(draft.isBuiltIn
                      ? AnyShapeStyle(VoizTheme.elevatedBackground)
                      : AnyShapeStyle(VoizTheme.accentGradient))
                .frame(width: 34, height: 34)
                .overlay(
                    Image(systemName: draft.symbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(draft.isBuiltIn ? VoizTheme.accent : Color.white)
                )

            // Nome editável direto no título (um clique) — sem um campo "Nome" separado.
            nameField

            Spacer(minLength: 8)

            Menu {
                Button(action: duplicateTemplate) {
                    Label("Duplicar", systemImage: "doc.on.doc")
                }
                if draft.isBuiltIn {
                    Button(action: resetTemplate) {
                        Label("Restaurar padrão", systemImage: "arrow.counterclockwise")
                    }
                } else {
                    Divider()
                    Button(role: .destructive, action: deleteTemplate) {
                        Label("Apagar modelo", systemImage: "trash")
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
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var nameField: some View {
        let font = Font.system(size: 21, weight: .regular, design: .serif)

        if isEditingName {
            TextField("Sem nome", text: $draft.name)
                .textFieldStyle(.plain)
                .font(font)
                .foregroundColor(VoizTheme.primaryText)
                .focused($nameFocused)
                .onSubmit { isEditingName = false }
                .onChange(of: nameFocused) { _, focused in
                    if !focused { isEditingName = false }
                }
        } else {
            Text(draft.name.isEmpty ? String(localized: "Sem nome") : draft.name)
                .font(font)
                .foregroundColor(draft.name.isEmpty ? VoizTheme.mutedText : VoizTheme.primaryText)
                .lineLimit(1)
                .contentShape(Rectangle())
                .onTapGesture {
                    isEditingName = true
                    nameFocused = true
                }
                .help("Clique para renomear")
        }
    }

    private var instructionsField: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel("Contexto da reunião")
            Text("Descreva o tipo de reunião e o que a IA deve fazer com a transcrição. Quanto mais contexto, melhor o resumo.")
                .font(.system(size: 11.5))
                .foregroundColor(VoizTheme.mutedText)

            TextEditor(text: $draft.instructions)
                .font(.system(size: 14))
                .foregroundColor(VoizTheme.primaryText)
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .frame(height: 132)
                .padding(12)
                .background(VoizTheme.surfaceBackground)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(VoizTheme.border))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - Seções

    private var sectionsEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                fieldLabel("Seções")
                Spacer()
                Button(action: addSection) {
                    Label("Adicionar seção", systemImage: "plus")
                }
                .buttonStyle(GranolaPillButtonStyle())
            }

            if draft.sections.isEmpty {
                Text("Nenhuma seção. Adicione ao menos uma para o resumo.")
                    .font(.system(size: 12))
                    .foregroundColor(VoizTheme.mutedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 18)
                    .background(VoizTheme.surfaceBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(VoizTheme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                ForEach($draft.sections) { $section in
                    sectionRow($section)
                }
            }
        }
    }

    private func sectionRow(_ section: Binding<MeetingTemplateSection>) -> some View {
        let id = section.wrappedValue.id
        let isHovering = hoveredSectionId == id
        let index = draft.sections.firstIndex(where: { $0.id == id }) ?? 0

        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(VoizTheme.mutedText.opacity(isHovering ? 0.9 : 0.45))
                .frame(width: 14, height: 26)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("Título da seção", text: section.title)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(VoizTheme.primaryText)

                    Spacer(minLength: 0)

                    SettingsDropdown(
                        options: MeetingSectionKind.allCases.map { (value: $0, label: $0.displayName) },
                        selection: section.kind
                    )

                    // Reordenar/apagar só no hover — em repouso a linha fica limpa, como no
                    // editor de templates do Granola.
                    HStack(spacing: 4) {
                        Button(action: { moveSectionUp(id: id) }) {
                            Image(systemName: "arrow.up")
                        }
                        .buttonStyle(VoizTinyIconButtonStyle())
                        .disabled(index == 0)

                        Button(action: { moveSectionDown(id: id) }) {
                            Image(systemName: "arrow.down")
                        }
                        .buttonStyle(VoizTinyIconButtonStyle())
                        .disabled(index == draft.sections.count - 1)

                        Button(action: { deleteSection(id: id) }) {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(VoizTinyIconButtonStyle())
                    }
                    .opacity(isHovering ? 1 : 0)
                }

                TextField("Dica para a IA (opcional)", text: section.hint)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundColor(VoizTheme.mutedText)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(isHovering ? VoizTheme.elevatedBackground : VoizTheme.surfaceBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isHovering ? VoizTheme.borderStrong : VoizTheme.border)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hoveredSectionId = $0 ? id : (hoveredSectionId == id ? nil : hoveredSectionId) }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private func fieldLabel(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(VoizTheme.mutedText)
            .textCase(.uppercase)
    }

    // MARK: - Actions

    private func select(_ id: String) {
        selectedId = id
        isEditingName = false
        if let template = store.template(withId: id) {
            draft = template
        }
    }

    private func addTemplate() {
        let template = store.createTemplate()
        select(template.id)
        // Um modelo novo nasce como "Novo template" — já abre pronto para nomear.
        isEditingName = true
        nameFocused = true
    }

    private func duplicateTemplate() {
        let copy = store.duplicate(draft)
        select(copy.id)
    }

    private func deleteTemplate() {
        store.delete(draft)
        let fallback = store.templates.first ?? MeetingTemplate.daily
        select(fallback.id)
    }

    private func resetTemplate() {
        store.resetToDefault(draft)
        if let fresh = store.template(withId: selectedId) {
            draft = fresh
        }
    }

    private func addSection() {
        draft.sections.append(MeetingTemplateSection(title: String(localized: "Nova seção"), kind: .bullets))
    }

    private func deleteSection(id: String) {
        draft.sections.removeAll { $0.id == id }
    }

    private func moveSectionUp(id: String) {
        guard let index = draft.sections.firstIndex(where: { $0.id == id }), index > 0 else { return }
        draft.sections.swapAt(index, index - 1)
    }

    private func moveSectionDown(id: String) {
        guard let index = draft.sections.firstIndex(where: { $0.id == id }), index < draft.sections.count - 1 else { return }
        draft.sections.swapAt(index, index + 1)
    }
}

/// Linha da lista de modelos: ícone, nome e a origem (seu ou embarcado).
private struct TemplateListRow: View {
    let template: MeetingTemplate
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? VoizTheme.accent.opacity(0.22) : VoizTheme.elevatedBackground)
                    .frame(width: 30, height: 30)
                    .overlay(
                        Image(systemName: template.symbol)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(VoizTheme.accent)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(template.name.isEmpty ? String(localized: "Sem nome") : template.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isSelected ? VoizTheme.primaryText : VoizTheme.primaryText.opacity(0.85))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(VoizTheme.mutedText)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
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
        let origin = template.isBuiltIn ? template.displayCategory : String(localized: "Você")
        let sections = String(localized: "\(template.sections.count) seções")
        return "\(origin) • \(sections)"
    }

    private var background: Color {
        if isSelected { return VoizTheme.selectedBackground }
        if isHovering { return VoizTheme.hoverBackground }
        return .clear
    }
}
