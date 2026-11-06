import Foundation

/// Tipo de uma seção de resumo. Define **como** o conteúdo é pedido ao LLM (formato JSON)
/// e **como** é renderizado na UI. É a base das seções dinâmicas da Feature 4.
enum MeetingSectionKind: String, Codable, CaseIterable, Identifiable {
    case paragraph
    case bullets
    case actionItems

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .paragraph: return String(localized: "Parágrafo")
        case .bullets: return String(localized: "Tópicos")
        case .actionItems: return String(localized: "Ações")
        }
    }

    /// Descrição do formato esperado no JSON, usada ao montar o prompt do resumo.
    var jsonShapeHint: String {
        switch self {
        case .paragraph: return "uma string (texto corrido)"
        case .bullets: return "uma lista de strings"
        case .actionItems: return "uma lista de objetos {\"text\": string, \"assignee\": string|null, \"dueDate\": string|null}"
        }
    }

    /// Exemplo do valor JSON desse tipo, usado no esqueleto de exemplo do prompt.
    var jsonExample: String {
        switch self {
        case .paragraph: return "\"...\""
        case .bullets: return "[\"...\"]"
        case .actionItems: return "[{\"text\": \"...\", \"assignee\": null, \"dueDate\": null}]"
        }
    }
}

/// Uma seção declarada por um template: título, tipo e uma dica opcional para o LLM.
struct MeetingTemplateSection: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var kind: MeetingSectionKind
    /// Orientação extra para o LLM sobre o que entra nessa seção (opcional).
    var hint: String

    init(id: String = UUID().uuidString, title: String, kind: MeetingSectionKind, hint: String = "") {
        self.id = id
        self.title = title
        self.kind = kind
        self.hint = hint
    }
}

/// Template de resumo: nome + instruções (prompt editável pelo usuário) + seções dinâmicas.
/// Substitui o `switch` por `sessionType` — o resumo passa a ser data-driven, alinhado ao
/// posicionamento "o usuário é dono do caminho do dado" (o prompt é dele, roda no endpoint dele).
struct MeetingTemplate: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var instructions: String
    var sections: [MeetingTemplateSection]
    /// Embarcado com o app. Built-ins não podem ser apagados, só restaurados ao padrão.
    var isBuiltIn: Bool
    /// Emoji salvo com o modelo. Não aparece mais na interface: serve de chave para `symbol`,
    /// e as cópias de um modelo do Voiz o herdam. Opcional: templates salvos antes desta
    /// versão (e os criados pelo usuário) decodificam como nil e caem no ícone padrão.
    var icon: String?
    /// Agrupamento na lista de modelos ("Rotina", "Comercial", …). Também opcional por
    /// compatibilidade com o que já está persistido em UserDefaults.
    var category: String?

    init(
        id: String = UUID().uuidString,
        name: String,
        instructions: String,
        sections: [MeetingTemplateSection],
        isBuiltIn: Bool = false,
        icon: String? = nil,
        category: String? = nil
    ) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.sections = sections
        self.isBuiltIn = isBuiltIn
        self.icon = icon
        self.category = category
    }

    /// Tipo de sessão associado, mantido para rótulos/ícones legados (e contexto do chat).
    var sessionType: MeetingSessionType {
        id == MeetingTemplate.interviewID ? .interview : .meeting
    }

    /// SF Symbol do modelo nas listas e no editor, no lugar do emoji.
    var symbol: String {
        if let icon, let symbol = Self.symbols[icon] { return symbol }
        return isBuiltIn ? "sparkles" : "doc.text"
    }

    static let symbols: [String: String] = [
        "🏃": "figure.walk",
        "👥": "person.2",
        "📅": "calendar",
        "📝": "note.text",
        "💰": "dollarsign.circle",
        "❤️": "heart",
        "🔍": "magnifyingglass",
        "🗺️": "map",
        "🔁": "arrow.triangle.2.circlepath",
        "🛠️": "wrench.and.screwdriver",
        "💡": "lightbulb",
        "💼": "briefcase",
        "📊": "chart.bar",
        "🎓": "graduationcap"
    ]

    /// Grupo para exibição na lista de modelos.
    var displayCategory: String {
        if let category, !category.isEmpty { return category }
        return isBuiltIn ? String(localized: "Do Voiz") : String(localized: "Meus modelos")
    }

    /// Rótulo para dropdowns e menus: só o nome, como nos menus do macOS.
    var menuLabel: String { name }
}

