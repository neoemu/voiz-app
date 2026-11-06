import Combine
import Foundation

enum MeetingCaptureSource: String, Codable, CaseIterable, Identifiable {
    case microphone
    case systemAudio

    var id: String { rawValue }

    var defaultSpeakerName: String {
        switch self {
        case .microphone:
            return String(localized: "Você")
        case .systemAudio:
            // Áudio da chamada que a separação de vozes não atribuiu a ninguém. "Participantes"
            // aparecia ao lado de "Participante 1" como se fosse outra pessoa.
            return String(localized: "Outros na chamada")
        }
    }

    var displayName: String {
        switch self {
        case .microphone:
            return String(localized: "Microfone")
        case .systemAudio:
            return String(localized: "Áudio do sistema")
        }
    }
}

enum MeetingSessionType: String, Codable, CaseIterable, Identifiable {
    case meeting
    case interview

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .meeting:
            return String(localized: "Reunião")
        case .interview:
            return String(localized: "Entrevista")
        }
    }
}

struct MeetingSpeaker: Identifiable, Codable, Equatable {
    var id: String
    var source: MeetingCaptureSource
    var name: String
    /// Embedding de voz (256d) para reconhecimento entre reuniões. nil até a Fase 2.
    var embedding: [Float]?

    init(source: MeetingCaptureSource, name: String? = nil) {
        self.id = source.rawValue
        self.source = source
        self.name = name ?? source.defaultSpeakerName
        self.embedding = nil
    }

    /// Participante diarizado do áudio do sistema (id = cluster do diarizer, ex. "S1").
    init(id: String, source: MeetingCaptureSource, name: String, embedding: [Float]? = nil) {
        self.id = id
        self.source = source
        self.name = name
        self.embedding = embedding
    }
}

struct MeetingTurn: Identifiable, Codable, Equatable {
    var id: UUID
    var source: MeetingCaptureSource
    /// Identidade do falante após a diarização (cluster do diarizer, ex. "S1", ou "microphone").
    /// nil em sessões anteriores à Feature 2 / antes de diarizar.
    var speakerId: String?
    var speakerName: String
    var text: String
    var startTime: TimeInterval
    var endTime: TimeInterval
    var confidence: Float
    /// De onde veio este turno: motor, modelo e se foi fallback (T2.5).
    ///
    /// **Opcional, e para sempre**: turns gravados antes desta versão não têm a chave, e turns
    /// produzidos pela diarização/eco continuam carregando a que veio do lote. É a mesma disciplina
    /// da T2.4a no `TranscriptionEntry` — campo novo nunca derruba o que já está no disco.
    ///
    /// Quando um turno cresce com mais de um lote (`merge(turn:into:)` costura falas contíguas),
    /// vale a proveniência do **primeiro** — ver `MeetingTranscription.mergedProvenance`.
    ///
    /// A UI que mostra isso é a T6.3; aqui a proveniência só é **registrada**.
    var provenance: TranscriptionProvenance?

    init(
        id: UUID = UUID(),
        source: MeetingCaptureSource,
        speakerId: String? = nil,
        speakerName: String,
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        confidence: Float = 0,
        provenance: TranscriptionProvenance? = nil
    ) {
        self.id = id
        self.source = source
        self.speakerId = speakerId
        self.speakerName = speakerName
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
        self.provenance = provenance
    }

