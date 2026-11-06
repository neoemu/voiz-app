import Foundation

/// Tudo que o Chat conhece do app na hora de montar o prompt. Existe para as duas telas (Home e
/// Chat) mandarem o mesmo conjunto sem cada uma montar o seu — e para o builder abaixo não
/// depender de view models.
struct VoizChatContext {
    var meetings: [MeetingSession] = []
    var folders: [MeetingFolder] = []
    var dictations: [TranscriptionEntry] = []

    func meeting(id: UUID) -> MeetingSession? { meetings.first { $0.id == id } }
    func folder(id: UUID) -> MeetingFolder? { folders.first { $0.id == id } }
    func dictation(id: UUID) -> TranscriptionEntry? { dictations.first { $0.id == id } }
    func folderName(for session: MeetingSession) -> String? {
        guard let folderId = session.folderId else { return nil }
        return folder(id: folderId)?.name
    }

    /// Reuniões de uma pasta, da mais recente para a mais antiga.
    func meetings(inFolder folderId: UUID) -> [MeetingSession] {
        meetings.filter { $0.folderId == folderId }.sorted { $0.startedAt > $1.startedAt }
    }
}

/// Um item do app pendurado na conversa: reunião, pasta ou ditado.
///
/// Anexar aqui não é "subir arquivo" — é apontar para algo que o app já tem, para o modelo
/// receber **o conteúdo inteiro** daquilo em vez do recorte que cabe no índice.
struct ChatAttachment: Identifiable, Equatable, Hashable {
    enum Kind: String {
        case meeting
        case folder
        case dictation

        var systemImage: String {
            switch self {
            case .meeting: return "person.2.wave.2"
            case .folder: return "folder"
            case .dictation: return "waveform"
            }
        }
    }

    /// Id do objeto de origem — é por ele que o conteúdo é buscado na hora de enviar.
    let id: UUID
    let kind: Kind
    let title: String
}

/// Marcas de citação que o modelo devolve no texto (`[[m:1a2b3c4d]]`) e que a interface troca por
/// um chip clicável.
///
/// O identificador é o **prefixo** do UUID, não ele inteiro: são 8 caracteres em vez de 36, o
/// modelo copia sem errar e a resolução por prefixo é inequívoca na prática (16^8 combinações
/// para algumas centenas de itens).
enum ChatCitation {
    struct Match: Equatable {
        let range: Range<String.Index>
        let kind: VoizSearchKind
        let handle: String
    }

    static func handle(for id: UUID) -> String {
        String(id.uuidString.lowercased().prefix(8))
    }

    static func marker(kind: VoizSearchKind, id: UUID) -> String {
        "[[\(letter(for: kind)):\(handle(for: id))]]"
    }

    static func letter(for kind: VoizSearchKind) -> String {
        switch kind {
        case .meeting: return "m"
        case .dictation: return "d"
        case .translation: return "t"
        }
    }

    static func kind(forLetter letter: String) -> VoizSearchKind? {
        switch letter {
        case "m": return .meeting
        case "d": return .dictation
        default: return nil
        }
    }

    private static let pattern = try? NSRegularExpression(pattern: "\\[\\[([a-z]):([0-9a-fA-F]{4,32})\\]\\]")

    /// Todas as marcas de um texto, na ordem em que aparecem.
    static func matches(in text: String) -> [Match] {
        guard let pattern else { return [] }
        let ns = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { result in
                guard let range = Range(result.range, in: text),
                      let letterRange = Range(result.range(at: 1), in: text),
                      let handleRange = Range(result.range(at: 2), in: text),
                      let kind = kind(forLetter: String(text[letterRange]))
                else { return nil }
                return Match(range: range, kind: kind, handle: String(text[handleRange]).lowercased())
            }
    }

}

/// Monta o system prompt do Chat a partir do contexto e dos anexos.
///
/// A regra que organiza tudo aqui é separar **índice** de **conteúdo**. O índice de uma reunião
/// custa ~100 caracteres; o transcript dela custa ~45.000. Mandar o índice inteiro (todas as
/// reuniões, sempre) sai mais barato do que os pedaços de transcript que cabiam antes, e é o que
/// faz "liste todas as minhas reuniões" responder o número certo em vez do tamanho da janela.
enum VoizChatPromptBuilder {
    /// Reuniões cujo resumo entra no prompt. O resumo é curto e responde a maioria das perguntas.
    private static let summarizedMeetings = 12
    /// Reuniões cujo transcript entra sem ninguém pedir. É um paliativo até a busca local
    /// alimentar o contexto: sem isso, perguntas sobre o meio de uma reunião recente só
    /// funcionariam com anexo.
    private static let transcribedMeetings = 3
    private static let transcriptBudget = 4_000
    /// Teto do transcript de uma reunião anexada. ~15k tokens: cabe numa janela de 200k junto com
    /// o resto e ainda deixa espaço para a conversa.
    private static let attachedTranscriptBudget = 60_000
    /// Teto somado de todos os anexos, para uma pasta grande não estourar a janela sozinha.
    private static let attachmentsBudget = 120_000
    private static let dictationBudget = 700

