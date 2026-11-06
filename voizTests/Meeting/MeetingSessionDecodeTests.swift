import Testing
import Foundation

/// O que a T2.5 acrescentou ao que está **no disco** — o snapshot do plano na sessão e a
/// proveniência no turno — não pode derrubar nenhuma reunião já gravada.
///
/// A aposta é assimétrica e é por isso que esta suíte existe: o `MeetingSessionStore` decodifica
/// cada `session.json` com `try?`, então um campo novo que lance apaga a reunião inteira da lista —
/// com áudio, transcript e resumo. Proveniência é diagnóstico; transcript é o produto.
@Suite("Reunião — sessões legadas continuam abrindo")
struct MeetingSessionDecodeTests {

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Uma sessão real de antes da T2.5, com o conjunto de chaves que o `MeetingSessionStore`
    /// gravava então — conferido contra os `session.json` desta máquina, sem copiar conteúdo
    /// nenhum: os textos abaixo são inventados (PLANO, regra 7 — nunca comitar transcript).
    ///
    /// Três detalhes que só um arquivo real ensina, e que um `MeetingSession()` recém-codificado
    /// não teria: `audioFiles` é um **array alternado** (`Dictionary` com chave enum não vira objeto
    /// JSON), o resumo está no formato **antigo de campos fixos** (que o `MeetingSummary` migra no
    /// decode) e não existem `pausedDuration`, `templateId`, `chapters`, `cleanMicFile`, `folderId`,
    /// `summaryModel` nem `summaryEffort`.
    private static let legacySessionJSON = """
    {
      "audioFiles" : ["systemAudio", "system-audio.caf", "microphone", "microphone.caf"],
      "endedAt" : "2026-02-11T14:41:03Z",
      "id" : "6C6A1B3E-9F44-4E71-9A0C-0E6F1B2D3A45",
      "notes" : "anotação do usuário",
      "sessionType" : "meeting",
      "speakers" : [
        { "id" : "microphone", "name" : "Você", "source" : "microphone" },
        { "id" : "systemAudio", "name" : "Participantes", "source" : "systemAudio" }
      ],
      "startedAt" : "2026-02-11T14:12:57Z",
      "summary" : {
        "actionItems" : ["ação inventada"],
        "decisions" : [],
        "followUps" : [],
        "interviewSignals" : [],
        "keyPoints" : ["ponto inventado"],
        "summary" : "conteúdo inventado para o teste",
        "title" : "Título inventado"
      },
      "systemAudioWarning" : "Permissão de captura de tela ausente",
      "title" : "Reunião de teste",
      "turns" : [
        {
          "confidence" : -0.3210,
          "endTime" : 12.5,
          "id" : "1D9B1C2A-7B33-4F52-8E10-2A4C6D8E0F11",
          "source" : "microphone",
          "speakerName" : "Você",
          "startTime" : 0.4,
          "text" : "fala inventada do microfone"
        },
        {
          "confidence" : -0.4111,
          "endTime" : 30.0,
          "id" : "2E8C4D6B-1A55-4C33-9B77-3F5E7A9C1D22",
          "source" : "systemAudio",
          "speakerName" : "Participantes",
          "startTime" : 13.0,
          "text" : "fala inventada do sistema"
        }
      ]
    }
    """

    @Test("Sessão gravada antes da T2.5 abre inteira, com os campos novos vazios")
    func aLegacySessionStillDecodes() throws {
        let session = try Self.decoder().decode(
            MeetingSession.self,
            from: Data(Self.legacySessionJSON.utf8)
        )

        #expect(session.turns.count == 2)
        #expect(session.title == "Reunião de teste")
        // O resumo antigo (campos fixos) continua migrando para seções no decode.
        #expect(session.summary?.sections.count == 3)
        #expect(session.audioFiles[.microphone] == "microphone.caf")

        // Os dois campos da T2.5, ausentes no disco antigo:
        #expect(session.transcriptionPlan == nil)
        #expect(session.turns.allSatisfy { $0.provenance == nil })
    }

