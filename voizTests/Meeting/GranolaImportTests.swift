import Foundation
import Testing

/// Importação do Granola sem rede real. As notas são sintéticas, mas seguem o formato observado na
/// API oficial: `# Tópico`, bullets com detalhe indentado, rodapé com link e segmentos curtos.
@MainActor
@Suite("Importação do Granola", .serialized)
struct GranolaImportTests {
    private static let key = "grn_SECRET_KEY_NEVER_LOG"
    private static let base = Date(timeIntervalSince1970: 1_780_000_000)

    private func segment(_ offset: TimeInterval, _ duration: TimeInterval, _ text: String,
                         source: String = "speaker", attribution: String? = "them",
                         name: String? = nil, label: String? = nil) -> GranolaNote.Segment {
        GranolaNote.Segment(
            speaker: .init(source: source, attribution: attribution, diarizationLabel: label, name: name),
            text: text,
            startTime: Self.base.addingTimeInterval(offset),
            endTime: Self.base.addingTimeInterval(offset + duration)
        )
    }

    private func note(id: String = "not_00000000000001", title: String? = "Planejamento",
                      transcript: [GranolaNote.Segment]? = nil, markdown: String? = nil,
                      text: String? = nil, calendar: GranolaNote.CalendarEvent? = nil) -> GranolaNote {
        GranolaNote(id: id, title: title, createdAt: Self.base.addingTimeInterval(-60), calendarEvent: calendar,
                    folderMembership: [], summaryText: text, summaryMarkdown: markdown,
                    privateNotesText: nil, privateNotesMarkdown: nil, transcript: transcript)
    }

    // MARK: - Reunião

    @Test("ID derivado da nota: a mesma nota sempre cai na mesma reunião")
    func stableIdentity() {
        let first = GranolaNoteMapper.sessionID(forNoteID: "not_00000000000001")
        #expect(first == GranolaNoteMapper.sessionID(forNoteID: "not_00000000000001"))
        #expect(first != GranolaNoteMapper.sessionID(forNoteID: "not_00000000000002"))
    }

    @Test("Sem áudio e concluída: o pós-processamento pago nunca a alcança")
    func importedSessionStaysOutOfThePipeline() {
        let session = GranolaNoteMapper.session(from: note(transcript: [segment(0, 2, "Oi")], markdown: "# A\n\n- b"))
        #expect(session.audioFiles.isEmpty)
        #expect(session.isProcessingCompleted == true)
        #expect(session.pendingManualReprocess == nil)
        #expect(session.summaryModel == GranolaNoteMapper.summaryOrigin)
        #expect(session.includeNotesInSummary == false)
    }

    @Test("A reunião começa na primeira fala, e não quando a nota foi criada")
    func timesComeFromTheTranscript() throws {
        let session = GranolaNoteMapper.session(from: note(transcript: [
            segment(0, 5, "Abertura", source: "microphone", attribution: "me"),
            segment(600, 30, "Fechamento")
        ]))
        #expect(session.startedAt == Self.base)
        #expect(session.endedAt == Self.base.addingTimeInterval(630))
        #expect(try #require(session.turns.last).startTime == 600)
    }

    @Test("Sem transcrição, vale a agenda; sem agenda, a criação da nota")
    func timesWithoutTranscript() {
        let start = Self.base.addingTimeInterval(1_000)
        let event = GranolaNote.CalendarEvent(eventTitle: "Daily", scheduledStartTime: start,
                                              scheduledEndTime: start.addingTimeInterval(900))
        let scheduled = GranolaNoteMapper.session(from: note(transcript: nil, calendar: event))
        #expect(scheduled.startedAt == start)
        #expect(scheduled.duration == 900)
        let bare = GranolaNoteMapper.session(from: note(transcript: []))
        #expect(bare.startedAt == Self.base.addingTimeInterval(-60))
        #expect(bare.duration == 0)
    }

    @Test("Título ausente usa o evento da agenda antes do texto genérico")
    func titleFallbacks() {
        let event = GranolaNote.CalendarEvent(eventTitle: "Daily", scheduledStartTime: nil, scheduledEndTime: nil)
        #expect(GranolaNoteMapper.session(from: note(title: nil, calendar: event)).title == "Daily")
        #expect(!GranolaNoteMapper.session(from: note(title: "   ")).title.isEmpty)
    }

    // MARK: - Falantes

