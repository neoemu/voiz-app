import Foundation
import Combine

/// Persiste os templates de resumo (defaults editáveis + customizados) em UserDefaults.
/// Semeia os defaults na primeira execução e garante que os built-ins sempre existam,
/// mesmo após updates do app que adicionem novos.
final class MeetingTemplateStore: ObservableObject {
    @Published private(set) var templates: [MeetingTemplate] = []

    private let defaults: UserDefaults
    private let storageKey = "voiz.meeting.templates"
    private let revisionKey = "voiz.meeting.templates.builtinRevision"
    private let localeKey = "voiz.meeting.templates.builtinLocale"
    /// Revisão do conteúdo embarcado. Ao subir esse número, os built-ins salvos são substituídos
    /// pelo conteúdo novo de fábrica — sem isso, quem já usou o app continuaria com os prompts
    /// antigos para sempre (só veria os modelos novos). Templates do usuário não são tocados.
    private static let builtInRevision = 2

    /// Idioma em que os built-ins foram semeados. Como nome, instruções e seções são persistidos
    /// já traduzidos, trocar o idioma do app deixaria prompts em português num app em inglês —
    /// então os built-ins são re-semeados no novo idioma (edições em built-ins se perdem aí).
    private static var currentLocaleTag: String {
        Bundle.main.preferredLocalizations.first ?? "pt-BR"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func template(withId id: String?) -> MeetingTemplate? {
        guard let id else { return nil }
        return templates.first(where: { $0.id == id })
    }

    /// Template padrão usado quando a sessão não tem um associado (primeiro da lista).
    var defaultTemplate: MeetingTemplate {
        templates.first ?? MeetingTemplate.daily
    }

    /// Cria/atualiza um template (upsert por id) e persiste.
    func save(_ template: MeetingTemplate) {
        if let index = templates.firstIndex(where: { $0.id == template.id }) {
            templates[index] = template
        } else {
            templates.append(template)
        }
        persist()
    }

    /// Cria um novo template customizado com um esqueleto inicial e o retorna.
    @discardableResult
    func createTemplate(name: String = String(localized: "Novo template")) -> MeetingTemplate {
        let template = MeetingTemplate(
            name: name,
            instructions: String(localized: """
            Descreva aqui o tipo de reunião e o que a IA deve fazer com o transcript — quanto mais \
            contexto, melhor o resumo. Ex.: "Participei de uma reunião de X. Registre Y e Z, em notas \
            curtas, sem inventar nada que não foi dito."
            """),
            sections: [
                MeetingTemplateSection(title: String(localized: "Resumo"), kind: .paragraph,
                                       hint: String(localized: "Panorama geral em 3-5 frases.")),
                MeetingTemplateSection(title: String(localized: "Pontos-chave"), kind: .bullets,
                                       hint: String(localized: "Principais tópicos discutidos.")),
                MeetingTemplateSection(title: String(localized: "Ações"), kind: .actionItems,
                                       hint: String(localized: "Tarefas combinadas, com responsável e prazo quando ditos."))
            ],
            isBuiltIn: false
        )
        templates.append(template)
        persist()
        return template
    }

    /// Copia um template existente (inclusive built-in) como um customizado editável — o caminho
    /// para partir de um modelo embarcado sem perder o original.
    @discardableResult
    func duplicate(_ template: MeetingTemplate) -> MeetingTemplate {
        var copy = template
        copy.id = UUID().uuidString
        copy.name = String(localized: "\(template.name) (cópia)")
        copy.isBuiltIn = false
        copy.sections = template.sections.map {
            MeetingTemplateSection(title: $0.title, kind: $0.kind, hint: $0.hint)
        }
        templates.append(copy)
        persist()
        return copy
    }

    /// Remove um template. Built-ins não podem ser apagados (só restaurados).
    func delete(_ template: MeetingTemplate) {
        guard !template.isBuiltIn else { return }
        templates.removeAll { $0.id == template.id }
        persist()
    }

    /// Restaura um built-in editado para o conteúdo de fábrica.
    func resetToDefault(_ template: MeetingTemplate) {
        guard let fresh = MeetingTemplate.defaults.first(where: { $0.id == template.id }) else { return }
        save(fresh)
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([MeetingTemplate].self, from: data),
              !decoded.isEmpty else {
            templates = MeetingTemplate.defaults
            persist()
            return
        }

        let storedRevision = defaults.integer(forKey: revisionKey)
        let storedLocale = defaults.string(forKey: localeKey)
        let needsRefresh = storedRevision < MeetingTemplateStore.builtInRevision
            || storedLocale != MeetingTemplateStore.currentLocaleTag
        templates = needsRefresh
            ? MeetingTemplateStore.refreshingBuiltIns(decoded)
            : MeetingTemplateStore.reconcilingBuiltIns(decoded)
        persist()
    }

    /// Garante que built-ins (inclusive novos, adicionados em updates) apareçam mesmo para
    /// quem já tem templates salvos, sem sobrescrever as edições do usuário nos já existentes.
    private static func reconcilingBuiltIns(_ stored: [MeetingTemplate]) -> [MeetingTemplate] {
        var result = stored
        for builtIn in MeetingTemplate.defaults where !result.contains(where: { $0.id == builtIn.id }) {
            result.append(builtIn)
        }
        return result
    }

    /// Migração de revisão: built-ins voltam ao conteúdo de fábrica (na ordem canônica) e os
    /// templates do usuário são preservados como estão, depois deles.
    private static func refreshingBuiltIns(_ stored: [MeetingTemplate]) -> [MeetingTemplate] {
        MeetingTemplate.defaults + stored.filter { !$0.isBuiltIn }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(templates) else { return }
        defaults.set(data, forKey: storageKey)
        defaults.set(MeetingTemplateStore.builtInRevision, forKey: revisionKey)
        defaults.set(MeetingTemplateStore.currentLocaleTag, forKey: localeKey)
    }
}