extension MeetingTemplate {
    static let dailyID = "builtin.daily"
    static let interviewID = "builtin.interview"
    static let salesID = "builtin.sales"

    /// Categorias dos built-ins, na ordem em que aparecem na lista de modelos.
    static var builtInCategoryOrder: [String] {
        [
            String(localized: "Rotina"),
            String(localized: "Comercial"),
            String(localized: "Produto"),
            String(localized: "Pessoas"),
            String(localized: "Liderança"),
            String(localized: "Aprendizado")
        ]
    }

    /// Templates embarcados — editáveis (não caixa-preta) e restauráveis ao padrão.
    /// A ordem manda na lista e no dropdown; o primeiro é o padrão de novas sessões.
    static var defaults: [MeetingTemplate] {
        [
            daily,
            oneOnOne,
            teamMeeting,
            generalNotes,
            sales,
            accountReview,
            userResearch,
            projectKickoff,
            retro,
            techReview,
            brainstorm,
            interview,
            leadershipUpdate,
            lecture
        ]
    }

    /// Açúcar para declarar seções sem repetir o nome do tipo em cada linha.
    private static func section(
        _ id: String,
        _ title: String,
        _ kind: MeetingSectionKind,
        _ hint: String
    ) -> MeetingTemplateSection {
        MeetingTemplateSection(id: id, title: title, kind: kind, hint: hint)
    }

    // MARK: - Rotina

    static var daily: MeetingTemplate {
        MeetingTemplate(
            id: dailyID,
            name: String(localized: "Daily / Stand-up"),
            instructions: String(localized: """
            Participei de uma daily do time. O objetivo é registrar, pessoa por pessoa, o que foi \
            concluído desde o último encontro, o que está em andamento agora e o que está travando.
            Escreva notas curtas e diretas, sem enfeite — quem não falou não aparece no resumo.
            """),
            sections: [
                section("summary", String(localized: "Resumo"), .paragraph,
                        String(localized: "Panorama em 2-4 frases: o que dominou a conversa e se há algo em risco.")),
                section("updates", String(localized: "Atualizações"), .bullets,
                        String(localized: "Uma linha por participante, no formato \"Nome — concluído / em andamento / próximo passo\". Use apenas o que a pessoa disse.")),
                section("blockers", String(localized: "Bloqueios"), .bullets,
                        String(localized: "Impedimentos e dependências: quem está travado, no quê e do que precisa para destravar.")),
                section("decisions", String(localized: "Decisões"), .bullets,
                        String(localized: "Decisões fechadas na call. Se nada foi decidido, devolva a lista vazia.")),
                section("actionItems", String(localized: "Ações"), .actionItems,
                        String(localized: "Tarefas combinadas, com responsável e prazo somente quando ditos.")),
                section("followUps", String(localized: "Follow-ups"), .bullets,
                        String(localized: "Assuntos adiados para fora da daily (\"levar pro 1:1\", \"discutir depois\")."))
            ],
            isBuiltIn: true,
            icon: "🏃",
            category: String(localized: "Rotina")
        )
    }