    /// Decode escrito à mão por causa de **um** campo: a proveniência.
    ///
    /// `TranscriptionProvenance` carrega dois enums (`useCase`, `origin`) e um rawValue que esta
    /// versão não conheça faz o decode **lançar** — o que aqui não custa um campo, custa a reunião
    /// inteira: o `MeetingSessionStore` decodifica cada sessão com `try?`, então um turno ilegível
    /// apaga a sessão da lista, com áudio, transcript e resumo. Proveniência é diagnóstico; o
    /// transcript é o produto. Diante da dúvida, o produto sobrevive e o diagnóstico vira `nil`.
    ///
    /// Todo o resto continua obrigatório de propósito — um turno sem texto ou sem tempos não é um
    /// turno degradado, é lixo, e engolir isso esconderia corrupção real. O `encode` segue
    /// sintetizado (`encodeIfPresent` para o opcional: turno sem proveniência não engorda o JSON).
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        source = try container.decode(MeetingCaptureSource.self, forKey: .source)
        speakerId = try container.decodeIfPresent(String.self, forKey: .speakerId)
        speakerName = try container.decode(String.self, forKey: .speakerName)
        text = try container.decode(String.self, forKey: .text)
        startTime = try container.decode(TimeInterval.self, forKey: .startTime)
        endTime = try container.decode(TimeInterval.self, forKey: .endTime)
        confidence = try container.decode(Float.self, forKey: .confidence)
        provenance = (try? container.decodeIfPresent(TranscriptionProvenance.self, forKey: .provenance))
            .flatMap { $0 }
    }
}

/// Índice imutável do transcript usado pelo player. Sessões produzidas pelo pipeline atual já
/// chegam ordenadas, mas sessões antigas são decodificadas como foram gravadas; ordenar aqui uma
/// única vez preserva a busca binária sem transformar cada tick de 200 ms em sort/scan do feed.
struct MeetingTurnPlaybackIndex {
    struct Lookup: Equatable {
        let turnID: UUID?
        let comparisonCount: Int
    }

    private struct Entry {
        let id: UUID
        let startTime: TimeInterval
        let sourceOrder: Int
    }

    private let entries: [Entry]

    init(turns: [MeetingTurn]) {
        entries = turns.enumerated()
            .map { offset, turn in
                Entry(id: turn.id, startTime: turn.startTime, sourceOrder: offset)
            }
            .sorted { lhs, rhs in
                if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
                // Empates mantêm a ordem da sessão. O upper-bound abaixo então reproduz a
                // semântica anterior de `last(where:)`: no instante exato, vence o último empate.
                return lhs.sourceOrder < rhs.sourceOrder
            }
    }

    func turnID(at time: TimeInterval) -> UUID? {
        lookup(at: time).turnID
    }

    /// O contador torna a garantia algorítmica testável: uma regressão para varredura linear
    /// continua funcional em muitos casos, mas deixa de respeitar o teto logarítmico da suíte.
    func lookup(at time: TimeInterval) -> Lookup {
        var lowerBound = 0
        var upperBound = entries.count
        var comparisons = 0

        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            comparisons += 1
            if entries[middle].startTime <= time {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }

        let id = lowerBound > 0 ? entries[lowerBound - 1].id : nil
        return Lookup(turnID: id, comparisonCount: comparisons)
    }
}

/// Publicação fina consumida pelo transcript. Ticks dentro do mesmo turno são deliberadamente
/// silenciosos; só uma fronteira de turno invalida as bolhas visíveis.
@MainActor
final class MeetingTurnPlaybackState: ObservableObject {
    @Published private(set) var currentTurnID: UUID?
    private var turnIndex: MeetingTurnPlaybackIndex

    init(turns: [MeetingTurn] = []) {
        turnIndex = MeetingTurnPlaybackIndex(turns: turns)
    }

    /// Substitui o transcript indexado e resolve imediatamente o destaque no tempo atual.
    /// Reprocessamentos mantêm o ID da sessão, mas recriam os UUIDs dos turnos; sem esta troca,
    /// o player continuaria publicando IDs que já não existem na view.
    @discardableResult
    func updateTurns(_ turns: [MeetingTurn], at currentTime: TimeInterval) -> Bool {
        turnIndex = MeetingTurnPlaybackIndex(turns: turns)
        return updateCurrentTime(currentTime)
    }

    @discardableResult
    func updateCurrentTime(_ currentTime: TimeInterval) -> Bool {
        updateCurrentTurnID(turnIndex.turnID(at: currentTime))
    }

    @discardableResult
    func updateCurrentTurnID(_ nextID: UUID?) -> Bool {
        guard nextID != currentTurnID else { return false }
        currentTurnID = nextID
        return true
    }
}