    static func systemPrompt(
        context: VoizChatContext,
        attachments: [ChatAttachment],
        answerLanguage: String
    ) -> String {
        """
        Você é o assistente do Voiz: um assistente de memória de reuniões e notas.
        Sua função é ajudar o usuário a encontrar e entender o que foi discutido, decidido ou combinado nas reuniões e ditados dele.

        O QUE VOCÊ FAZ:
        - Resumir reuniões e conversas
        - Listar e detalhar action items / tarefas pendentes
        - Buscar temas específicos no histórico ("o que foi discutido sobre X?")
        - Filtrar por pessoa ("reuniões com a Ana")
        - Ajudar a preparar próximas reuniões e follow-ups
        - Apontar decisões e insights tomados
        - Consultar duração, tempo de fala por participante e capítulos

        O QUE VOCÊ NÃO FAZ:
        - Não envia e-mails nem cria eventos de calendário
        - Não salva arquivos nem edita as notas do usuário diretamente
        - Não é um chatbot de uso geral: não conta piadas, não escreve poemas, não responde sobre assuntos aleatórios fora do contexto das reuniões e notas do usuário

        REGRAS:
        - Responda sempre em \(answerLanguage), de forma direta, objetiva e útil.
        - Baseie-se SOMENTE nos dados fornecidos abaixo. Nunca invente reuniões, datas, nomes ou fatos.
        - O ÍNDICE abaixo é completo: ele lista TODAS as reuniões e ditados do usuário. Para contar, listar ou filtrar, use o índice inteiro — não só os itens que têm resumo ou transcrição.
        - Quando o índice tiver o item mas não o conteúdo, responda com o que o índice dá (título, data, pasta) e diga que para entrar no detalhe o usuário pode anexar aquela reunião pelo clipe ao lado do campo de mensagem.
        - Se não houver dado suficiente para responder, diga claramente o que falta — não preencha com suposições.
        - O tempo de fala vem dos intervalos salvos da transcrição, como na interface do Voiz; é uma estimativa, não uma medição exata de voz. Use os valores fornecidos, nunca estime pela quantidade de palavras. Percentuais usam a soma dos tempos de fala, não a duração da reunião; pode haver sobreposição. Dados parciais podem mudar após o processamento. Rótulos genéricos como "Participantes" não identificam pessoas individuais.
        - Se o usuário pedir algo fora do seu escopo (piadas, conversa solta, tarefas genéricas de IA), recuse educadamente em uma frase curta e lembre que você é o assistente de reuniões e notas do Voiz, oferecendo o que você consegue fazer. Não misture esse pedido com o conteúdo das reuniões.
        - Não force conexões entre a pergunta e os dados quando elas não existem.
        - Ações extraídas das reuniões não são automaticamente tarefas pessoais. Para "minhas tarefas" ou "em acompanhamento", use somente a lista ACOMPANHAMENTO EXPLÍCITO. O usuário pode acompanhar ações de outras pessoas. Para ações de uma reunião ou de alguém, consulte normalmente o histórico.

        CITAÇÕES:
        - Ao mencionar uma reunião ou um ditado específico, cole a marca dele logo depois do nome: [[m:1a2b3c4d]] para reunião, [[d:1a2b3c4d]] para ditado.
        - Use exatamente a marca que aparece no início da linha do item no índice. NUNCA invente uma marca nem cite um item que não está no índice.
        - Uma marca por menção, no fim da frase ou do item de lista. Não escreva a marca dentro de títulos.

        \(attachmentsSection(context: context, attachments: attachments))

        \(followedTasksSection(context: context))

        \(meetingsIndexSection(context: context))

        \(dictationsIndexSection(context: context))

        \(meetingDetailsSection(context: context, attachments: attachments))
        """
    }