    static var oneOnOne: MeetingTemplate {
        MeetingTemplate(
            id: "builtin.oneOnOne",
            name: String(localized: "1:1"),
            instructions: String(localized: """
            Participei de uma conversa 1:1. Registre o que a pessoa trouxe, os feedbacks trocados e \
            os combinados, em tom neutro e respeitoso.
            Este é um registro privado: preserve nuances, não julgue a pessoa e não amplie nada além \
            do que foi dito.
            """),
            sections: [
                section("summary", String(localized: "Resumo"), .paragraph,
                        String(localized: "Como a pessoa está e o que a conversa cobriu, em 3-5 frases.")),
                section("topics", String(localized: "Temas trazidos"), .bullets,
                        String(localized: "Assuntos levantados pela pessoa: prioridades, carga de trabalho, relações do time, contexto pessoal quando relevante.")),
                section("feedback", String(localized: "Feedbacks"), .bullets,
                        String(localized: "Feedbacks trocados nos dois sentidos — deixe claro quem deu e quem recebeu.")),
                section("growth", String(localized: "Carreira e desenvolvimento"), .bullets,
                        String(localized: "Objetivos, interesses, aprendizados e o que a pessoa quer fazer diferente.")),
                section("support", String(localized: "Onde precisa de apoio"), .bullets,
                        String(localized: "Bloqueios a remover, decisões pendentes do gestor e apoio pedido explicitamente.")),
                section("actionItems", String(localized: "Combinados"), .actionItems,
                        String(localized: "Compromissos dos dois lados, com responsável e prazo quando ditos.")),
                section("nextTime", String(localized: "Retomar no próximo"), .bullets,
                        String(localized: "O que ficou em aberto para o próximo 1:1."))
            ],
            isBuiltIn: true,
            icon: "👥",
            category: String(localized: "Rotina")
        )
    }

    static var teamMeeting: MeetingTemplate {
        MeetingTemplate(
            id: "builtin.teamMeeting",
            name: String(localized: "Reunião de equipe"),
            instructions: String(localized: """
            Participei de uma reunião de equipe (semanal ou quinzenal). Registre avisos, andamento \
            das frentes, riscos e o que ficou combinado.
            Escreva para alguém que faltou: cada tópico precisa fazer sentido sozinho, sem o áudio.
            """),
            sections: [
                section("summary", String(localized: "Resumo"), .paragraph,
                        String(localized: "O que a reunião cobriu e o estado geral das frentes, em 3-5 frases.")),
                section("announcements", String(localized: "Avisos"), .bullets,
                        String(localized: "Novidades, recados e anúncios do começo da call.")),
                section("updates", String(localized: "Andamento por frente"), .bullets,
                        String(localized: "Estado de cada projeto/frente citado e o que mudou desde a última reunião.")),
                section("risks", String(localized: "Riscos e atrasos"), .bullets,
                        String(localized: "Riscos, atrasos e dependências, com o impacto quando mencionado.")),
                section("decisions", String(localized: "Decisões"), .bullets,
                        String(localized: "Decisões tomadas e, quando dito, quem decidiu.")),
                section("actionItems", String(localized: "Ações"), .actionItems,
                        String(localized: "Tarefas combinadas, com responsável e prazo quando ditos.")),
                section("followUps", String(localized: "Follow-ups"), .bullets,
                        String(localized: "Temas que ficaram para a próxima reunião."))
            ],
            isBuiltIn: true,
            icon: "📅",
            category: String(localized: "Rotina")
        )
    }

    static var generalNotes: MeetingTemplate {
        MeetingTemplate(
            id: "builtin.generalNotes",
            name: String(localized: "Notas gerais"),
            instructions: String(localized: """
            Participei de uma conversa de trabalho sem formato definido. Faça um registro fiel e \
            enxuto: sobre o que se falou, o que ficou decidido e o que alguém precisa fazer depois.
            Se a conversa não cobrir uma seção, deixe-a vazia em vez de forçar conteúdo.
            """),
            sections: [
                section("summary", String(localized: "Resumo"), .paragraph,
                        String(localized: "Do que se tratou a conversa e onde ela chegou, em 3-5 frases.")),
                section("keyPoints", String(localized: "Pontos-chave"), .bullets,
                        String(localized: "Principais tópicos discutidos, um por linha, com o contexto necessário.")),
                section("decisions", String(localized: "Decisões"), .bullets,
                        String(localized: "O que ficou decidido, mesmo que informalmente.")),
                section("openQuestions", String(localized: "Perguntas em aberto"), .bullets,
                        String(localized: "Dúvidas levantadas que ficaram sem resposta.")),
                section("actionItems", String(localized: "Ações"), .actionItems,
                        String(localized: "Tarefas combinadas, com responsável e prazo quando ditos."))
            ],
            isBuiltIn: true,
            icon: "📝",
            category: String(localized: "Rotina")
        )
    }

    // MARK: - Comercial