/// Item de ação acionável: texto + responsável/prazo opcionais + estado de concluído.
/// Capítulo/tópico automático da reunião, com um timestamp que amarra ao player (clicar → seek).
struct MeetingChapter: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var startTime: TimeInterval

    init(id: UUID = UUID(), title: String, startTime: TimeInterval) {
        self.id = id
        self.title = title
        self.startTime = startTime
    }
}

struct MeetingActionItem: Identifiable, Codable, Equatable {
    var id: UUID
    var text: String
    var assignee: String?
    var dueDate: String?
    var done: Bool
    /// Missing in legacy data: extracted actions are never followed automatically.
    var followed: Bool?
    var isFollowed: Bool { followed == true }

    init(id: UUID = UUID(), text: String, assignee: String? = nil, dueDate: String? = nil, done: Bool = false, followed: Bool? = nil) {
        self.id = id
        self.text = text
        self.assignee = assignee
        self.dueDate = dueDate
        self.done = done
        self.followed = followed
    }
}

/// Uma seção do resumo (data-driven, definida pelo template). O campo de conteúdo usado
/// depende de `kind` — os demais ficam vazios. Facilita Codable e migração.
struct MeetingSummarySection: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var kind: MeetingSectionKind
    var paragraph: String
    var bullets: [String]
    var actionItems: [MeetingActionItem]
    var evidence: [MeetingSummaryEvidence]?

    init(
        id: String,
        title: String,
        kind: MeetingSectionKind,
        paragraph: String = "",
        bullets: [String] = [],
        actionItems: [MeetingActionItem] = []
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.paragraph = paragraph
        self.bullets = bullets
        self.actionItems = actionItems
    }

    var isEmpty: Bool {
        switch kind {
        case .paragraph:
            return paragraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .bullets:
            return bullets.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        case .actionItems:
            return actionItems.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }

    /// Texto agregado da seção, usado na busca full-text.
    var searchableText: String {
        switch kind {
        case .paragraph:
            return paragraph
        case .bullets:
            return bullets.joined(separator: "\n")
        case .actionItems:
            return actionItems.map { item in
                [item.text, item.assignee, item.dueDate].compactMap { $0 }.joined(separator: " ")
            }.joined(separator: "\n")
        }
    }
}

extension MeetingSummarySection {
    static func paragraph(id: String, title: String, text: String) -> MeetingSummarySection {
        MeetingSummarySection(id: id, title: title, kind: .paragraph, paragraph: text)
    }

    static func bullets(id: String, title: String, items: [String]) -> MeetingSummarySection {
        MeetingSummarySection(id: id, title: title, kind: .bullets, bullets: items)
    }

    static func actions(id: String, title: String, items: [MeetingActionItem]) -> MeetingSummarySection {
        MeetingSummarySection(id: id, title: title, kind: .actionItems, actionItems: items)
    }

    /// Seção vazia derivada de uma seção de template (preserva estrutura sem conteúdo).
    static func empty(from section: MeetingTemplateSection) -> MeetingSummarySection {
        MeetingSummarySection(id: section.id, title: section.title, kind: section.kind)
    }
}

/// Resumo gerado por IA. Migrou de **campos fixos** para **seções dinâmicas** definidas pelo
/// template (Feature 4). O Codable customizado decodifica o formato antigo (campos fixos) para
/// manter compat com sessões já salvas em disco.
struct MeetingSummary: Equatable {
    var title: String
    var sections: [MeetingSummarySection]

    init(title: String, sections: [MeetingSummarySection]) {
        self.title = title
        self.sections = sections
    }

    static let empty = MeetingSummary(title: "", sections: [])

    var hasContent: Bool {
        !title.isEmpty || sections.contains { !$0.isEmpty }
    }

    /// Primeiro parágrafo não vazio (compat com chat/preview que esperavam um texto de resumo).
    var overview: String {
        sections.first(where: { $0.kind == .paragraph && !$0.isEmpty })?.paragraph ?? ""
    }

    /// Todos os action items de todas as seções de ações.
    var allActionItems: [MeetingActionItem] {
        sections.filter { $0.kind == .actionItems }.flatMap { $0.actionItems }
    }