    private static func followedTasksSection(context: VoizChatContext) -> String {
        let tasks = MeetingProductivity.tasks(in: context.meetings)
        let lines = tasks.map { task in
            let item = task.item
            return "- \(item.done ? "[concluída]" : "[pendente]") \(item.text) · responsável: \(item.assignee ?? "não informado") · prazo: \(item.dueDate ?? "não informado") · \(ChatCitation.marker(kind: .meeting, id: task.sessionID))"
        }
        return "ACOMPANHAMENTO EXPLÍCITO (\(tasks.count))\n" + (lines.isEmpty ? "Nenhuma ação escolhida para acompanhar." : lines.joined(separator: "\n"))
    }

    // MARK: - Índice

    private static func meetingsIndexSection(context: VoizChatContext) -> String {
        let sorted = context.meetings.sorted { $0.startedAt > $1.startedAt }
        guard !sorted.isEmpty else {
            return "ÍNDICE DE REUNIÕES (0)\n\(String(localized: "Nenhuma reunião salva."))"
        }
        let lines = sorted.map { session -> String in
            var parts = [ChatCitation.marker(kind: .meeting, id: session.id)]
            parts.append(session.formattedDate)
            parts.append(session.title)
            parts.append(session.sessionType.displayName)
            if let folder = context.folderName(for: session) {
                parts.append("pasta: \(folder)")
            }
            if let count = session.summary?.actionItemCount, count > 0 {
                parts.append("\(count) ações")
            }
            if session.summary == nil {
                parts.append("sem resumo")
            }
            return "- " + parts.joined(separator: " · ") + "\n  " + timingContext(session).replacingOccurrences(of: "\n", with: "\n  ")
        }
        return """
        ÍNDICE DE REUNIÕES (\(sorted.count) — lista completa, da mais recente para a mais antiga)
        \(lines.joined(separator: "\n"))
        """
    }

    private static func dictationsIndexSection(context: VoizChatContext) -> String {
        let sorted = context.dictations.sorted { $0.timestamp > $1.timestamp }
        guard !sorted.isEmpty else {
            return "ÍNDICE DE DITADOS (0)\n\(String(localized: "Nenhum ditado salvo."))"
        }
        let lines = sorted.map { entry -> String in
            let marker = ChatCitation.marker(kind: .dictation, id: entry.id)
            return "- \(marker) \(entry.formattedDate) · \(entry.text.prefix(120))"
        }
        return """
        ÍNDICE DE DITADOS (\(sorted.count) — lista completa)
        \(lines.joined(separator: "\n"))
        """
    }

    // MARK: - Conteúdo

    private static func meetingDetailsSection(
        context: VoizChatContext,
        attachments: [ChatAttachment]
    ) -> String {
        let sorted = context.meetings.sorted { $0.startedAt > $1.startedAt }
        // O que já foi anexado sai daqui: o anexo manda a versão completa logo acima.
        let attachedIds = Set(attachments.filter { $0.kind == .meeting }.map(\.id))
        let candidates = sorted.filter { !attachedIds.contains($0.id) }

        var blocks: [String] = []
        for (index, session) in candidates.prefix(summarizedMeetings).enumerated() {
            var block = """
            ### \(session.title) — \(session.formattedDate) \(ChatCitation.marker(kind: .meeting, id: session.id))
            Notas: \(session.notes.isEmpty ? "sem notas" : session.notes)
            Resumo: \(summaryContext(session))
            Capítulos: \(chaptersContext(session))
            """
            if index < transcribedMeetings {
                let transcript = session.transcriptText
                block += "\nTranscrição (início): \(String(transcript.prefix(transcriptBudget)))"
                if transcript.count > transcriptBudget {
                    block += "\n[transcrição cortada — anexe esta reunião para receber ela inteira]"
                }
            }
            blocks.append(block)
        }

        let recentDictations = context.dictations
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(summarizedMeetings)
            .map { "- \($0.formattedDate) \(ChatCitation.marker(kind: .dictation, id: $0.id)): \($0.text.prefix(dictationBudget))" }

        var section = "DETALHE DAS REUNIÕES MAIS RECENTES\n"
        section += blocks.isEmpty ? String(localized: "Nenhuma reunião salva.") : blocks.joined(separator: "\n\n")
        if !recentDictations.isEmpty {
            section += "\n\nDITADOS RECENTES (texto)\n" + recentDictations.joined(separator: "\n")
        }
        return section
    }

    /// Os horários já são persistidos em session.json. Derivar aqui mantém reuniões antigas,
    /// renomes de participantes e retranscrições coerentes com o gráfico, sem cache obsoleto.
    private static func timingContext(_ session: MeetingSession) -> String {
        MeetingProductivity.timingContext(session)
    }