    @Test("Sem snapshot, o pós-processamento cai no caminho de antes da T2.5")
    func aLegacySessionHasNoBatchPlan() throws {
        // É a ponta que amarra o decode ao comportamento: sessão legada não tem plano gravado, e
        // `batchPlan(from:)` responde `nil` — que o view model lê como "monte com os Ajustes
        // atuais", exatamente o que o app fazia antes desta tarefa.
        let session = try Self.decoder().decode(
            MeetingSession.self,
            from: Data(Self.legacySessionJSON.utf8)
        )
        #expect(MeetingTranscription.batchPlan(from: session.transcriptionPlan) == nil)
    }

    @Test("Round-trip de uma sessão nova: plano e proveniência voltam intactos")
    func aSessionWithPlanAndProvenanceRoundTrips() throws {
        var session = try Self.decoder().decode(
            MeetingSession.self,
            from: Data(Self.legacySessionJSON.utf8)
        )
        session.transcriptionPlan = TranscriptionPlanSnapshot(
            language: .portugueseBrazil,
            candidates: [
                TranscriptionPlanSnapshot.Candidate(
                    engine: .whisperKit, model: .whisperMedium, rank: 0, origin: .userSelection
                ),
                TranscriptionPlanSnapshot.Candidate(
                    engine: .parakeet, model: .parakeetTDT06BV3, rank: 1, origin: .automatic
                )
            ],
            isStrict: false,
            createdAt: Date(timeIntervalSince1970: 1_770_000_000)
        )
        session.turns[0].provenance = TranscriptionProvenance(
            engine: .whisperKit,
            model: .whisperMedium,
            useCase: .meetingFinal,
            origin: .userSelection,
            candidateRank: 0
        )

        let data = try Self.encoder().encode(session)
        let decoded = try Self.decoder().decode(MeetingSession.self, from: data)

        #expect(decoded == session)
        #expect(decoded.transcriptionPlan?.candidates.count == 2)
        #expect(decoded.turns[0].provenance?.model == .whisperMedium)
        #expect(decoded.turns[1].provenance == nil)
    }

    @Test("Turno sem proveniência não engorda o JSON")
    func aTurnWithoutProvenanceOmitsTheKey() throws {
        let turn = MeetingTurn(
            source: .microphone,
            speakerName: "Você",
            text: "x",
            startTime: 0,
            endTime: 1
        )
        let json = String(data: try Self.encoder().encode(turn), encoding: .utf8) ?? ""
        #expect(json.contains("provenance") == false)
    }

    @Test("Proveniência que esta versão não entende vira nil — o turno sobrevive")
    func anUnreadableProvenanceDoesNotDropTheTurn() throws {
        // O cenário: uma versão futura grava um caso de uso (ou uma origem) que esta não conhece, e
        // o usuário volta para esta. Sem o decode tolerante, `TranscriptionProvenance` lançaria, o
        // `MeetingTurn` lançaria junto e o `try?` do store apagaria a reunião.
        let json = """
        {
          "confidence" : -0.2,
          "endTime" : 4.0,
          "id" : "3A7D5E1C-8B22-4D44-8C99-4E6F8B0D2E33",
          "provenance" : {
            "candidateRank" : 0,
            "engine" : "whisperkit",
            "model" : "openai_whisper-small",
            "origin" : "automatic",
            "useCase" : "algoQueAindaNaoExiste"
          },
          "source" : "microphone",
          "speakerName" : "Você",
          "startTime" : 1.0,
          "text" : "fala inventada"
        }
        """
        let turn = try Self.decoder().decode(MeetingTurn.self, from: Data(json.utf8))
        #expect(turn.provenance == nil)
        #expect(turn.text == "fala inventada")
        #expect(turn.startTime == 1.0)
    }