    var actionItemCount: Int {
        allActionItems.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    /// Texto curto dos action items para contexto do chat ("; " entre eles).
    var actionItemsText: String {
        allActionItems.map(\.text).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "; ")
    }
}

extension MeetingSummary: Codable {
    private enum CodingKeys: String, CodingKey {
        case title
        case sections
        // Legado (campos fixos) — apenas para decodificar sessões antigas.
        case summary
        case keyPoints
        case decisions
        case actionItems
        case followUps
        case interviewSignals
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""

        if let sections = try container.decodeIfPresent([MeetingSummarySection].self, forKey: .sections) {
            self.sections = sections
            return
        }

        // Migração do formato antigo de campos fixos → seções dinâmicas.
        var migrated: [MeetingSummarySection] = []
        let summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        if !summary.isEmpty {
            migrated.append(.paragraph(id: "summary", title: String(localized: "Resumo"), text: summary))
        }
        let keyPoints = try container.decodeIfPresent([String].self, forKey: .keyPoints) ?? []
        if !keyPoints.isEmpty {
            migrated.append(.bullets(id: "keyPoints", title: String(localized: "Pontos-chave"), items: keyPoints))
        }
        let decisions = try container.decodeIfPresent([String].self, forKey: .decisions) ?? []
        if !decisions.isEmpty {
            migrated.append(.bullets(id: "decisions", title: String(localized: "Decisões"), items: decisions))
        }
        let actionItems = try container.decodeIfPresent([String].self, forKey: .actionItems) ?? []
        if !actionItems.isEmpty {
            migrated.append(.actions(id: "actionItems", title: String(localized: "Ações"),
                                     items: actionItems.map { MeetingActionItem(text: $0) }))
        }
        let followUps = try container.decodeIfPresent([String].self, forKey: .followUps) ?? []
        if !followUps.isEmpty {
            migrated.append(.bullets(id: "followUps", title: String(localized: "Follow-ups"), items: followUps))
        }
        let interviewSignals = try container.decodeIfPresent([String].self, forKey: .interviewSignals) ?? []
        if !interviewSignals.isEmpty {
            migrated.append(.bullets(id: "interviewSignals", title: String(localized: "Sinais da entrevista"), items: interviewSignals))
        }
        self.sections = migrated
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(sections, forKey: .sections)
    }
}

struct MeetingTalkTimeStat: Identifiable, Equatable {
    var id: String { "\(source.rawValue):\(speakerId ?? speakerName)" }
    var speakerName: String
    var source: MeetingCaptureSource
    var speakerId: String?
    var duration: TimeInterval
    var fraction: Double
}

/// Pasta para organizar reuniões (estilo Granola). As sessões apontam pra pasta via
/// `MeetingSession.folderId`; apagar a pasta só desassocia as sessões (nada é perdido).
struct MeetingFolder: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    /// Descrição opcional ("Describe the purpose of this folder").
    var details: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String, details: String = "", createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.details = details
        self.createdAt = createdAt
    }
}