    static var sales: MeetingTemplate {
        MeetingTemplate(
            id: salesID,
            name: String(localized: "Vendas: descoberta"),
            instructions: String(localized: """
            Participei de uma call de vendas de descoberta. O objetivo é entender o contexto do \
            cliente e qualificar a oportunidade: dor, impacto, processo de decisão, orçamento e prazo.
            Descreva a dor com as palavras do próprio cliente e nunca transforme uma suposição nossa \
            em fato dito por ele.
            """),
            sections: [
                section("summary", String(localized: "Resumo"), .paragraph,
                        String(localized: "Empresa, quem estava na call e por que estão conversando com a gente agora.")),
                section("context", String(localized: "Situação atual"), .bullets,
                        String(localized: "Como resolvem isso hoje: processo, ferramentas e time envolvido.")),
                section("needs", String(localized: "Dores e necessidades"), .bullets,
                        String(localized: "Dores levantadas e o impacto no negócio, com números quando citados.")),
                section("objections", String(localized: "Objeções"), .bullets,
                        String(localized: "Objeções, preocupações e riscos citados — e como foram respondidos.")),
                section("decisionProcess", String(localized: "Processo de decisão"), .bullets,
                        String(localized: "Quem decide, orçamento, prazo, critérios de escolha e concorrentes mencionados.")),
                section("nextSteps", String(localized: "Próximos passos"), .actionItems,
                        String(localized: "Ações para avançar o negócio, com responsável e data quando ditos.")),
                section("followUps", String(localized: "Follow-ups"), .bullets,
                        String(localized: "O que prometemos enviar e o que confirmar no próximo contato."))
            ],
            isBuiltIn: true,
            icon: "💰",
            category: String(localized: "Comercial")
        )
    }

    static var accountReview: MeetingTemplate {
        MeetingTemplate(
            id: "builtin.accountReview",
            name: String(localized: "Cliente: acompanhamento"),
            instructions: String(localized: """
            Participei de uma reunião de acompanhamento com um cliente já ativo. Registre como está \
            o uso, o que está funcionando, os pontos de atrito e os sinais de renovação ou expansão.
            Separe com clareza o que o cliente disse do que é leitura nossa.
            """),
            sections: [
                section("summary", String(localized: "Resumo"), .paragraph,
                        String(localized: "Situação da conta, tom da conversa e recado principal em 3-5 frases.")),
                section("wins", String(localized: "Resultados e valor"), .bullets,
                        String(localized: "O que está funcionando e o valor percebido, com números ou citações quando houver.")),
                section("issues", String(localized: "Problemas e atritos"), .bullets,
                        String(localized: "Reclamações, bugs e dificuldades, com a urgência quando mencionada.")),
                section("requests", String(localized: "Pedidos de produto"), .bullets,
                        String(localized: "Melhorias e funcionalidades pedidas, sempre com o motivo por trás.")),
                section("renewalSignals", String(localized: "Sinais de renovação/risco"), .bullets,
                        String(localized: "Indícios de expansão, renovação ou churn — inclusive ressalvas e hesitações.")),
                section("actionItems", String(localized: "Ações"), .actionItems,
                        String(localized: "Compromissos assumidos com o cliente, com responsável e prazo quando ditos.")),
                section("followUps", String(localized: "Follow-ups"), .bullets,
                        String(localized: "O que retomar no próximo contato."))
            ],
            isBuiltIn: true,
            icon: "❤️",
            category: String(localized: "Comercial")
        )
    }

    // MARK: - Produto