    @Test("Eu, pessoas com nome e anônimos viram falantes separados")
    func speakerMapping() throws {
        var session = GranolaNoteMapper.session(from: note(transcript: [
            segment(0, 1, "Oi", source: "microphone", attribution: "me"),
            segment(10, 1, "Olá", name: "Ana"),
            segment(20, 1, "Tudo", name: "Bruno"),
            segment(30, 1, "bem", name: "Ana"),
            segment(40, 1, "Quem?")
        ]))
        session.reconcileSpeakers()
        #expect(session.turns.map(\.source) == [.microphone, .systemAudio, .systemAudio, .systemAudio, .systemAudio])
        #expect(session.turns[0].speakerName == MeetingCaptureSource.microphone.defaultSpeakerName)
        #expect(session.turns[1].speakerName == "Ana")
        #expect(session.turns[1].speakerId == session.turns[3].speakerId)
        #expect(session.turns[1].speakerId != session.turns[2].speakerId)
        #expect(session.turns[4].speakerId == MeetingCaptureSource.systemAudio.rawValue)
        #expect(session.speakers.count == 4)
    }

    @Test("iOS: tudo vem como microfone, e o rótulo de diarização indica outra pessoa")
    func iOSDiarizationLabels() throws {
        let session = GranolaNoteMapper.session(from: note(transcript: [
            segment(0, 1, "Oi", source: "microphone", attribution: nil),
            segment(10, 1, "Olá", source: "microphone", attribution: nil, label: "Speaker A")
        ]))
        #expect(session.turns[0].source == .microphone)
        #expect(session.turns[1].source == .systemAudio)
        #expect(session.turns[1].speakerName == "Speaker A")
    }