struct MeetingSession: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var sessionType: MeetingSessionType
    var startedAt: Date
    var endedAt: Date?
    /// Soma dos intervalos pausados. Opcional mantém compatibilidade com sessões antigas.
    var pausedDuration: TimeInterval?
    var notes: String
    /// nil preserves the behavior of older sessions; new sessions keep manual notes out of AI summaries.
    var includeNotesInSummary: Bool?
    var contextSessionIDs: [UUID]?

    var usesNotesInSummary: Bool { includeNotesInSummary ?? true }
    var speakers: [MeetingSpeaker]
    var turns: [MeetingTurn]
    var summary: MeetingSummary?
    var audioFiles: [MeetingCaptureSource: String]
    var systemAudioWarning: String?
    var summaryError: String?
    /// Template de resumo usado nesta sessão. nil em sessões anteriores à Feature 4.
    var templateId: String?
    /// Capítulos/tópicos automáticos. nil em sessões que ainda não geraram (compat retroativa).
    var chapters: [MeetingChapter]?
    /// Falha da geração automática; nil em sessões antigas ou sem erro.
    var chaptersError: String?
    /// Faixa de microfone com o eco da caixa de som removido (gerada pós-call pelo
    /// `MeetingEchoReconciler`). Quando presente, o player a usa no lugar do `microphone.caf`
    /// para o participante não ecoar no playback. nil = sem eco detectado / sessão antiga.
    var cleanMicFile: String?
    /// Pasta à qual a sessão pertence. nil = sem pasta (aparece só em Recentes).
    var folderId: UUID?
    /// Modelo que gerou **este** resumo, capturado na hora da geração (ex.: "GPT-5.6 Luna").
    ///
    /// Guardado como texto de propósito: as listas de modelo mudam (slug aposentado sai do enum),
    /// e uma reunião resumida meses atrás precisa continuar mostrando com o que foi feita. Ler das
    /// configurações atuais mostraria o modelo de hoje, não o que rodou. nil = resumo anterior a
    /// este campo, ou ainda não gerado.
    var summaryModel: String?
    /// Esforço de raciocínio usado **nesta** geração, como `rawValue` de
    /// `AppSettings.ReasoningEffort` (ex.: "max"). nil = o resumo rodou no padrão do modelo
    /// (`.auto`, que nem manda o parâmetro), veio de antes deste campo, ou ainda não existe.
    ///
    /// Ao contrário de `summaryModel`, aqui vale guardar o slug: a escada de esforço é fixa e
    /// pequena, então o rótulo pode ser traduzido na hora de exibir em vez de congelar o idioma
    /// em que a reunião foi resumida.
    var summaryEffort: String?
    /// O plano de transcrição congelado no início desta reunião (T2.5).
    ///
    /// Os lotes do transcript oficial seguem **este** plano, e não os Ajustes vivos: trocar de
    /// modelo durante a gravação não parte o transcript da reunião em curso em dois motores. É a
    /// versão persistida (e com a decisão inteira do roteador dentro) dos três campos que o view
    /// model fixava à mão no `startMeeting`.
    ///
    /// nil = sessão gravada antes deste campo, ou sessão cujo plano não sobreviveu ao decode. Nos
    /// dois casos o pós-processamento se comporta como antes da T2.5: monta o plano com os Ajustes
    /// atuais. `reprocessTranscript` sempre grava um snapshot **novo**, pelo mesmo motivo de sempre
    /// (reprocessar é escolher de novo, com o que está configurado agora).
    var transcriptionPlan: TranscriptionPlanSnapshot?
    /// Modo de transcrição da reunião (.quality ou .granola). nil em sessões gravadas antes deste campo.
    var meetingMode: AppSettings.MeetingMode?
    /// nil = sessão gravada antes deste campo. true = pós-processamento completo; false = pendente/interrompido.
    var isProcessingCompleted: Bool?
    /// Clique em Reprocessar: o recovery re-enfileira o pipeline completo, não o
    /// só-resumo do Granola. nil/false = automático. Decode ausente = nil.
    var pendingManualReprocess: Bool?

    init(
        id: UUID = UUID(),
        title: String = "Nova reunião",
        sessionType: MeetingSessionType = .meeting,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        pausedDuration: TimeInterval? = nil,
        notes: String = "",
        includeNotesInSummary: Bool? = false,
        contextSessionIDs: [UUID]? = nil,
        speakers: [MeetingSpeaker] = MeetingCaptureSource.allCases.map({ MeetingSpeaker(source: $0) }),
        turns: [MeetingTurn] = [],
        summary: MeetingSummary? = nil,
        audioFiles: [MeetingCaptureSource: String] = [:],
        systemAudioWarning: String? = nil,
        summaryError: String? = nil,
        templateId: String? = nil,
        chapters: [MeetingChapter]? = nil,
        chaptersError: String? = nil,
        cleanMicFile: String? = nil,
        folderId: UUID? = nil,
        summaryModel: String? = nil,
        summaryEffort: String? = nil,
        transcriptionPlan: TranscriptionPlanSnapshot? = nil,
        meetingMode: AppSettings.MeetingMode? = nil,
        isProcessingCompleted: Bool? = nil,
        pendingManualReprocess: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.sessionType = sessionType
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.pausedDuration = pausedDuration
        self.notes = notes
        self.includeNotesInSummary = includeNotesInSummary
        self.contextSessionIDs = contextSessionIDs
        self.speakers = speakers
        self.turns = turns
        self.summary = summary
        self.audioFiles = audioFiles
        self.systemAudioWarning = systemAudioWarning
        self.summaryError = summaryError
        self.templateId = templateId
        self.chapters = chapters
        self.chaptersError = chaptersError
        self.cleanMicFile = cleanMicFile
        self.folderId = folderId
        self.summaryModel = summaryModel
        self.summaryEffort = summaryEffort
        self.transcriptionPlan = transcriptionPlan
        self.meetingMode = meetingMode
        self.isProcessingCompleted = isProcessingCompleted
        self.pendingManualReprocess = pendingManualReprocess
    }

    var duration: TimeInterval {
        max(0, (endedAt ?? Date()).timeIntervalSince(startedAt) - (pausedDuration ?? 0))
    }

    var transcriptText: String {
        turns.map { "\($0.speakerName): \($0.text)" }.joined(separator: "\n")
    }

    /// Falantes da lista de participantes. O áudio da chamada que a separação de vozes não atribuiu
    /// a ninguém sai dela quando é resto (menos de 5% do tempo de fala) e já há participantes
    /// identificados: na lista, ao lado de "Participante 1", ele parecia mais uma pessoa. O tempo
    /// de fala continua mostrando tudo.
    var participantsListSpeakers: [MeetingSpeaker] {
        let unassignedID = MeetingCaptureSource.systemAudio.rawValue
        let hasIdentified = speakers.contains { $0.source == .systemAudio && $0.id != unassignedID }
        guard hasIdentified else { return speakers }
        let share = talkTimeStats.first { $0.source == .systemAudio && $0.speakerId == unassignedID }?.fraction ?? 0
        guard share < 0.05 else { return speakers }
        return speakers.filter { $0.id != unassignedID }
    }

    /// IDs mantêm homônimos separados e o tempo estável depois de renomear.
    var talkTimeStats: [MeetingTalkTimeStat] {
        var resolved = self
        resolved.reconcileSpeakers()
        var stats: [String: MeetingTalkTimeStat] = [:]
        for turn in resolved.turns {
            guard let id = turn.speakerId else { continue }
            let key = "\(turn.source.rawValue):\(id)"
            if stats[key] == nil {
                stats[key] = MeetingTalkTimeStat(
                    speakerName: turn.speakerName, source: turn.source, speakerId: id,
                    duration: 0, fraction: 0
                )
            }
            stats[key]?.duration += max(0, turn.endTime - turn.startTime)
        }
        let total = stats.values.reduce(0) { $0 + $1.duration }
        guard total > 0 else { return [] }
        return stats.values.map { stat in
            var next = stat
            next.fraction = stat.duration / total
            return next
        }.sorted {
            $0.duration == $1.duration ? $0.id < $1.id : $0.duration > $1.duration
        }
    }

    /// Conteúdo da sessão sem o título: falas, resumo e notas. É daqui que a busca global tira o
    /// trecho mostrado no resultado — do título ela já mostra o título.
    var searchableBody: String {
        var haystack = [transcriptText]
        if let summary {
            haystack.append(summary.title)
            for section in summary.sections {
                haystack.append(section.title)
                haystack.append(section.searchableText)
            }
        }
        haystack.append(notes)
        return haystack.joined(separator: "\n")
    }

    /// Texto varrido pela busca: título mais todo o `searchableBody`.
    var searchableText: String {
        title + "\n" + searchableBody
    }

    /// Prosa da sessão, para o trecho mostrado nos resultados: conteúdo do resumo primeiro (é o
    /// que resume melhor), depois as falas e as notas. Sem os títulos das seções — "Resumo
    /// Pontos-chave Decisões" é estrutura, não conteúdo.
    var previewText: String {
        var parts: [String] = []
        if let summary {
            parts.append(contentsOf: summary.sections.map(\.searchableText))
        }
        parts.append(transcriptText)
        parts.append(notes)
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Busca full-text sobre `searchableText`. Query vazia casa com tudo.
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        return VoizSearch.matches(searchableText, q)
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.locale = .voizInterface
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: startedAt)
    }

    func speakerName(for source: MeetingCaptureSource) -> String {
        // Ao vivo e Qualidade usam os mesmos nomes padrão ("Você" e "Outros na chamada").
        if let custom = speakers.first(where: { $0.source == source })?.name, !custom.isEmpty {
            return custom
        }
        return source.defaultSpeakerName
    }
}