    @Test("O que é produto continua obrigatório: turno sem texto ainda reprova o decode")
    func aTurnWithoutTextStillThrows() {
        // O decode manual do `MeetingTurn` existe para tolerar **um** campo. Engolir os demais
        // esconderia corrupção real em vez de preservar transcript.
        let json = """
        {
          "confidence" : 0,
          "endTime" : 4.0,
          "id" : "3A7D5E1C-8B22-4D44-8C99-4E6F8B0D2E33",
          "source" : "microphone",
          "speakerName" : "Você",
          "startTime" : 1.0
        }
        """
        #expect(throws: (any Error).self) {
            try Self.decoder().decode(MeetingTurn.self, from: Data(json.utf8))
        }
    }

    @Test("Snapshot com FORMA inválida não leva a sessão junto")
    func aSnapshotWithTheWrongShapeDoesNotDropTheSession() throws {
        // O MAIOR das duas reviews da T2.5, e o caso que o teste ao lado (objeto com valores
        // desconhecidos) NÃO cobria: chave presente com valor que não é objeto. É o que uma versão
        // futura que mude a forma do campo — ou um JSON remendado — produz, e o `try?` do store
        // transformaria em reunião que some da lista.
        for value in ["\"plano-do-futuro\"", "7", "[\"whisperkit\"]"] {
            let json = Self.legacySessionJSON.replacingOccurrences(
                of: "\"title\" : \"Reunião de teste\",",
                with: "\"title\" : \"Reunião de teste\",\n  \"transcriptionPlan\" : \(value),"
            )
            let session = try Self.decoder().decode(MeetingSession.self, from: Data(json.utf8))

            #expect(session.turns.count == 2, "forma \(value) derrubou os turns")
            #expect(session.summary != nil)
            // Degradado para vazio ⇒ tratado como "sessão sem plano": o pós-call monta com os
            // Ajustes atuais, que é o comportamento legado.
            #expect(MeetingTranscription.batchPlan(from: session.transcriptionPlan) == nil)
        }
    }

    @Test("Um snapshot ilegível não leva a sessão junto")
    func aBrokenSnapshotDoesNotDropTheSession() throws {
        let json = Self.legacySessionJSON.replacingOccurrences(
            of: "\"title\" : \"Reunião de teste\",",
            with: """
            "title" : "Reunião de teste",
              "transcriptionPlan" : {
                "useCase" : "casoDeUsoDoFuturo",
                "isStrict" : false,
                "candidates" : [ { "engine" : "motor-do-futuro" } ]
              },
            """
        )
        let session = try Self.decoder().decode(MeetingSession.self, from: Data(json.utf8))

        #expect(session.turns.count == 2)
        // O snapshot decodifica degradado (sem candidato utilizável), e o pós-processamento trata
        // isso como "sessão sem plano": monta com os Ajustes atuais em vez de recusar a reunião.
        #expect(MeetingTranscription.batchPlan(from: session.transcriptionPlan) == nil)
    }

    /// Forma persistida depois da T2.5 + modo Granola (chaves novas, textos inventados).
    /// `audioFiles` continua array alternado — o store nunca gravou objeto JSON nessa chave.
    private static let granolaSessionJSON = """
    {
      "audioFiles" : ["systemAudio", "system-audio.caf", "microphone", "microphone.caf"],
      "endedAt" : "2026-08-17T18:00:00Z",
      "id" : "A1B2C3D4-E5F6-4789-ABCD-EF0123456789",
      "isProcessingCompleted" : true,
      "meetingMode" : "granola",
      "notes" : "",
      "sessionType" : "meeting",
      "speakers" : [
        { "id" : "microphone", "name" : "Você", "source" : "microphone" },
        { "id" : "systemAudio", "name" : "Eles", "source" : "systemAudio" }
      ],
      "startedAt" : "2026-08-17T17:40:00Z",
      "title" : "Reunião Granola inventada",
      "transcriptionPlan" : {
        "candidates" : [
          {
            "engine" : "apple-speech-analyzer",
            "model" : "apple-system-speech.pt-BR",
            "origin" : "automatic",
            "rank" : 0
          }
        ],
        "createdAt" : "2026-08-17T17:40:00Z",
        "isStrict" : false,
        "language" : "pt",
        "useCase" : "meetingFinal"
      },
      "turns" : [
        {
          "confidence" : -0.2,
          "endTime" : 8.0,
          "id" : "B2C3D4E5-F6A7-4890-BCDE-F01234567890",
          "source" : "microphone",
          "speakerName" : "Você",
          "startTime" : 0.2,
          "text" : "fala inventada do microfone"
        }
      ]
    }
    """

    @Test("Sessão no formato Granola (meetingMode + isProcessingCompleted) abre")
    func aGranolaShapedSessionStillDecodes() throws {
        let session = try Self.decoder().decode(
            MeetingSession.self,
            from: Data(Self.granolaSessionJSON.utf8)
        )
        #expect(session.meetingMode == .granola)
        #expect(session.isProcessingCompleted == true)
        #expect(session.turns.count == 1)
        #expect(session.transcriptionPlan?.useCase == .meetingFinal)
        #expect(MeetingTranscription.batchPlan(from: session.transcriptionPlan) != nil)
    }

    /// Sessão inteira no layout do store cuja proveniência tem rawValue futuro.
    ///
    /// Distinto das três outras fixtures (chave `provenance` **ausente**): aqui a chave
    /// **existe** e é ilegível. Sem o `try?` no decode do `MeetingTurn`, o `try?` do
    /// `MeetingSessionStore` apaga a reunião — é a mutação que este walker precisa morder.
    private static let illegibleProvenanceSessionID = UUID(
        uuidString: "C3D4E5F6-A7B8-4901-CDEF-012345678901"
    )!

    private static let illegibleProvenanceSessionJSON = """
    {
      "audioFiles" : ["microphone", "microphone.caf"],
      "endedAt" : "2026-08-18T12:00:00Z",
      "id" : "C3D4E5F6-A7B8-4901-CDEF-012345678901",
      "notes" : "",
      "sessionType" : "meeting",
      "speakers" : [
        { "id" : "microphone", "name" : "Você", "source" : "microphone" }
      ],
      "startedAt" : "2026-08-18T11:50:00Z",
      "title" : "Reunião inventada com proveniência futura",
      "turns" : [
        {
          "confidence" : -0.2,
          "endTime" : 4.0,
          "id" : "D4E5F6A7-B8C9-4012-DEF0-123456789012",
          "provenance" : {
            "candidateRank" : 0,
            "engine" : "whisperkit",
            "model" : "openai_whisper-small",
            "origin" : "automatic",
            "useCase" : "algoQueAindaNaoExiste"
          },
          "source" : "microphone",
          "speakerName" : "Você",
          "startTime" : 1.0,
          "text" : "fala inventada"
        }
      ]
    }
    """

    // MARK: - Walker (layout do store, sem dados reais)

    /// O mesmo layout que o `MeetingSessionStore` grava: `Voiz/Meetings/<uuid>/session.json`.
    /// Roda sempre, contra fixtures sintéticas, com teto no I/O — é o que o gate reproduz.
    @Test("Walker do store decodifica legado, plano T2.5, Granola e proveniência ilegível")
    func syntheticStoreLayoutStillDecodes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiz-decode-fixtures-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Self.writeSessionJSON(Self.legacySessionJSON, named: "legacy", under: root)
        try Self.writeSessionJSON(Self.granolaSessionJSON, named: "granola", under: root)
        try Self.writeSessionJSON(
            Self.illegibleProvenanceSessionJSON,
            named: "illegible-provenance",
            under: root
        )
        var withPlan = try Self.decoder().decode(
            MeetingSession.self,
            from: Data(Self.legacySessionJSON.utf8)
        )
        withPlan.transcriptionPlan = TranscriptionPlanSnapshot(
            language: .portugueseBrazil,
            candidates: [
                TranscriptionPlanSnapshot.Candidate(
                    engine: .whisperKit, model: .whisperSmall, rank: 0, origin: .userSelection
                )
            ],
            isStrict: false,
            createdAt: Date(timeIntervalSince1970: 1_770_000_000)
        )
        let planned = try Self.encoder().encode(withPlan)
        try Self.writeSessionData(planned, named: "planned", under: root)

        let report = try Self.decodeSessions(in: [root], listingTimeout: 2)
        #expect(report.timedOutRoots.isEmpty)
        #expect(report.failedDirectoryNames.isEmpty)
        #expect(report.decoded == 4)

        // O walker — não só o unitário do turno — tem de ver a reunião ilegível
        // sobreviver com o turno intacto e provenance == nil. Mutar
        // `try? decodeIfPresent(provenance)` → `try` faz esta sessão ir para
        // `failedDirectoryNames` e some deste digest.
        let illegible = report.digests.first { $0.id == Self.illegibleProvenanceSessionID }
        #expect(illegible != nil, "walker não viu a sessão com proveniência ilegível")
        #expect(illegible?.turnCount == 1)
        #expect(illegible?.turnsWithNilProvenance == 1)
    }

    // MARK: - Varredura real (opt-in, nunca no gate)

    /// Liga no **worker** do xcodebuild — `VOIZ_DECODE_REAL_SESSIONS=1` no processo ou
    /// como build setting **não chega** ao xctest. Argumento `TEST_RUNNER_…=1` no fim
    /// da linha do xcodebuild também **não** basta (vira build setting). O encaminhamento
    /// documentado pelo `man xcodebuild` é o prefixo no **ambiente do processo** (ele é
    /// removido antes de entrar no worker). Comando que de fato liga o opt-in:
    ///
    /// ```
    /// TEST_RUNNER_VOIZ_DECODE_REAL_SESSIONS=1 xcodebuild test \
    ///   -project voiz.xcodeproj -scheme voiz \
    ///   -destination 'platform=macOS' \
    ///   -only-testing:'voizTests/MeetingSessionDecodeTests/realSessionsOnThisMachineStillDecode()'
    /// ```
    ///
    /// Enumerar o Meetings do **container** pendura o runner em clones `/private/tmp` (TCC:
    /// assinatura nova do xctest após rebuild, prompt que o xcodebuild headless nunca mostra).
    /// O app do Desktop assinado "Voiz Dev" mantém o grant entre rebuilds — o hang é do
    /// runner, não do produto. `ls -ld` do diretório responde; `contentsOfDirectory` é
    /// que trava. Sem teto isso é 0% CPU eterno; com teto falha em 2 s por raiz.
    // nonisolated: o trait `.enabled` avalia isto num closure Sendable, fora do MainActor.
    nonisolated static let realSessionsEnvironmentKey = "VOIZ_DECODE_REAL_SESSIONS"

    /// Motivo visível no xcresult quando o opt-in está desligado — diz COMO ligar,
    /// não só "Test skipped".
    nonisolated static let realSessionsOptInSkipComment: Comment = """
    skip: ligue com TEST_RUNNER_VOIZ_DECODE_REAL_SESSIONS=1 no ambiente do xcodebuild \
    (VOIZ_DECODE_REAL_SESSIONS sozinho, ou TEST_RUNNER_ como argumento, NÃO chega ao worker). \
    Ex.: TEST_RUNNER_VOIZ_DECODE_REAL_SESSIONS=1 xcodebuild test \
    -project voiz.xcodeproj -scheme voiz -destination 'platform=macOS' \
    -only-testing:'voizTests/MeetingSessionDecodeTests/realSessionsOnThisMachineStillDecode()'
    """

    @Test(
        "OPT-IN — reuniões reais desta máquina continuam decodificando",
        .enabled(
            if: ProcessInfo.processInfo.environment[Self.realSessionsEnvironmentKey] == "1",
            Self.realSessionsOptInSkipComment
        )
    )
    func realSessionsOnThisMachineStillDecode() throws {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let roots = [
            FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first,
            home
                .appending(path: "Library/Containers/com.rmb.voiz/Data/Library/Application Support")
        ].compactMap { $0 }

        let report = try Self.decodeSessions(in: roots, listingTimeout: 2)
        if !report.timedOutRoots.isEmpty {
            // Aviso, não falha: nesta máquina o container pendura em TCC e a outra
            // raiz (Application Support do usuário) decodifica. Falhar o opt-in
            // inteiro por uma raiz bloqueada tornava o comando inacionável.
            // Falha só se NADA foi decodificado (abaixo).
            Issue.record(
                """
                enumerar Meetings travou em \(report.timedOutRoots.count) raiz(es) \
                (teto 2s). Hipótese: TCC do runner de teste/clone em /private/tmp \
                (assinatura muda a cada rebuild; o prompt não aparece no xcodebuild \
                headless). O app Desktop com cert Voiz Dev mantém o grant. Isto NÃO \
                é regressão de decode. Raízes que responderam ainda são decodificadas.
                """,
                severity: .warning
            )
        }
        #expect(
            report.failedDirectoryNames.isEmpty,
            "sessões reais que pararam de decodificar: \(report.failedDirectoryNames)"
        )
        #expect(
            report.decoded > 0,
            report.timedOutRoots.isEmpty
                ? "opt-in ligado mas 0 sessões no disco"
                : "TCC/enumeração pendurada em toda raiz e 0 sessões decodificadas (teto 2s)"
        )
        print("sessões reais decodificadas: \(report.decoded)")
    }

    // MARK: - Apoio do walker

    /// Resumo sem texto: o walker nunca carrega transcript para asserção/log.
    private struct DecodedSessionDigest: Sendable {
        var id: UUID
        var turnCount: Int
        var turnsWithNilProvenance: Int
    }

    private struct DecodeWalkReport: Sendable {
        var decoded = 0
        var failedDirectoryNames: [String] = []
        var timedOutRoots: [String] = []
        var digests: [DecodedSessionDigest] = []
    }

    /// Percorre `Voiz/Meetings/<id>/session.json` em cada raiz. Nunca imprime texto da sessão.
    private static func decodeSessions(
        in roots: [URL],
        listingTimeout: TimeInterval
    ) throws -> DecodeWalkReport {
        var report = DecodeWalkReport()
        for root in roots {
            let base = root
                .appendingPathComponent("Voiz", isDirectory: true)
                .appendingPathComponent("Meetings", isDirectory: true)
            switch listDirectories(at: base, timeout: listingTimeout) {
            case .missing:
                continue
            case .timedOut:
                report.timedOutRoots.append(base.lastPathComponent)
            case .listed(let directories):
                for directory in directories {
                    let url = directory.appendingPathComponent("session.json")
                    guard let data = try? Data(contentsOf: url) else { continue }
                    do {
                        let session = try decoder().decode(MeetingSession.self, from: data)
                        report.decoded += 1
                        report.digests.append(
                            DecodedSessionDigest(
                                id: session.id,
                                turnCount: session.turns.count,
                                turnsWithNilProvenance: session.turns.filter { $0.provenance == nil }.count
                            )
                        )
                        if let plan = session.transcriptionPlan {
                            #expect(plan.useCase == .meetingFinal)
                        }
                    } catch {
                        report.failedDirectoryNames.append(directory.lastPathComponent)
                    }
                }
            }
        }
        return report
    }

    fileprivate enum DirectoryList: Sendable {
        case missing
        case listed([URL])
        case timedOut
    }

    /// `stat`/`fileExists` do Meetings responde; `contentsOfDirectory` é o que pendura no TCC.
    private static func listDirectories(at url: URL, timeout: TimeInterval) -> DirectoryList {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return .missing }

        let box = DirectoryListBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let urls = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            box.value = .listed(urls ?? [])
            group.leave()
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            return .timedOut
        }
        return box.value ?? .missing
    }

    private static func writeSessionJSON(_ json: String, named name: String, under root: URL) throws {
        try writeSessionData(Data(json.utf8), named: name, under: root)
    }

    private static func writeSessionData(_ data: Data, named name: String, under root: URL) throws {
        let directory = root
            .appendingPathComponent("Voiz", isDirectory: true)
            .appendingPathComponent("Meetings", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("session.json"), options: .atomic)
    }
}

/// Caixa para o `contentsOfDirectory` fora da thread do teste — o hang do TCC é síncrono.
private final class DirectoryListBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: MeetingSessionDecodeTests.DirectoryList?

    var value: MeetingSessionDecodeTests.DirectoryList? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