    private static func chaptersContext(_ session: MeetingSession) -> String {
        let chapters = session.chapters ?? []
        guard !chapters.isEmpty else { return "não disponíveis" }
        return chapters.map { "[\(timeLabel($0.startTime))] \($0.title)" }.joined(separator: "; ")
    }

    private static func summaryContext(_ session: MeetingSession) -> String {
        guard let summary = session.summary else { return "sem resumo" }
        let sections = summary.sections.filter { !$0.isEmpty }.map { section in
            let text: String
            if section.kind == .actionItems {
                text = section.actionItems.map { item in
                    var parts = [item.done ? "[concluída]" : "[pendente]", item.text]
                    if let assignee = item.assignee { parts.append("responsável: \(assignee)") }
                    if let dueDate = item.dueDate { parts.append("prazo: \(dueDate)") }
                    return parts.joined(separator: " · ")
                }.joined(separator: "\n")
            } else {
                text = section.searchableText
            }
            return "\(section.title):\n\(text)"
        }
        return sections.isEmpty ? "sem resumo" : sections.joined(separator: "\n")
    }

    private static func timeLabel(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    // MARK: - Anexos

    private static func attachmentsSection(
        context: VoizChatContext,
        attachments: [ChatAttachment]
    ) -> String {
        guard !attachments.isEmpty else { return "" }

        var blocks: [String] = []
        var used = 0
        var truncated = false

        for attachment in attachments {
            guard used < attachmentsBudget else { truncated = true; break }
            guard let block = attachmentBlock(attachment, context: context) else { continue }
            let remaining = attachmentsBudget - used
            if block.count > remaining {
                blocks.append(String(block.prefix(remaining)) + "\n[anexo cortado por tamanho]")
                used = attachmentsBudget
                truncated = true
            } else {
                blocks.append(block)
                used += block.count
            }
        }

        guard !blocks.isEmpty else { return "" }
        var section = """
        ANEXOS DESTA CONVERSA (conteúdo completo — o usuário anexou de propósito, priorize isto)
        \(blocks.joined(separator: "\n\n"))
        """
        if truncated {
            section += "\n\n[parte dos anexos não coube; diga isso ao usuário se a resposta depender do que faltou]"
        }
        return section
    }

    private static func attachmentBlock(_ attachment: ChatAttachment, context: VoizChatContext) -> String? {
        switch attachment.kind {
        case .meeting:
            guard let session = context.meeting(id: attachment.id) else { return nil }
            return meetingBlock(session, context: context, transcriptBudget: attachedTranscriptBudget)

        case .folder:
            guard let folder = context.folder(id: attachment.id) else { return nil }
            let sessions = context.meetings(inFolder: folder.id)
            // Pasta vai sem transcrição de propósito: vinte reuniões inteiras passariam de 1 MB.
            // O que dá o panorama da pasta é o conjunto dos resumos e das ações.
            let lines = sessions.map { session -> String in
                """
                - \(session.formattedDate) · \(session.title) \(ChatCitation.marker(kind: .meeting, id: session.id))
                  Resumo: \(summaryContext(session))
                  Capítulos: \(chaptersContext(session))
                """
            }
            return """
            ## Pasta anexada: \(folder.name) (\(sessions.count) reuniões — resumos, sem transcrição)
            \(lines.isEmpty ? "Pasta vazia." : lines.joined(separator: "\n"))
            """

        case .dictation:
            guard let entry = context.dictation(id: attachment.id) else { return nil }
            return """
            ## Ditado anexado: \(entry.formattedDate) \(ChatCitation.marker(kind: .dictation, id: entry.id))
            \(entry.text)
            """
        }
    }

    private static func meetingBlock(
        _ session: MeetingSession,
        context: VoizChatContext,
        transcriptBudget: Int
    ) -> String {
        let transcript = session.transcriptText
        var block = """
        ## Reunião anexada: \(session.title) — \(session.formattedDate) \(ChatCitation.marker(kind: .meeting, id: session.id))
        Tipo: \(session.sessionType.displayName)\(context.folderName(for: session).map { " · Pasta: \($0)" } ?? "")
        Notas: \(session.notes.isEmpty ? "sem notas" : session.notes)
        Resumo: \(summaryContext(session))
        Capítulos: \(chaptersContext(session))
        Transcrição completa:
        \(String(transcript.prefix(transcriptBudget)))
        """
        if transcript.count > transcriptBudget {
            block += "\n[transcrição cortada em \(transcriptBudget) caracteres]"
        }
        return block
    }
}