struct MeetingAudioChunk {
    let source: MeetingCaptureSource
    let samples: [Float]
    let startTime: TimeInterval
    let endTime: TimeInterval
}

/// Uma frase do preview de transcript ao vivo. Não é persistida — o transcript
/// oficial são os `MeetingTurn`s da sessão.
///
/// `channel == nil` é o fluxo único da prévia Whisper (modo Qualidade). No Granola
/// cada entrada carrega o canal (Você = mic, Eles = áudio do sistema).
struct MeetingLiveFeedEntry: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let channel: MeetingLiveAudioChannel?
    /// Relógio da captura, em segundos desde o start. `nil` se não houver tempo confiável.
    let startTime: TimeInterval?

    init(
        text: String,
        channel: MeetingLiveAudioChannel? = nil,
        startTime: TimeInterval? = nil
    ) {
        self.text = text
        self.channel = channel
        self.startTime = startTime
    }

    /// Cap display-only: o transcript oficial são os turns. Sem código extra
    /// para evict (limitação conhecida).
    static let displayCap = 120

    /// Insere por `startTime` para o preview e o transcript final terem a
    /// mesma ordem entre canais. Sem relógio, cai no fim (chegada).
    static func inserting(_ entry: Self, into feed: [Self]) -> [Self] {
        var next = feed
        if let start = entry.startTime {
            let index = next.firstIndex { existing in
                guard let existingStart = existing.startTime else { return true }
                return existingStart > start
            } ?? next.endIndex
            next.insert(entry, at: index)
        } else {
            next.append(entry)
        }
        if next.count > displayCap {
            next.removeFirst(next.count - displayCap)
        }
        return next
    }
}