    static var userResearch: MeetingTemplate {
        MeetingTemplate(
            id: "builtin.userResearch",
            name: String(localized: "Pesquisa com usuário"),
            instructions: String(localized: """
            Conduzi uma entrevista de pesquisa com um usuário. O objetivo é capturar comportamento \
            real, não opinião sobre funcionalidades: o que a pessoa faz hoje, onde dói e o que já tentou.
            Prefira citações diretas às minhas conclusões e mantenha a linguagem do próprio usuário.
            """),
            sections: [
                section("summary", String(localized: "Resumo"), .paragraph,
                        String(localized: "Perfil da pessoa, contexto de uso e a impressão principal da conversa.")),
                section("currentWorkflow", String(localized: "Como faz hoje"), .bullets,
                        String(localized: "O fluxo atual passo a passo, com as ferramentas citadas.")),
                section("painPoints", String(localized: "Dores"), .bullets,
                        String(localized: "Frustrações em ordem de intensidade, com o impacto prático de cada uma.")),
                section("quotes", String(localized: "Citações"), .bullets,
                        String(localized: "Falas literais marcantes, entre aspas, com o nome de quem disse quando conhecido.")),
                section("desiredOutcomes", String(localized: "O que quer alcançar"), .bullets,
                        String(localized: "O resultado desejado e como a pessoa definiria \"resolvido\".")),
                section("productIdeas", String(localized: "Hipóteses de produto"), .bullets,
                        String(localized: "Ideias que a conversa sugere — marque explicitamente como interpretação, não como fala do usuário.")),
                section("actionItems", String(localized: "Próximos passos"), .actionItems,
                        String(localized: "Ações de pesquisa combinadas, com responsável quando dito."))
            ],
            isBuiltIn: true,
            icon: "🔍",
            category: String(localized: "Produto")
        )
    }

    static var projectKickoff: MeetingTemplate {
        MeetingTemplate(
            id: "builtin.projectKickoff",
            name: String(localized: "Kickoff / planejamento"),
            instructions: String(localized: """
            Participei de um kickoff/planejamento de projeto. Registre o que vamos construir, por quê, \
            o escopo acordado, o que ficou de fora, prazos e quem é dono de cada parte.
            Escreva como um documento que o time vai consultar depois, não como ata cronológica.
            """),
            sections: [
                section("summary", String(localized: "Resumo"), .paragraph,
                        String(localized: "Objetivo do projeto e por que agora, em 3-5 frases.")),
                section("goals", String(localized: "Objetivos e sucesso"), .bullets,
                        String(localized: "Objetivos e critérios de sucesso, com métrica quando citada.")),
                section("scope", String(localized: "Escopo"), .bullets,
                        String(localized: "O que está dentro do escopo desta fase.")),
                section("outOfScope", String(localized: "Fora do escopo"), .bullets,
                        String(localized: "O que foi explicitamente descartado ou adiado.")),
                section("timeline", String(localized: "Prazos e marcos"), .bullets,
                        String(localized: "Datas e marcos citados, com as dependências entre eles.")),
                section("risks", String(localized: "Riscos e premissas"), .bullets,
                        String(localized: "Riscos, incógnitas e premissas assumidas na conversa.")),
                section("owners", String(localized: "Responsáveis"), .bullets,
                        String(localized: "Quem ficou dono de cada frente, apenas conforme dito na call.")),
                section("actionItems", String(localized: "Ações"), .actionItems,
                        String(localized: "Primeiras tarefas combinadas, com responsável e prazo quando ditos."))
            ],
            isBuiltIn: true,
            icon: "🗺️",
            category: String(localized: "Produto")
        )
    }

    static var retro: MeetingTemplate {
        MeetingTemplate(
            id: "builtin.retro",
            name: String(localized: "Retrospectiva"),
            instructions: String(localized: """
            Participei de uma retrospectiva de time. Registre o que funcionou, o que não funcionou e \
            os experimentos combinados para o próximo ciclo.
            Mantenha o foco em processo, não em culpa: descreva o problema e o efeito, não o culpado.
            """),
            sections: [
                section("summary", String(localized: "Resumo"), .paragraph,
                        String(localized: "Como foi o ciclo e o clima da retro, em 3-5 frases.")),
                section("wentWell", String(localized: "O que funcionou"), .bullets,
                        String(localized: "Pontos positivos que o time quer manter.")),
                section("wentWrong", String(localized: "O que não funcionou"), .bullets,
                        String(localized: "Problemas relatados, cada um com o efeito prático que teve.")),
                section("rootCauses", String(localized: "Causas apontadas"), .bullets,
                        String(localized: "Causas levantadas pelo time — só o que foi dito, sem diagnóstico próprio.")),
                section("experiments", String(localized: "Experimentos do próximo ciclo"), .bullets,
                        String(localized: "Mudanças de processo acordadas e o que se espera de cada uma.")),
                section("actionItems", String(localized: "Ações"), .actionItems,
                        String(localized: "Ações com responsável e prazo quando ditos."))
            ],
            isBuiltIn: true,
            icon: "🔁",
            category: String(localized: "Produto")
        )
    }