    @Test("Costura segmentos curtos do mesmo falante, sem atravessar falante nem pausa longa")
    func mergesContiguousSegments() {
        let session = GranolaNoteMapper.session(from: note(transcript: [
            segment(0, 2, "Primeira parte", name: "Ana"),
            segment(2, 2, "da mesma frase", name: "Ana"),
            segment(4.5, 2, "ainda ela", name: "Ana"),
            segment(7, 2, "Agora eu", source: "microphone", attribution: "me"),
            segment(9, 1, "Volta", name: "Ana"),
            segment(20, 1, "Depois da pausa", name: "Ana")
        ]))
        #expect(session.turns.map(\.text) == [
            "Primeira parte da mesma frase ainda ela", "Agora eu", "Volta", "Depois da pausa"
        ])
        #expect(session.turns[0].endTime == 6.5)
    }

    @Test("Monólogo contínuo é dividido em falas legíveis, sem perder texto nem cortar segmento")
    func capsMergedTurnLength() {
        let sentence = String(repeating: "palavra ", count: 25).trimmingCharacters(in: .whitespaces)
        let segments = (0..<40).map { segment(Double($0), 1, sentence) }
        let session = GranolaNoteMapper.session(from: note(transcript: segments))
        #expect(session.turns.count > 1)
        #expect(session.turns.allSatisfy { $0.text.count < 800 + sentence.count + 1 })
        #expect(session.turns.map(\.text).joined(separator: " ") == segments.map(\.text).joined(separator: " "))
    }

    @Test("Segmento vazio não vira fala")
    func skipsBlankSegments() {
        let session = GranolaNoteMapper.session(from: note(transcript: [segment(0, 1, "  \n"), segment(5, 1, "Oi")]))
        #expect(session.turns.map(\.text) == ["Oi"])
        #expect(session.startedAt == Self.base.addingTimeInterval(5))
    }

    @Test("Os turnos convertidos passam pelo contrato do Sync")
    func convertedSessionFitsSyncContract() throws {
        let session = GranolaNoteMapper.session(from: note(transcript: [
            segment(0, 1, "Sobreposto", source: "microphone", attribution: "me"),
            segment(-0.0, 0.5, "Ao mesmo tempo", name: "Ana"),
            segment(3, -1, "Fim antes do início", name: "Ana")
        ], markdown: "# A\n\n- b"))
        _ = try SyncDTOAdapter.meeting(session).canonicalData()
        _ = try SyncDTOAdapter.transcript(session, generationID: UUID()).canonicalData()
        #expect(session.turns.allSatisfy { $0.endTime >= $0.startTime && $0.startTime >= 0 })
    }

    // MARK: - Resumo

    private let realisticSummary = """
    # Decisões

    - **Lançar em março**

      Depois da revisão jurídica
    - Manter o preço
      - Sem desconto no início
      - Revisar em junho

    # Próximos Passos

    - **Fechar o contrato** com [o fornecedor](https://example.com/x)

      Até sexta

    ---

    Chat with meeting transcript: [https://notes.granola.ai/t/abc](https://notes.granola.ai/t/abc)
    """

    @Test("Cabeçalhos viram seções e o rodapé do Granola sai")
    func summarySections() throws {
        let summary = try #require(GranolaNoteMapper.summary(markdown: realisticSummary, plainText: nil, title: "T"))
        #expect(summary.sections.map(\.title) == ["Decisões", "Próximos Passos"])
        #expect(summary.sections.allSatisfy { $0.kind == .bullets })
        let all = summary.sections.flatMap(\.bullets).joined(separator: "\n")
        #expect(!all.contains("notes.granola.ai"))
        #expect(!all.contains("Chat with meeting"))
        #expect(!all.contains("---"))
    }

    @Test("Filhos e detalhes indentados ficam dentro do bullet do tópico")
    func nestedBullets() throws {
        let summary = try #require(GranolaNoteMapper.summary(markdown: realisticSummary, plainText: nil, title: "T"))
        #expect(summary.sections[0].bullets == [
            "Lançar em março\nDepois da revisão jurídica",
            "Manter o preço\n– Sem desconto no início\n– Revisar em junho"
        ])
    }

    @Test("Negrito e links não aparecem crus")
    func inlineMarkdown() throws {
        let summary = try #require(GranolaNoteMapper.summary(markdown: realisticSummary, plainText: nil, title: "T"))
        #expect(summary.sections[1].bullets == ["Fechar o contrato com o fornecedor\nAté sexta"])
    }

    @Test("Só parágrafos viram seção de parágrafo; texto antes do primeiro título entra em Resumo")
    func paragraphs() throws {
        let summary = try #require(GranolaNoteMapper.summary(
            markdown: "Visão geral.\n\nSegunda frase.\n\n# Tópico\n\n1. Um\n2. [x] Dois",
            plainText: nil, title: "T"
        ))
        #expect(summary.sections.map(\.kind) == [.paragraph, .bullets])
        #expect(summary.sections[0].paragraph == "Visão geral.\n\nSegunda frase.")
        #expect(summary.sections[1].bullets == ["Um", "Dois"])
    }

    @Test("Sem Markdown usa o texto puro; sem nada, não inventa resumo")
    func summaryFallback() throws {
        let plain = try #require(GranolaNoteMapper.summary(markdown: nil, plainText: "  Texto.  ", title: "T"))
        #expect(plain.sections.first?.paragraph == "Texto.")
        #expect(GranolaNoteMapper.summary(markdown: "", plainText: "  ", title: "T") == nil)
        #expect(GranolaNoteMapper.summary(markdown: "---\n\n[l](https://notes.granola.ai/t/a)", plainText: nil, title: "T") == nil)
    }

    // MARK: - API

    private func client(sleeps: GranolaSleepLog = GranolaSleepLog()) -> GranolaAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GranolaAPIStub.self]
        return GranolaAPIClient(apiKey: Self.key, session: URLSession(configuration: config),
                                sleep: { sleeps.record($0) })
    }

    @Test("Percorre todas as páginas com o cursor e envia a chave como bearer")
    func pagination() async throws {
        GranolaAPIStub.reset()
        GranolaAPIStub.handler = { request in
            let cursor = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "cursor" }?.value
            return cursor == nil
                ? (200, [:], GranolaFixtures.listing(["not_a"], hasMore: true, cursor: "c2"))
                : (200, [:], GranolaFixtures.listing(["not_b"], hasMore: false, cursor: nil))
        }
        let notes = try await client().listNotes()
        #expect(notes.map(\.id) == ["not_a", "not_b"])
        #expect(GranolaAPIStub.recorded().count == 2)
        #expect(GranolaAPIStub.recorded().allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.key)"
        })
    }

    @Test("429 espera o Retry-After e tenta de novo")
    func retriesRateLimit() async throws {
        GranolaAPIStub.reset()
        let sleeps = GranolaSleepLog()
        GranolaAPIStub.handler = { _ in
            GranolaAPIStub.recorded().count == 1
                ? (429, ["Retry-After": "7"], Data())
                : (200, [:], GranolaFixtures.listing(["not_a"], hasMore: false, cursor: nil))
        }
        #expect(try await client(sleeps: sleeps).listNotes().count == 1)
        #expect(sleeps.values == [7])
    }

    @Test("429 insistente vira erro próprio e desiste num número fixo de tentativas")
    func givesUpOnRateLimit() async {
        GranolaAPIStub.reset()
        GranolaAPIStub.handler = { _ in (429, [:], Data()) }
        await #expect(throws: GranolaImportError.rateLimited) { try await client().listNotes() }
        #expect(GranolaAPIStub.recorded().count == 5)
    }

    @Test("401 não é repetido, e nenhuma mensagem de erro traz a chave")
    func invalidKeyFailsFast() async {
        GranolaAPIStub.reset()
        GranolaAPIStub.handler = { _ in (401, [:], Data()) }
        await #expect(throws: GranolaImportError.invalidKey) { try await client().listNotes() }
        #expect(GranolaAPIStub.recorded().count == 1)
        for error in [GranolaImportError.invalidKey, .accessDenied, .rateLimited, .offline] {
            #expect(!error.message.contains(Self.key))
        }
    }

    @Test("Transcrição grande demais (413) é buscada em páginas")
    func oversizedTranscript() async throws {
        GranolaAPIStub.reset()
        GranolaAPIStub.handler = { request in
            let url = try #require(request.url)
            if url.path.hasSuffix("/transcript") {
                let cursor = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "cursor" }?.value
                return (200, [:], GranolaFixtures.transcriptPage(text: cursor == nil ? "Um" : "Dois",
                                                                 cursor: cursor == nil ? "c2" : nil))
            }
            return url.query?.contains("include=transcript") == true
                ? (413, [:], Data())
                : (200, [:], GranolaFixtures.note(id: "not_a", folder: nil))
        }
        let note = try await client().note(id: "not_a")
        #expect(note.transcript?.map(\.text) == ["Um", "Dois"])
    }

    @Test("Datas com e sem fração de segundo e campos novos da API são aceitos")
    func tolerantDecoding() async throws {
        GranolaAPIStub.reset()
        GranolaAPIStub.handler = { _ in
            (200, [:], Data("""
            {"id":"not_a","object":"note","campo_novo":1,"title":null,"created_at":"2026-11-06T13:04:05Z",
             "calendar_event":null,"folder_membership":[],"summary_text":"s","summary_markdown":null,
             "private_notes_text":null,"private_notes_markdown":null,
             "transcript":[{"speaker":{"source":"algo_novo"},"text":"Oi",
             "start_time":"2026-11-06T13:04:05.123Z","end_time":"2026-11-06T13:04:06Z"}]}
            """.utf8))
        }
        let note = try await client().note(id: "not_a")
        #expect(note.transcript?.first?.speaker.source == "algo_novo")
    }

    // MARK: - CSV

    private func csv(_ text: String) throws -> GranolaCSVArchive { try GranolaCSVArchive.parse(Data(text.utf8)) }

    private func fileWith(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("granola-\(UUID().uuidString).csv")
        try Data(text.utf8).write(to: url)
        return url
    }

    private let exportCSV = """
    Title,Created At,Summary,Transcript,Folder
    "Planejamento, Q4",2026-11-06T13:04:05.000Z,"# Decisões

    - Lançar em \"\"março\"\"\",\"Me: Vamos começar
    Them: Combinado
    Me: Fechado",Clientes
    Daily,2026-11-05 09:00:00,Resumo curto,,
    """

    @Test("Vírgula, aspas e quebra de linha dentro do campo não partem a linha")
    func csvQuotedFields() throws {
        let archive = try csv(exportCSV)
        #expect(archive.notes.map(\.title) == ["Planejamento, Q4", "Daily"])
        #expect(archive.notes[0].summaryMarkdown?.contains("Lançar em \"março\"") == true)
        #expect(archive.notes[0].folderMembership.map(\.name) == ["Clientes"])
        #expect(archive.unreadableRows == 0)
    }

    @Test("BOM, CRLF e ponto e vírgula de planilha são aceitos")
    func csvSpreadsheetVariants() throws {
        let archive = try GranolaCSVArchive.parse(Data("\u{FEFF}Title;Date;Summary\r\nA;2026-01-02;Texto\r\n".utf8))
        #expect(archive.notes.map(\.title) == ["A"])
        #expect(archive.notes[0].summaryMarkdown == "Texto")
    }

    @Test("Me e Them viram você e os outros, com o mesmo conversor da API")
    func csvTranscriptSpeakers() throws {
        let session = GranolaNoteMapper.session(from: try csv(exportCSV).notes[0])
        #expect(session.turns.map(\.text) == ["Vamos começar", "Combinado", "Fechado"])
        #expect(session.turns.map(\.source) == [.microphone, .systemAudio, .microphone])
        #expect(session.audioFiles.isEmpty)
        #expect(session.isProcessingCompleted == true)
    }

    @Test("Nomes repetidos viram falantes; dois-pontos solto numa frase não")
    func csvNamedSpeakers() throws {
        let transcript = "Ana: Oi\nBruno: Olá\nAna: Tudo bem\nBruno: Nota: isso fica\nObservação: frase solta"
        let archive = try csv("Title,Date,Transcript\nA,2026-01-02,\"\(transcript)\"\n")
        let session = GranolaNoteMapper.session(from: archive.notes[0])
        #expect(session.turns.map(\.speakerName) == ["Ana", "Bruno", "Ana", "Bruno"])
        #expect(session.turns.last?.text == "Nota: isso fica Observação: frase solta")
    }

    @Test("Texto corrido sem falantes vira falas de tamanho legível, sem perder conteúdo")
    func csvPlainTranscript() throws {
        let sentence = "Uma frase de tamanho comum para o teste."
        let body = Array(repeating: sentence, count: 60).joined(separator: " ")
        let session = GranolaNoteMapper.session(from: try csv("Title,Date,Transcript\nA,2026-01-02,\"\(body)\"\n").notes[0])
        #expect(session.turns.count > 1)
        #expect(session.turns.allSatisfy { $0.text.count < 900 })
        #expect(session.turns.map(\.text).joined(separator: " ") == body)
    }

    @Test("Arquivo que não é do Granola é recusado, e não importado como lixo")
    func csvRejectsOtherFiles() {
        #expect(throws: GranolaCSVError.notAGranolaExport) { try csv("nome,valor\na,1\n") }
        #expect(throws: GranolaCSVError.notAGranolaExport) { try csv("") }
        #expect(throws: GranolaCSVError.unreadableFile) { try GranolaCSVArchive.parse(Data([0xFF, 0xFE, 0x00, 0xD8])) }
    }

    @Test("Linha sem data legível é contada e não entra")
    func csvUnreadableDates() async throws {
        GranolaAPIStub.reset()
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try fileWith("Title,Date,Summary\nBoa,2026-01-02,Texto\nRuim,ontem,Texto\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let importer = importer(store)
        importer.open(fileAt: url)
        await importer.waitForCurrentStep()
        guard case .ready(let plan) = importer.phase else { throw GranolaTestError.unexpectedPhase }
        #expect(plan.unreadable == 1)
        #expect(plan.lacksTranscripts)
        importer.startImport()
        await importer.waitForCurrentStep()
        #expect(try outcome(of: importer) == GranolaImportOutcome(imported: 1, failed: 1))
        #expect(GranolaAPIStub.recorded().isEmpty)
    }

    @Test("Arquivo recusado volta para a escolha do arquivo com o motivo")
    func csvRejectedFileReturnsToChoice() async throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try fileWith("nome,valor\na,1\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let importer = importer(store)
        importer.open(fileAt: url)
        await importer.waitForCurrentStep()
        #expect(importer.phase == .choosingFile(error: GranolaCSVError.notAGranolaExport.message))
    }

    @Test("O mesmo CSV duas vezes não duplica, nem CSV depois da API")
    func csvIsIdempotentAcrossRoutes() async throws {
        GranolaAPIStub.reset()
        serve(["not_a"], folder: nil)
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await runFullImport(importer(store))
        // O título e a data batem com a nota da API (Nota not_a, 13:04:05 UTC).
        let url = try fileWith("Title,Date,Summary\nNota not_a,2026-11-06T13:10:00Z,Texto\nOutra,2026-11-01,Texto\n")
        defer { try? FileManager.default.removeItem(at: url) }

        for expectedPending in [1, 0] {
            let run = importer(store)
            run.open(fileAt: url)
            await run.waitForCurrentStep()
            guard case .ready(let plan) = run.phase else { throw GranolaTestError.unexpectedPhase }
            #expect(plan.pending.count == expectedPending)
            run.startImport()
            await run.waitForCurrentStep()
        }
        #expect(store.sessions.count == 2)
    }

    // MARK: - Importação

    private func temporaryStore() -> (MeetingSessionStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Voiz-Granola-" + UUID().uuidString)
        return (MeetingSessionStore(baseURL: directory), directory)
    }

    private func gate(allowing allowed: Bool = true, tracker: VoizWorkTracker? = nil) -> VoizEditingGate {
        VoizEditingGate(authorize: { allowed }, currentLibrary: { nil }, tracker: tracker ?? VoizWorkTracker())
    }

    private func importer(_ store: MeetingSessionStore, gate: VoizEditingGate? = nil) -> GranolaImporter {
        let importer = GranolaImporter(store: store, makeClient: { _ in self.client() }, gate: gate ?? self.gate())
        importer.apiKey = Self.key
        return importer
    }

    private func serve(_ ids: [String], failing: Set<String> = [], folder: String? = "Clientes",
                       stoppingAt stop: String? = nil, deleted: Set<String> = []) {
        GranolaAPIStub.handler = { request in
            let path = try #require(request.url?.path)
            if path.hasSuffix("/notes") {
                return (200, [:], GranolaFixtures.listing(ids, hasMore: false, cursor: nil, deleted: deleted))
            }
            let id = (path as NSString).lastPathComponent
            if id == stop { return (401, [:], Data()) }
            if failing.contains(id) { return (404, [:], Data()) }
            return (200, [:], GranolaFixtures.note(id: id, folder: folder))
        }
    }

    private func outcome(of importer: GranolaImporter) throws -> GranolaImportOutcome {
        guard case .finished(let outcome) = importer.phase else { throw GranolaTestError.unexpectedPhase }
        return outcome
    }

    private func runFullImport(_ importer: GranolaImporter) async throws -> GranolaImportOutcome {
        importer.connect()
        await importer.waitForCurrentStep()
        importer.startImport()
        await importer.waitForCurrentStep()
        return try outcome(of: importer)
    }

    @Test("Importa, coloca na pasta e apaga a chave da memória ao terminar")
    func importsNotes() async throws {
        GranolaAPIStub.reset()
        serve(["not_a", "not_b"])
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let importer = importer(store)
        let result = try await runFullImport(importer)
        #expect(result == GranolaImportOutcome(imported: 2, failed: 0, stopReason: nil, cancelled: false))
        #expect(store.sessions.count == 2)
        #expect(store.folders.map(\.name) == ["Clientes"])
        #expect(store.sessions.allSatisfy { $0.folderId == store.folders[0].id })
        #expect(importer.apiKey.isEmpty)
    }

    @Test("Importar de novo não duplica nem desfaz o que foi editado no Voiz")
    func reimportKeepsEdits() async throws {
        GranolaAPIStub.reset()
        serve(["not_a"])
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await runFullImport(importer(store))
        var edited = try #require(store.sessions.first)
        edited.title = "Título meu"
        store.save(edited)

        serve(["not_a", "not_b"])
        let second = importer(store)
        second.connect()
        await second.waitForCurrentStep()
        guard case .ready(let plan) = second.phase else { throw GranolaTestError.unexpectedPhase }
        #expect(plan.pending.map(\.id) == ["not_b"])
        #expect(plan.alreadyInLibrary == 1)
        second.startImport()
        await second.waitForCurrentStep()
        #expect(store.sessions.count == 2)
        #expect(store.folders.count == 1)
        #expect(store.sessions.contains { $0.title == "Título meu" })
    }

    @Test("A pasta existente é reaproveitada, ignorando maiúsculas")
    func reusesExistingFolder() async throws {
        GranolaAPIStub.reset()
        serve(["not_a"], folder: "clientes")
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mine = store.createFolder(name: "Clientes")
        _ = try await runFullImport(importer(store))
        #expect(store.folders.count == 1)
        #expect(store.sessions.first?.folderId == mine.id)
    }

    @Test("Pasta única: tudo entra em Granola, inclusive nota sem pasta, e as pastas de lá não são criadas")
    func singleFolderPlacement() async throws {
        GranolaAPIStub.reset()
        serve(["not_a"], folder: "Clientes")
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = importer(store)
        first.folderPlacement = .singleFolder
        _ = try await runFullImport(first)

        serve(["not_a", "not_b"], folder: nil)
        let second = importer(store)
        second.folderPlacement = .singleFolder
        _ = try await runFullImport(second)

        #expect(store.folders.map(\.name) == [GranolaFolderPlacement.singleFolderName])
        #expect(store.sessions.count == 2)
        #expect(store.sessions.allSatisfy { $0.folderId == store.folders[0].id })
    }

    @Test("Pasta única reaproveita uma pasta Granola que já exista")
    func singleFolderReusesExisting() async throws {
        GranolaAPIStub.reset()
        serve(["not_a"])
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mine = store.createFolder(name: "granola")
        let importer = importer(store)
        importer.folderPlacement = .singleFolder
        _ = try await runFullImport(importer)
        #expect(store.folders.map(\.id) == [mine.id])
        #expect(store.sessions.first?.folderId == mine.id)
    }

    @Test("Sem admissão, a pasta única não é criada")
    func singleFolderNotCreatedWhenDenied() async throws {
        GranolaAPIStub.reset()
        serve(["not_a"])
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let importer = importer(store, gate: gate(allowing: false))
        importer.folderPlacement = .singleFolder
        _ = try await runFullImport(importer)
        #expect(store.folders.isEmpty)
    }

    @Test("Por padrão, mantém as pastas do Granola")
    func keepsGranolaFoldersByDefault() throws {
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(importer(store).folderPlacement == .keepGranolaFolders)
    }

    @Test("Nota apagada no Granola não entra")
    func skipsDeletedNotes() async throws {
        GranolaAPIStub.reset()
        serve(["not_a", "not_b"], deleted: ["not_b"])
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try await runFullImport(importer(store)).imported == 1)
    }

    @Test("Uma nota problemática é contada e não para as outras")
    func oneFailureDoesNotStopTheRest() async throws {
        GranolaAPIStub.reset()
        serve(["not_a", "not_b", "not_c"], failing: ["not_b"])
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await runFullImport(importer(store))
        #expect(result.imported == 2)
        #expect(result.failed == 1)
        #expect(result.isComplete)
    }

    @Test("Chave revogada no meio para na hora e mantém o que já entrou")
    func revokedKeyStopsAndKeepsProgress() async throws {
        GranolaAPIStub.reset()
        serve(["not_a", "not_b", "not_c"], stoppingAt: "not_b")
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await runFullImport(importer(store))
        #expect(result.imported == 1)
        #expect(result.stopReason == GranolaImportError.invalidKey.message)
        #expect(store.sessions.count == 1)
        #expect(!GranolaAPIStub.recorded().contains { $0.url?.path.hasSuffix("not_c") == true })
    }

    @Test("Chave recusada volta para a tela da chave com o motivo")
    func rejectedKeyReturnsToEntry() async {
        GranolaAPIStub.reset()
        GranolaAPIStub.handler = { _ in (401, [:], Data()) }
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let importer = importer(store)
        importer.connect()
        await importer.waitForCurrentStep()
        #expect(importer.phase == .enteringKey(error: GranolaImportError.invalidKey.message))
    }

    @Test("Parar no meio mantém o que já entrou")
    func cancellingKeepsProgress() async throws {
        GranolaAPIStub.reset()
        serve(["not_a", "not_b", "not_c"])
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let importer = importer(store)
        importer.connect()
        await importer.waitForCurrentStep()
        importer.startImport()
        importer.cancel()
        await importer.waitForCurrentStep()
        let result = try outcome(of: importer)
        #expect(result.cancelled)
        #expect(store.sessions.count == result.imported)
        #expect(result.imported < 3)
    }

    @Test("Sem admissão (licença, Sync ou biblioteca) nenhuma nota é baixada nem salva")
    func deniedAdmissionWritesNothing() async throws {
        GranolaAPIStub.reset()
        serve(["not_a", "not_b"])
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await runFullImport(importer(store, gate: gate(allowing: false)))
        #expect(result.imported == 0)
        #expect(result.stopReason != nil)
        #expect(!result.isComplete)
        #expect(store.sessions.isEmpty)
        #expect(!GranolaAPIStub.recorded().contains { $0.url?.path.hasSuffix("/not_a") == true })
    }

    @Test("A atividade fica aberta durante a importação e é encerrada no fim")
    func holdsWorkActivityWhileImporting() async throws {
        GranolaAPIStub.reset()
        let tracker = VoizWorkTracker()
        let observed = GranolaActivityLog()
        GranolaAPIStub.handler = { request in
            let path = try #require(request.url?.path)
            if path.hasSuffix("/notes") { return (200, [:], GranolaFixtures.listing(["not_a"], hasMore: false, cursor: nil)) }
            observed.mark()
            return (200, [:], GranolaFixtures.note(id: "not_a", folder: nil))
        }
        let (store, directory) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let importer = importer(store, gate: gate(tracker: tracker))
        importer.connect()
        await importer.waitForCurrentStep()
        #expect(!tracker.hasActiveWork)
        observed.onMark = { @MainActor in tracker.hasActiveWork }
        importer.startImport()
        await importer.waitForCurrentStep()
        #expect(await observed.sawActiveWork())
        #expect(!tracker.hasActiveWork)
    }

    @Test("Reunião importada e apagada no Sync não volta nem vira falha")
    func trashedInSyncIsLeftAlone() async throws {
        GranolaAPIStub.reset()
        serve(["not_a"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Voiz-Granola-Sync-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try SyncJournal(databaseURL: directory.appendingPathComponent("journal.sqlite"),
                                      accountID: "synthetic", collectionGeneration: SyncTestFixtures.generation)
        let context = SyncLibraryContext(libraryID: UUID(), ownerAccountID: "synthetic",
                                         collectionGeneration: SyncTestFixtures.generation,
                                         rootURL: directory, journal: journal)
        let suite = "Voiz.Granola.Tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = try SyncLibraryPersistence(
            context: context, settingsStore: SettingsStore(defaults: defaults, credentials: NoCredentials())
        )
        let store = MeetingSessionStore(sync: persistence)

        #expect(try await runFullImport(importer(store)).imported == 1)
        store.delete(try #require(store.sessions.first))
        #expect(store.sessions.isEmpty)

        let again = importer(store)
        again.connect()
        await again.waitForCurrentStep()
        guard case .ready(let plan) = again.phase else { throw GranolaTestError.unexpectedPhase }
        #expect(plan.pending.isEmpty)
        #expect(plan.alreadyInLibrary == 1)
    }
}

private enum GranolaTestError: Error { case unexpectedPhase }

nonisolated private struct NoCredentials: SettingsCredentialsPersisting {
    func read() throws -> SettingsCredentialRecord? { throw SettingsCredentialError.unavailable }
    func write(_ record: SettingsCredentialRecord) throws { throw SettingsCredentialError.unavailable }
}

/// O stub roda fora do main actor: registra a chegada e o teste consulta o tracker no main actor.
private final class GranolaActivityLog: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: Task<Bool, Never>?
    nonisolated(unsafe) var onMark: (@MainActor () -> Bool)?
    nonisolated func mark() {
        lock.withLock {
            let check = onMark
            pending = Task { @MainActor in check?() ?? false }
        }
    }
    nonisolated func sawActiveWork() async -> Bool {
        let task = lock.withLock { pending }
        return await task?.value ?? false
    }
}