/// Hipóteses voláteis do transcript ao vivo, uma por canal.
///
/// O view model não compila em `voizTests`; a regra mora aqui para o teste
/// conseguir reintroduzir o defeito (um único parágrafo sobrescrito).
nonisolated struct MeetingLiveVolatileState: Equatable, Sendable {
    var microphone: String = ""
    var systemAudio: String = ""

    func text(for channel: MeetingLiveAudioChannel) -> String {
        switch channel {
        case .microphone: return microphone
        case .systemAudio: return systemAudio
        }
    }

    /// Cada volátil só reescreve o próprio canal. O defeito antigo era
    /// `liveCurrentParagraph = text`, que ignorava o canal e apagava o outro.
    mutating func apply(text: String, channel: MeetingLiveAudioChannel) {
        switch channel {
        case .microphone: microphone = text
        case .systemAudio: systemAudio = text
        }
    }

    mutating func clear(_ channel: MeetingLiveAudioChannel) {
        apply(text: "", channel: channel)
    }

    var isEmpty: Bool {
        microphone.isEmpty && systemAudio.isEmpty
    }
}

/// Lado da bolha no transcript Granola. Convenção: Você à esquerda, Eles à direita.
nonisolated enum MeetingLiveTranscriptSide: Equatable, Sendable {
    case you
    case them
    case fill

    static func forChannel(_ channel: MeetingLiveAudioChannel?) -> Self {
        switch channel {
        case .microphone: return .you
        case .systemAudio: return .them
        case nil: return .fill
        }
    }

    /// Você (e o fluxo único sem canal) encostam à esquerda; Eles à direita.
    var isLeading: Bool { self != .them }
}

struct MeetingCaptureStartResult {
    let audioFiles: [MeetingCaptureSource: String]
    let systemAudioWarning: String?
}