    static var techReview: MeetingTemplate {
        MeetingTemplate(
            id: "builtin.techReview",
            name: String(localized: "Discussão técnica"),
            instructions: String(localized: """
            Participei de uma discussão técnica (arquitetura, design review ou depuração). Registre o \
            problema, as alternativas com seus trade-offs, a decisão e o que ficou em aberto.
            Preserve nomes de serviços, arquivos, comandos e termos técnicos exatamente como foram \
            falados, mesmo que soem estranhos.
            """),
            sections: [
                section("summary", String(localized: "Resumo"), .paragraph,
                        String(localized: "Qual problema técnico estava em discussão e onde a conversa chegou.")),
                section("context", String(localized: "Contexto técnico"), .bullets,
                        String(localized: "Sistemas, componentes e restrições envolvidos.")),
                section("options", String(localized: "Alternativas avaliadas"), .bullets,
                        String(localized: "Cada opção discutida com os prós e contras citados.")),
                section("decision", String(localized: "Decisão"), .paragraph,
                        String(localized: "A decisão técnica e o motivo. Se não houve decisão, diga isso explicitamente.")),
                section("risks", String(localized: "Riscos e dívida"), .bullets,
                        String(localized: "Riscos técnicos, dívida assumida e o que pode dar errado.")),
                section("openQuestions", String(localized: "Em aberto"), .bullets,
                        String(localized: "Dúvidas técnicas pendentes e o que precisa ser investigado.")),
                section("actionItems", String(localized: "Ações"), .actionItems,
                        String(localized: "Tarefas técnicas combinadas, com responsável quando dito."))
            ],
            isBuiltIn: true,
            icon: "🛠️",
            category: String(localized: "Produto")
        )
    }

    static var brainstorm: MeetingTemplate {
        MeetingTemplate(
            id: "builtin.brainstorm",
            name: String(localized: "Brainstorm"),
            instructions: String(localized: """
            Participei de uma sessão de brainstorm. Registre todas as ideias levantadas sem filtrar \
            pela minha opinião, agrupando as parecidas por tema.
            Separe o que empolgou o grupo do que foi descartado e não conclua nada que o grupo não \
            concluiu.
            """),
            sections: [
                section("summary", String(localized: "Resumo"), .paragraph,
                        String(localized: "Pergunta ou desafio que originou a sessão e onde o grupo chegou.")),
                section("ideas", String(localized: "Ideias"), .bullets,
                        String(localized: "Todas as ideias, agrupadas por tema, com o autor quando identificado.")),
                section("promising", String(localized: "Ideias promissoras"), .bullets,
                        String(localized: "As que ganharam tração no grupo e o motivo do entusiasmo.")),
                section("discarded", String(localized: "Descartadas"), .bullets,
                        String(localized: "Ideias rejeitadas e o motivo citado para o descarte.")),
                section("openQuestions", String(localized: "Para investigar"), .bullets,
                        String(localized: "O que precisa ser validado antes de decidir.")),
                section("actionItems", String(localized: "Ações"), .actionItems,
                        String(localized: "Próximos passos combinados, com responsável quando dito."))
            ],
            isBuiltIn: true,
            icon: "💡",
            category: String(localized: "Produto")
        )
    }

    // MARK: - Pessoas