private final class GranolaSleepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []
    nonisolated var values: [TimeInterval] { lock.withLock { recorded } }
    nonisolated func record(_ value: TimeInterval) { lock.withLock { recorded.append(value) } }
}

private enum GranolaFixtures {
    nonisolated static func listing(_ ids: [String], hasMore: Bool, cursor: String?, deleted: Set<String> = []) -> Data {
        let notes: [[String: Any]] = ids.map {
            ["id": $0, "object": "note", "title": "Nota", "owner": ["name": NSNull(), "email": "a@example.com"],
             "created_at": "2026-11-06T13:04:05.000Z", "updated_at": "2026-11-06T13:04:05.000Z",
             "deleted_at": deleted.contains($0) ? "2026-11-07T00:00:00.000Z" : NSNull()]
        }
        return try! JSONSerialization.data(withJSONObject: [
            "notes": notes, "hasMore": hasMore, "cursor": cursor as Any? ?? NSNull()
        ])
    }

    nonisolated static func segment(_ text: String) -> [String: Any] {
        ["speaker": ["source": "speaker", "attribution": "them"], "text": text,
         "start_time": "2026-11-06T13:04:05.000Z", "end_time": "2026-11-06T13:04:06.000Z"]
    }

    nonisolated static func note(id: String, folder: String?) -> Data {
        let folders: [[String: Any]] = folder.map {
            [["id": "fol_00000000000001", "object": "folder", "name": $0, "parent_folder_id": NSNull(), "space_id": NSNull()]]
        } ?? []
        return try! JSONSerialization.data(withJSONObject: [
            "id": id, "object": "note", "title": "Nota \(id)", "created_at": "2026-11-06T13:04:05.000Z",
            "calendar_event": NSNull(), "folder_membership": folders, "summary_text": "Resumo",
            "summary_markdown": "# Tópico\n\n- Item", "private_notes_text": NSNull(),
            "private_notes_markdown": NSNull(), "transcript": [segment("Olá")]
        ] as [String: Any])
    }

    nonisolated static func transcriptPage(text: String, cursor: String?) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "transcript": [segment(text)], "hasMore": cursor != nil, "cursor": cursor as Any? ?? NSNull()
        ])
    }
}

/// URLProtocol fake: sem DNS, sem rede. O handler decide status, cabeçalhos e corpo.
final class GranolaAPIStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, [String: String], Data))?
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    private static let lock = NSLock()

    nonisolated static func reset() {
        lock.withLock { handler = nil; requests = [] }
    }

    nonisolated static func recorded() -> [URLRequest] { lock.withLock { requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let handler = Self.lock.withLock {
            Self.requests.append(request)
            return Self.handler
        }
        do {
            let (status, headers, data) = try handler?(request) ?? (500, [:], Data())
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}