    static var interview: MeetingTemplate {
        MeetingTemplate(
            id: interviewID,
            name: String(localized: "Entrevista de candidato"),
            instructions: String(localized: """
            Participei de uma entrevista com um candidato. Avalie de forma equilibrada e baseada em \
            evidências: cada sinal precisa vir de algo que o candidato disse, não de impressão vaga.
            Separe fato de interpretação, evite adjetivar a pessoa e registre também o que ficou sem \
            resposta.
            """),
            sections: [
                section("summary", String(localized: "Resumo"), .paragraph,
                        String(localized: "Vaga, etapa do processo e impressão geral em 3-5 frases.")),
                section("background", String(localized: "Trajetória"), .bullets,
                        String(localized: "Experiências relevantes, com escopo, tamanho de time e resultados quando citados.")),
                section("strengths", String(localized: "Pontos fortes"), .bullets,
                        String(localized: "Cada ponto forte ancorado em um exemplo dado pelo candidato.")),
                section("concerns", String(localized: "Riscos e lacunas"), .bullets,
                        String(localized: "Dúvidas e lacunas, sempre com a evidência que as sustenta.")),
                section("candidateQuestions", String(localized: "Perguntas do candidato"), .bullets,
                        String(localized: "O que o candidato perguntou e o que isso indica sobre o interesse dele.")),
                section("logistics", String(localized: "Expectativas e logística"), .bullets,
                        String(localized: "Pretensão salarial, disponibilidade, modelo de trabalho e localização — apenas se ditos.")),
                section("actionItems", String(localized: "Próximos passos"), .actionItems,
                        String(localized: "Etapas seguintes do processo, com responsável e prazo quando ditos.")),
                section("followUps", String(localized: "Perguntar depois"), .bullets,
                        String(localized: "O que investigar na próxima etapa ou nas referências."))
            ],
            isBuiltIn: true,
            icon: "💼",
            category: String(localized: "Pessoas")
        )
    }

    // MARK: - Liderança

    static var leadershipUpdate: MeetingTemplate {
        MeetingTemplate(
            id: "builtin.leadershipUpdate",
            name: String(localized: "Status para liderança"),
            instructions: String(localized: """
            Participei de uma reunião de status com liderança ou board. Registre em nível executivo: \
            números, decisões tomadas e pedidas, riscos e pedidos de apoio.
            Corte detalhe operacional, não suavize problemas e nunca estime um número que não foi dito.
            """),
            sections: [
                section("summary", String(localized: "Resumo executivo"), .paragraph,
                        String(localized: "O recado principal em 3-5 frases, como um executive summary.")),
                section("metrics", String(localized: "Números"), .bullets,
                        String(localized: "Indicadores citados, com o período de referência quando dito.")),
                section("decisions", String(localized: "Decisões"), .bullets,
                        String(localized: "Decisões tomadas e decisões pedidas, indicando quem decide.")),
                section("risks", String(localized: "Riscos"), .bullets,
                        String(localized: "Riscos com impacto e mitigação quando mencionados.")),
                section("asks", String(localized: "Pedidos de apoio"), .bullets,
                        String(localized: "Recursos, prioridade ou apoio pedidos à liderança.")),
                section("actionItems", String(localized: "Ações"), .actionItems,
                        String(localized: "Compromissos assumidos, com responsável e prazo quando ditos."))
            ],
            isBuiltIn: true,
            icon: "📊",
            category: String(localized: "Liderança")
        )
    }

    // MARK: - Aprendizado

    static var lecture: MeetingTemplate {
        MeetingTemplate(
            id: "builtin.lecture",
            name: String(localized: "Aula / palestra"),
            instructions: String(localized: """
            Assisti a uma aula, palestra ou apresentação. O objetivo é sair com um material de estudo: \
            conceitos explicados com clareza, exemplos usados e o que fazer com isso depois.
            Priorize o conteúdo apresentado, não o bate-papo em volta, e copie referências exatamente \
            como foram citadas.
            """),
            sections: [
                section("summary", String(localized: "Resumo"), .paragraph,
                        String(localized: "Tema, quem apresentou e a tese central em 3-5 frases.")),
                section("keyConcepts", String(localized: "Conceitos-chave"), .bullets,
                        String(localized: "Conceitos e definições explicados de forma auto-suficiente, sem precisar do áudio.")),
                section("examples", String(localized: "Exemplos e dados"), .bullets,
                        String(localized: "Casos, analogias e números usados para ilustrar.")),
                section("references", String(localized: "Referências citadas"), .bullets,
                        String(localized: "Livros, artigos, ferramentas, links e nomes — copiados exatamente como falados.")),
                section("questions", String(localized: "Perguntas e respostas"), .bullets,
                        String(localized: "Perguntas da audiência e as respostas dadas.")),
                section("actionItems", String(localized: "Aplicar depois"), .actionItems,
                        String(localized: "O que estudar, testar ou aplicar a partir daqui."))
            ],
            isBuiltIn: true,
            icon: "🎓",
            category: String(localized: "Aprendizado")
        )
    }
}
