import Foundation

// A lógica pura da transcrição pós-call da reunião (T2.5).
//
// Mesmo desenho da `DictationTranscription` (T2.4a) e pelo mesmo motivo: o `MeetingViewModel` é
// `@MainActor`, fala com o `MeetingCaptureService`, com o notch e com o disco, e o alvo `voizTests`
// não tem host app de propósito (DECISOES, 2026-08-07). Então tudo que é **decisão** sai de lá e
// vem para cá — congelar o plano no início da reunião, decidir o que os lotes seguintes tentam
// depois de uma falha, atribuir a proveniência de um turno que cresceu com mais de um lote. O que
// sobra no view model é I/O e UI.
//
// Como os contratos da T1.2, este arquivo depende **só de Foundation** e é `nonisolated` de ponta a
// ponta: ele compila nos dois alvos, e o alvo do app usa `SWIFT_DEFAULT_ACTOR_ISOLATION =
// MainActor`.

/// O plano de transcrição **congelado no início da reunião**, na forma que a sessão persiste.
///
/// ## Por que congelar
///
/// Os lotes do transcript oficial só rodam **depois** da chamada, e podem levar minutos. Entre
/// apertar gravar e o último lote, o usuário pode abrir as Configurações e trocar o modelo — e o
/// transcript de uma mesma reunião sairia metade num motor e metade em outro, sem nada explicando a
/// diferença. O código legado já protegia isso à mão, com três campos (`recordingEngine`,
/// `recordingWhisperModelName`, `recordingLanguage`) fixados no `startMeeting`; o snapshot é o
/// mesmo princípio com a decisão inteira do roteador dentro, e persistido — um pós-call retomado
/// depois de o app fechar continua seguindo o plano da reunião, não os Ajustes de hoje.
///
/// ## O que ele NÃO guarda
///
/// As `rejections` do plano (por que cada motor ficou de fora) ficam de fora de propósito: elas são
/// diagnóstico de UI da Onda 6, valem para o instante em que o roteador decidiu, e ressuscitá-las
/// meses depois seria ficção — o hardware, os assets e o catálogo podem ter mudado. O que o
/// snapshot promete é a **ordem de tentativa**, que é o que faz dois lotes da mesma reunião
/// caírem no mesmo motor.
///
/// ## Decode tolerante
///
/// Ele mora dentro do `MeetingSession`, e um `throw` aqui derruba a **sessão inteira** (o
/// `MeetingSessionStore` decodifica com `try?` por arquivo: a reunião some da lista, com áudio,
/// turns e resumo). Por isso nada aqui lança por valor desconhecido — é a mesma disciplina da T1.4
/// e da T2.4a, levada ao caso em que o custo de um campo novo derrubar o decode é o mais alto do
/// app.
nonisolated struct TranscriptionPlanSnapshot: Sendable, Equatable, Codable {

    /// Um candidato do plano, na forma persistível.
    ///
    /// É uma cópia de `TranscriptionRoutingCandidate` em vez de uma conformance `Codable` naquele
    /// tipo porque o que se persiste tem regra de compatibilidade própria (decode tolerante, campos
    /// que só podem crescer) e o contrato da T1.2 não deve carregar essa dívida.
    nonisolated struct Candidate: Sendable, Equatable, Codable {
        var engine: TranscriptionEngineID
        var model: TranscriptionModelID
        /// 0 = primeira escolha do plano; 1+ = fallback, na ordem de tentativa.
        var rank: Int
        var origin: TranscriptionSelectionOrigin

        init(
            engine: TranscriptionEngineID,
            model: TranscriptionModelID,
            rank: Int,
            origin: TranscriptionSelectionOrigin
        ) {
            self.engine = engine
            self.model = model
            self.rank = rank
            self.origin = origin
        }

        init(_ candidate: TranscriptionRoutingCandidate) {
            self.init(
                engine: candidate.engine,
                model: candidate.model,
                rank: candidate.rank,
                origin: candidate.origin
            )
        }

        var routingCandidate: TranscriptionRoutingCandidate {
            TranscriptionRoutingCandidate(engine: engine, model: model, rank: rank, origin: origin)
        }

        /// `origin` e `rank` são tolerantes; `engine` e `model` não, porque sem eles não há
        /// candidato nenhum — e um elemento que falha some sozinho, sem levar o resto do plano
        /// (ver `TranscriptionPlanSnapshot.init(from:)`).
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            engine = try container.decode(TranscriptionEngineID.self, forKey: .engine)
            model = try container.decode(TranscriptionModelID.self, forKey: .model)
            rank = (try? container.decodeIfPresent(Int.self, forKey: .rank)).flatMap { $0 } ?? 0
            origin = (try? container.decodeIfPresent(TranscriptionSelectionOrigin.self, forKey: .origin))
                .flatMap { $0 } ?? .automatic
        }
    }

    /// Para que este plano foi montado. Sempre `.meetingFinal` no código de hoje — o campo existe
    /// para que um snapshot de outro caso de uso, se um dia for gravado aqui por engano, seja
    /// **detectável** em vez de virar `planMismatch` dentro do coordenador (ver
    /// `MeetingTranscription.batchPlan(from:)`).
    var useCase: TranscriptionUseCase
    /// De onde veio o idioma do plano. Snapshots novos sempre gravam
    /// `explicit` ou `autoAdopted`. Ausente/desconhecido no decode vira
    /// `.unresolved` e resolve **uma vez** contra os Ajustes daquela passagem
    /// — o snapshot com a origem resolvida é persistido imediatamente
    /// (DECISOES r4). Origem gravada nunca se reinterpreta.
    nonisolated enum LanguageOrigin: String, Codable, Sendable, Equatable {
        case explicit
        case autoAdopted
        case unresolved
    }

    /// O idioma falado fixado no início da reunião; `nil` = detecção automática.
    ///
    /// Anda com o plano porque é parte da mesma promessa: trocar o idioma nas Configurações no meio
    /// da reunião não pode mudar o pedido dos lotes que ainda faltam.
    var language: TranscriptionLanguage?
    /// Proveniência do `language`. A guarda lê **isto**, nunca `language != nil`.
    var languageOrigin: LanguageOrigin
    /// Candidatos na ordem de tentativa.
    var candidates: [Candidate]
    /// O plano foi montado sob `strictEngineSelection`.
    var isStrict: Bool
    /// Quando o plano foi congelado. Diagnóstico — é o que permite ler uma sessão antiga e saber
    /// que aquele plano é de antes de uma mudança de catálogo.
    var createdAt: Date

    init(
        useCase: TranscriptionUseCase = .meetingFinal,
        language: TranscriptionLanguage?,
        languageOrigin: LanguageOrigin = .explicit,
        candidates: [Candidate],
        isStrict: Bool,
        createdAt: Date = Date()
    ) {
        self.useCase = useCase
        self.language = language
        self.languageOrigin = languageOrigin
        self.candidates = candidates
        self.isStrict = isStrict
        self.createdAt = createdAt
    }

    /// O snapshot de um plano recém-montado pelo roteador.
    init(
        plan: TranscriptionRoutingPlan,
        language: TranscriptionLanguage?,
        languageOrigin: LanguageOrigin = .explicit,
        createdAt: Date = Date()
    ) {
        self.init(
            useCase: plan.useCase,
            language: language,
            languageOrigin: languageOrigin,
            candidates: plan.candidates.map(Candidate.init),
            isStrict: plan.isStrict,
            createdAt: createdAt
        )
    }

    /// O plano do roteador de volta, para o coordenador executar.
    ///
    /// Ordenado por `rank` porque é o rank que define a ordem de tentativa, e um JSON editado à mão
    /// (ou um encode futuro que não preserve ordem) não pode inverter fallback e primeira escolha.
    var routingPlan: TranscriptionRoutingPlan {
        TranscriptionRoutingPlan(
            useCase: useCase,
            candidates: candidates.sorted { $0.rank < $1.rank }.map(\.routingCandidate),
            rejections: [],
            isStrict: isStrict
        )
    }

    var primary: Candidate? {
        candidates.min { $0.rank < $1.rank }
    }

    var isEmpty: Bool { candidates.isEmpty }

    /// Uma linha de log com o plano inteiro — só ids de motor e modelo, nunca texto.
    var logSummary: String {
        let ordered = candidates.sorted { $0.rank < $1.rank }
        guard !ordered.isEmpty else { return "plano vazio" }
        let described = ordered.map { "\($0.engine)/\($0.model)" }.joined(separator: " → ")
        return isStrict ? "\(described) (estrito)" : described
    }

    private enum CodingKeys: String, CodingKey {
        case useCase
        case language
        case languageOrigin
        case candidates
        case isStrict
        case createdAt
    }

    /// Nada aqui lança — nem por valor desconhecido, nem por **forma** desconhecida.
    ///
    /// - **A forma**: se o valor gravado não for um objeto (string, número, array — versão futura
    ///   que mude o campo, JSON editado à mão, arquivo truncado e remendado), `container(keyedBy:)`
    ///   lançaria `typeMismatch`, e como `MeetingSession` decodifica sintetizado esse `throw` sobe
    ///   pelo `init(from:)` da sessão até o `try?` do `MeetingSessionStore` — que transforma o
    ///   problema em **reunião que some da lista**, com áudio, turns e resumo. Foi o MAIOR das duas
    ///   reviews da T2.5, e a versão anterior deste decode prometia tolerância que a primeira linha
    ///   já não cumpria. Forma inválida degrada para snapshot **vazio**, que é o mesmo que "sem
    ///   snapshot" para `MeetingTranscription.batchPlan(from:)`: comportamento de sessão legada.
    /// - `useCase` desconhecido cai em `.meetingFinal`: este campo só existe dentro de uma sessão de
    ///   reunião, então um rawValue que esta versão não conhece veio de uma versão futura e ainda
    ///   assim descreve o plano dos lotes **desta** reunião.
    /// - `candidates` é decodificado elemento a elemento: um candidato corrompido some sozinho em
    ///   vez de zerar o plano.
    init(from decoder: any Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            self.init(language: nil, candidates: [], isStrict: false, createdAt: Self.unknownDate)
            return
        }
        let decodedCandidates = (try? container.decodeIfPresent([FailableCandidate].self, forKey: .candidates))
            .flatMap { $0 } ?? []
        let originRaw = (try? container.decodeIfPresent(String.self, forKey: .languageOrigin))
            .flatMap { $0 }
        self.init(
            useCase: (try? container.decodeIfPresent(TranscriptionUseCase.self, forKey: .useCase))
                .flatMap { $0 } ?? .meetingFinal,
            language: (try? container.decodeIfPresent(TranscriptionLanguage.self, forKey: .language))
                .flatMap { $0 },
            languageOrigin: originRaw.flatMap(LanguageOrigin.init(rawValue:)) ?? .unresolved,
            candidates: decodedCandidates.compactMap(\.value),
            isStrict: (try? container.decodeIfPresent(Bool.self, forKey: .isStrict)).flatMap { $0 } ?? false,
            createdAt: (try? container.decodeIfPresent(Date.self, forKey: .createdAt))
                .flatMap { $0 } ?? Self.unknownDate
        )
    }

    /// A data de um snapshot que não trouxe (ou não pôde trazer) a dela. Não é "agora" de propósito:
    /// carimbar o instante do decode faria um plano ilegível parecer recém-criado.
    private static let unknownDate = Date(timeIntervalSince1970: 0)

    /// Um candidato que pode não decodificar, sem levar o array junto.
    private struct FailableCandidate: Decodable {
        var value: Candidate?

        init(from decoder: any Decoder) throws {
            value = try? Candidate(from: decoder)
        }
    }
}

/// As decisões da transcrição pós-call da reunião que não dependem de tela, de áudio nem de disco.
nonisolated enum MeetingTranscription {

    // MARK: - Política de retry dos lotes

    /// A política que **todo** pedido da reunião usa — no `transcribe` e no `warmUp`.
    ///
    /// É a `TranscriptionRetryPolicy.meetingBatch` que a T2.3 já deixou pronta, nomeada aqui para o
    /// view model não escolher política por conta própria e para a suíte travar as três
    /// propriedades que importam:
    ///
    /// 1. **`attemptsPerCandidate == 2`** — o "retry 1× por lote" do PLANO. Uma segunda tentativa do
    ///    mesmo candidato antes de passar ao próximo do snapshot.
    /// 2. **`failureCooldown` infinito** — a supressão dura a reunião inteira. Com os 300 s do
    ///    default, uma reunião de ~7 min ganharia exatamente uma retentativa no meio dela, e o
    ///    `runLoad` dos motores evicta o residente ANTES de tentar carregar o novo: o lote que
    ///    calhasse de disparar o retry perderia o modelo de fallback que estava servindo e o
    ///    seguinte pagaria uma recarga inteira (análise da Quilha, registrada no doc do tipo).
    /// 3. **`recordsGlobalFailure == true`** — e é por isso que os lotes **não** usam
    ///    `.silentInteractive`. O aviso da Quilha na re-review r2 da T2.4b: para um consumidor que
    ///    não escreve `latchedModels`, `clearingLatch` nunca é acionado, e `unload()` é o único
    ///    caminho contratual para limpar o latch do motor — então **não há vencimento de cooldown**
    ///    e uma falha transitória de preparação mataria a reunião inteira. Na tradução isso é
    ///    paridade com o legado e é aceitável; num lote não é: falha de reunião tem que suprimir
    ///    para todos.
    static let batchRetryPolicy = TranscriptionRetryPolicy.meetingBatch

    // MARK: - O plano da reunião

    /// O plano que os lotes desta sessão devem executar — `nil` quando não há snapshot utilizável.
    ///
    /// `nil` significa exatamente "faça como antes da T2.5": quem chama monta o plano com os
    /// Ajustes atuais. Os três casos que caem aí:
    ///
    /// - **sessão legada** (gravada antes desta versão): não tem snapshot, e reprocessá-la usa os
    ///   Ajustes de hoje — que é o que o app já fazia;
    /// - **snapshot vazio** (nenhum candidato sobreviveu ao decode);
    /// - **snapshot de outro caso de uso**: pegar aqui é melhor que deixar o coordenador rejeitar
    ///   com `planMismatch`, que abortaria o lote em vez de transcrever.
    static func batchPlan(from snapshot: TranscriptionPlanSnapshot?) -> TranscriptionRoutingPlan? {
        guard let snapshot, snapshot.useCase == .meetingFinal, !snapshot.isEmpty else { return nil }
        return snapshot.routingPlan
    }

    /// Plano gravado pronto para a passagem, ou ilegível (reconstrói).
    /// `persistResolvedOrigin` é true só quando o unresolved acabou de resolver —
    /// o chamador grava o snapshot imediatamente (one-shot).
    nonisolated enum StoredPlanUse: Equatable, Sendable {
        case usable(TranscriptionPlanSnapshot, persistResolvedOrigin: Bool)
        case unusable
    }

    /// Resolve `languageOrigin` ausente/desconhecido contra os Ajustes de agora.
    /// Origem já gravada não se reinterpreta.
    ///
    /// Mismatch do idioma gravado com o explícito atual ⇒ **sempre** reconstrói
    /// com os Ajustes de agora. Sem olhar candidato nenhum.
    ///
    /// A versão anterior tratava "plano sem candidato Apple" como assinatura de
    /// um auto que congelou (o router exclui SpeechAnalyzer com `language ==
    /// nil`) e adotava `autoAdopted` sem rebuild. A heurística é falsificável:
    /// um Mac Intel não tem Apple em plano nenhum — SpeechAnalyzer exige Apple
    /// Silicon (`TranscriptionCatalogTests`, rejeição `hardwareUnsupported`) —
    /// e um decode parcial que perdeu o candidato dá a mesma assinatura. Nos
    /// dois casos um plano legitimamente **explícito** era relido como auto, e
    /// o idioma que o humano escolheu deixava de ser soberano.
    ///
    /// O preço de remover é o simétrico e menor: um auto legado que congelou
    /// num locale diferente do explícito de hoje é reconstruído em vez de
    /// reaproveitado. Reconstruir usa os Ajustes atuais — o desfecho que o
    /// humano pediu. Exposição: só sessão incompleta legada (DECISOES, r4 do
    /// LANG).
    static func preparingStoredPlan(
        _ snapshot: TranscriptionPlanSnapshot,
        selectedLanguage: Language
    ) -> StoredPlanUse {
        guard snapshot.languageOrigin == .unresolved else {
            return .usable(snapshot, persistResolvedOrigin: false)
        }
        // O caso `.auto` sumiu do seletor (ver `Language`), então não há mais como um snapshot
        // sem origem ser lido como "auto que congelou": ele é comparado com o idioma explícito de
        // hoje. Uma sessão incompleta gravada em automático cai em `.unusable` quando o idioma
        // não bate — e ser reconstruída com os Ajustes de agora é o desfecho certo, porque
        // "agora" é uma escolha do humano e "então" era um palpite do modelo.
        var prepared = snapshot
        let selected = selectedLanguage.transcriptionLanguage
        if let planned = snapshot.language,
           planned.matches(selected) || selected.matches(planned) {
            prepared.languageOrigin = .explicit
            return .usable(prepared, persistResolvedOrigin: true)
        }
        return .unusable
    }

    /// Grava o snapshot no instante em que o unresolved resolve. One-shot:
    /// independente de `isCorrected` / persistPlanIfCorrected. `nil` quando
    /// não há o que gravar (origem já estava no disco, ou plano ilegível).
    static func persistingResolvedOrigin(
        _ use: StoredPlanUse,
        on session: MeetingSession
    ) -> MeetingSession? {
        guard case .usable(let snapshot, persistResolvedOrigin: true) = use else {
            return nil
        }
        var next = session
        next.transcriptionPlan = snapshot
        return next
    }

    /// Auto puro (sem idioma congelado) não tem probe — não gaste 30 s de buffer.
    static func shouldCollectProbeAudio(from snapshot: TranscriptionPlanSnapshot) -> Bool {
        snapshot.language != nil
    }

    // MARK: - Rebaixamento do plano ao longo dos lotes

    /// Um par motor+modelo, para acompanhar o que já falhou nesta reunião.
    nonisolated struct CandidateKey: Sendable, Hashable {
        var engine: TranscriptionEngineID
        var model: TranscriptionModelID

        init(engine: TranscriptionEngineID, model: TranscriptionModelID) {
            self.engine = engine
            self.model = model
        }

        init(_ candidate: TranscriptionPlanSnapshot.Candidate) {
            self.init(engine: candidate.engine, model: candidate.model)
        }

        init(_ candidate: TranscriptionRoutingCandidate) {
            self.init(engine: candidate.engine, model: candidate.model)
        }
    }

    /// Os candidatos que este lote deixou fora de cogitação para os próximos.
    ///
    /// Todo candidato que aparece nas tentativas falhas sai: preparação e inferência ficam
    /// registradas no coordenador com o `failureCooldown` infinito da `batchRetryPolicy` (logo,
    /// suprimidas pelo resto da passagem), `engineMissing` nunca vai passar a existir no meio de uma
    /// reunião, e `suppressed` é justamente o candidato que já estava fora.
    ///
    /// **Menos o que venceu.** `TranscriptionOutcome.failedAttempts` guarda a primeira tentativa
    /// mesmo quando a segunda do MESMO candidato deu certo (é a `attemptsPerCandidate: 2` dos lotes
    /// funcionando), e nesse caso o coordenador **apaga** o registro dele — `failures[key] = nil` no
    /// sucesso. Um espelho que não excluísse o vencedor mentiria duas vezes: anunciaria um
    /// rebaixamento que não houve, e ficaria com o candidato marcado, calando o aviso no dia em que
    /// a falha dele fosse definitiva. Achado do Farol.
    ///
    /// Não é o coordenador reimplementado: é o **espelho** do que ele decidiu, e serve só para o
    /// log dizer, uma vez, que os lotes seguintes mudaram de motor. Quem de fato escolhe continua
    /// sendo o coordenador, com os livros dele.
    ///
    /// - Parameter succeeded: a proveniência do candidato que produziu o texto; `nil` quando o lote
    ///   inteiro falhou.
    static func suppressedCandidates(
        from attempts: [TranscriptionAttempt],
        succeeded: TranscriptionProvenance? = nil
    ) -> Set<CandidateKey> {
        let winner = succeeded.map { CandidateKey(engine: $0.engine, model: $0.model) }
        return Set(attempts.map { CandidateKey($0.candidate) }).subtracting(winner.map { [$0] } ?? [])
    }

    // MARK: - Cancelamento

    /// Este erro é "alguém desistiu", e não "o lote falhou"?
    ///
    /// A distinção decide se o laço do pós-call continua: falha de lote é local (o próximo lote
    /// tenta), cancelamento vale para a passagem inteira. Sem ela, um pós-processamento cancelado
    /// percorreria o áudio inteiro falhando de linha em linha (MENOR da Quilha).
    static func isCancellation(_ error: any Error) -> Bool {
        if let coordinatorError = error as? TranscriptionCoordinatorError {
            return coordinatorError == .cancelled
        }
        if let engineFailure = error as? TranscriptionEngineFailure {
            return engineFailure == .cancelled
        }
        return error is CancellationError
    }

    /// O candidato que o **próximo** lote vai tentar primeiro, dado o que já falhou.
    ///
    /// É o primeiro do snapshot, na ordem de rank, que ainda não caiu. `nil` quando todos caíram —
    /// e aí os lotes restantes falham barato (candidato suprimido é pulado sem tocar no motor), que
    /// é a mesma economia do `initializationFailed` legado.
    static func nextPrimaryCandidate(
        in snapshot: TranscriptionPlanSnapshot,
        suppressing suppressed: Set<CandidateKey>
    ) -> TranscriptionPlanSnapshot.Candidate? {
        snapshot.candidates
            .sorted { $0.rank < $1.rank }
            .first { !suppressed.contains(CandidateKey($0)) }
    }

    /// A linha de log do rebaixamento — só ids, nunca texto.
    static func downgradeLogSummary(
        from previous: TranscriptionPlanSnapshot.Candidate?,
        to next: TranscriptionPlanSnapshot.Candidate?
    ) -> String {
        let before = previous.map { "\($0.engine)/\($0.model)" } ?? "nenhum"
        guard let next else {
            return "Plano da reunião esgotado: \(before) → nenhum candidato restante"
        }
        return "Plano da reunião rebaixado: \(before) → \(next.engine)/\(next.model) (rank \(next.rank))"
    }

    // MARK: - Proveniência por turno

    /// A proveniência de um turno que **cresceu** com mais de um lote.
    ///
    /// `merge(turn:into:)` costura lotes contíguos do mesmo falante (até 3 s de intervalo) num turno
    /// só, e nada garante que os dois lotes tenham saído do mesmo candidato — basta o primeiro
    /// falhar entre um e outro. A regra é **preservar a primeira**: um turno é identificado pelo
    /// começo dele, e a proveniência gravada responde "com que motor este turno começou a ser
    /// transcrito". Registrar a última faria a atribuição de um turno mudar retroativamente a cada
    /// costura, que é pior para quem for auditar meses depois.
    ///
    /// A proveniência **por lote** (que descreveria o turno inteiro sem essa perda) exige um campo
    /// por trecho no modelo, e a persistência de proveniência para a UI é da T6.3 — quando aquela
    /// tarefa desenhar o popover de detalhes, este é o ponto a revisitar.
    ///
    /// Turno legado (sem proveniência) que recebe um lote novo adota a proveniência do lote: é a
    /// única informação verdadeira que existe sobre ele.
    static func mergedProvenance(
        existing: TranscriptionProvenance?,
        incoming: TranscriptionProvenance?
    ) -> TranscriptionProvenance? {
        existing ?? incoming
    }
}

/// Decisões do stop/pós Granola (r4). Moram aqui porque o `MeetingViewModel` não compila
/// em `voizTests` — o mesmo desenho da T2.5. O view model só aplica o resultado.
nonisolated enum MeetingRecordingLifecycle {
    /// Granola só pode pular o **batch** (e a diarização e o eco pós-call) se o
    /// transcript ao vivo já produziu turns. Órfã com turns permanece Granola
    /// (rabo perdido é aceito); órfã sem turns vira Qualidade.
    ///
    /// WYSIWYG: o preview ao vivo **é** o transcript final. Eco se resolve
    /// ao vivo; o pós-call Granola é só o resumo. Ver `granolaPostCallWork`.
    static func granolaCompletesWithLiveTranscriptOnly(
        mode: AppSettings.MeetingMode?,
        turnCount: Int
    ) -> Bool {
        mode == .granola && turnCount > 0
    }

    /// O que o pós-call Granola executa. Receita WYSIWYG (decisão do humano):
    /// com turns, **só** o resumo — sem reconcileEcho e sem mutar turns.
    enum GranolaPostCallWork: Equatable, Sendable {
        /// Sem batch, sem diarização, sem eco pós-call. Só o resumo.
        case liveTranscriptThenSummary
        /// Pipeline Qualidade (transcrição + diarização + eco + resumo).
        case fullBatchPipeline
    }

    static func granolaPostCallWork(
        mode: AppSettings.MeetingMode?,
        turnCount: Int,
        isManualReprocess: Bool = false
    ) -> GranolaPostCallWork {
        // Clique explícito do humano é re-criação. WYSIWYG só governa o
        // pipeline automático (pós-call do hangup / recovery).
        if isManualReprocess { return .fullBatchPipeline }
        return granolaCompletesWithLiveTranscriptOnly(mode: mode, turnCount: turnCount)
            ? .liveTranscriptThenSummary
            : .fullBatchPipeline
    }

    /// Sessão encontrada no boot sem `endedAt`: o stop não chegou a gravar o fim.
    ///
    /// Granola **com** turns ao vivo fica Granola — WYSIWYG: o pós é só o resumo;
    /// o rabo não transcrito é perda aceita (DECISOES 2026-08-19). Sem turns,
    /// vira Qualidade para o batch reprocessar o CAF (comportamento de hoje).
    static func modeAfterInterruptedRecording(
        stored: AppSettings.MeetingMode?,
        hadEndedAt: Bool,
        turnCount: Int
    ) -> AppSettings.MeetingMode? {
        if !hadEndedAt, stored == .granola, turnCount == 0 { return .quality }
        return stored
    }

    /// "Remover eco" (Ações de áudio) muta turns. No Granola com transcript ao
    /// vivo isso fura o WYSIWYG. Qualidade e Granola sem turns mantêm o botão.
    static func showsRemoveEchoAction(
        mode: AppSettings.MeetingMode?,
        turnCount: Int
    ) -> Bool {
        !(mode == .granola && turnCount > 0)
    }

    /// Só troca os turns existentes quando o batch já produziu um substituto.
    /// Zerar antes do primeiro lote bem-sucedido apaga o transcript no crash.
    static func replacingTurnsIfNeeded(
        _ existing: [MeetingTurn],
        alreadyReplaced: Bool
    ) -> (turns: [MeetingTurn], replaced: Bool) {
        if alreadyReplaced { return (existing, true) }
        return ([], true)
    }

    /// Crash no meio do Reprocessar tem que cair no recovery, não parecer completo.
    /// A intenção manual vai no disco junto — o Set em memória não sobrevive.
    static func markingReprocessStarted(_ session: MeetingSession) -> MeetingSession {
        var next = session
        next.isProcessingCompleted = false
        next.pendingManualReprocess = true
        return next
    }

    static func markingProcessingFinished(_ session: MeetingSession) -> MeetingSession {
        var next = session
        next.isProcessingCompleted = true
        next.pendingManualReprocess = false
        return next
    }

    /// Como a passagem de lotes terminou. Os três são **términos** — a passagem
    /// foi até o fim do que dava para fazer e a intenção manual sai. O plano
    /// vazio e a falha de lote não são exceções à regra: o áudio fica em disco
    /// e o botão "Reprocessar transcript" continua oferecido, então prender a
    /// flag só faria o boot re-enfileirar sozinho, para sempre.
    nonisolated enum PostCallOutcome: Equatable, Sendable {
        case succeeded
        case emptyPlan
        case batchFailed
    }

    /// O desfecho a partir do que a passagem de fato encontrou.
    /// `hasUsablePlan == false` ⇒ nenhum motor atende (seleção estrita inviável,
    /// hardware, idioma). `cancelled` ⇒ o loop de lotes abortou no meio.
    static func postCallOutcome(
        hasUsablePlan: Bool,
        cancelled: Bool
    ) -> PostCallOutcome {
        guard hasUsablePlan else { return .emptyPlan }
        return cancelled ? .batchFailed : .succeeded
    }

    /// Término da passagem. O `switch` é exaustivo de propósito: um desfecho
    /// novo tem que decidir explicitamente o que faz com a flag manual.
    static func finishing(
        _ session: MeetingSession,
        after outcome: PostCallOutcome
    ) -> MeetingSession {
        switch outcome {
        case .succeeded, .emptyPlan, .batchFailed:
            return markingProcessingFinished(session)
        }
    }

    /// Admissão na fila de 1 do pós-processamento. Já enfileirada, ou já sendo
    /// processada agora, não entra de novo — é o que faz o boot que reencontra
    /// a mesma sessão incompleta enfileirá-la UMA vez.
    static func admittingToPostProcessing(
        _ sessionId: UUID,
        queue: inout [UUID],
        current: UUID?
    ) -> Bool {
        guard !queue.contains(sessionId), current != sessionId else { return false }
        queue.append(sessionId)
        return true
    }

    /// Reserva por **processo** do pós-processamento — a camada acima da fila de 1.
    ///
    /// A fila protege uma instância de `MeetingViewModel` de si mesma. Não protege de
    /// OUTRA instância: a SwiftUI pode construir a View (e com ela o view model) várias
    /// vezes, e cada `init` reencontra a mesma sessão incompleta no disco. Em 2026-09-03
    /// isso virou ~60 pipelines paralelos da mesma reunião — cada um com a sua chamada de
    /// nomes e de resumo na API paga, e nenhum deles conseguindo marcar a sessão como
    /// concluída (cada cópia velha sobrescrevia o session.json da outra).
    ///
    /// `inFlight` é o registro compartilhado entre instâncias: quem reserva primeiro
    /// processa; as demais desistem. A reserva sai em `releasingPostProcessing`, no
    /// término da passagem ou na exclusão da sessão.
    static func claimingPostProcessing(
        _ sessionId: UUID,
        inFlight: inout Set<UUID>
    ) -> Bool {
        inFlight.insert(sessionId).inserted
    }

    static func releasingPostProcessing(
        _ sessionId: UUID,
        inFlight: inout Set<UUID>
    ) {
        inFlight.remove(sessionId)
    }

    static func isManualReprocess(_ session: MeetingSession) -> Bool {
        session.pendingManualReprocess == true
    }

    /// Consome a intenção manual do disco e do Set. O remove no Set é
    /// incondicional — `pending == true` não pode pular o `remove` e prender
    /// o UUID para um re-enqueue automático posterior.
    static func consumeManualReprocessIntent(
        session: MeetingSession,
        inMemoryIDs: inout Set<UUID>
    ) -> Bool {
        let inMemory = inMemoryIDs.remove(session.id) != nil
        return session.pendingManualReprocess == true || inMemory
    }

    /// Costura um lote no transcript da passagem. Mora aqui porque o acumulador
    /// (não a sessão relida do store) é a verdade dos turns durante o batch.
    /// `speakerBoundaries` é parte do contrato do O2, não um detalhe: os lotes
    /// cortados na troca de falante saem ENCOSTADOS (gap 0), e a costura de 3 s
    /// recolaria exatamente o que o corte separou — a feature ficaria inerte e
    /// nenhum teste do leitor perceberia. A costura não atravessa corte.
    static func merge(
        turn: MeetingTurn,
        into turns: inout [MeetingTurn],
        speakerBoundaries: [TimeInterval] = []
    ) {
        if let last = turns.last,
           last.source == turn.source,
           turn.startTime - last.endTime <= 3,
           !crossesSpeakerBoundary(from: last.endTime, to: turn.startTime, boundaries: speakerBoundaries),
           let index = turns.indices.last {
            turns[index].text += " " + turn.text
            turns[index].endTime = turn.endTime
            turns[index].confidence = turn.confidence
            turns[index].provenance = MeetingTranscription.mergedProvenance(
                existing: last.provenance,
                incoming: turn.provenance
            )
        } else {
            turns.append(turn)
            turns.sort { $0.startTime < $1.startTime }
        }
    }

    /// Onde o leitor de lotes tem que cortar. Puro de propósito: a decisão é
    /// testável sem abrir arquivo de áudio.
    nonisolated struct MeetingBatchCutPlan: Sendable {
        let boundaries: [TimeInterval]
        /// Tolerância para "o corte é a própria fronteira do chunk".
        static let epsilon: TimeInterval = 0.001

        init(boundaries: [TimeInterval] = []) {
            self.boundaries = boundaries.sorted()
        }

        var isEmpty: Bool { boundaries.isEmpty }

        /// Primeiro corte ESTRITAMENTE dentro do chunk. O chunk é dividido no
        /// ponto exato — não na borda de 3 s da leitura —, senão a troca de
        /// falante fica com até um chunk inteiro de erro.
        func cut(strictlyInside chunk: MeetingAudioChunk) -> TimeInterval? {
            boundaries.first {
                $0 > chunk.startTime + Self.epsilon && $0 < chunk.endTime - Self.epsilon
            }
        }

        /// Existe corte entre o começo do lote aberto e o começo do próximo
        /// chunk? Inclusivo nas duas pontas: com os lotes encostados, a
        /// fronteira cai exatamente no fim de um e no começo do outro.
        func crossesBoundary(fromBatchStart start: TimeInterval, toChunkStart chunkStart: TimeInterval) -> Bool {
            boundaries.contains {
                $0 > start + Self.epsilon && $0 <= chunkStart + Self.epsilon
            }
        }

        /// Divide o chunk no instante pedido, proporcional em amostras.
        static func split(
            _ chunk: MeetingAudioChunk,
            at time: TimeInterval
        ) -> (head: MeetingAudioChunk, tail: MeetingAudioChunk) {
            let duration = chunk.endTime - chunk.startTime
            let index: Int
            if duration > 0, !chunk.samples.isEmpty {
                let fraction = (time - chunk.startTime) / duration
                let raw = (Double(chunk.samples.count) * fraction).rounded()
                index = min(chunk.samples.count, max(0, Int(raw)))
            } else {
                index = 0
            }
            return (
                head: MeetingAudioChunk(
                    source: chunk.source,
                    samples: Array(chunk.samples[..<index]),
                    startTime: chunk.startTime,
                    endTime: time
                ),
                tail: MeetingAudioChunk(
                    source: chunk.source,
                    samples: Array(chunk.samples[index...]),
                    startTime: time,
                    endTime: chunk.endTime
                )
            )
        }
    }

    static func crossesSpeakerBoundary(
        from end: TimeInterval,
        to start: TimeInterval,
        boundaries: [TimeInterval]
    ) -> Bool {
        let epsilon = MeetingBatchCutPlan.epsilon
        return boundaries.contains { $0 >= end - epsilon && $0 <= start + epsilon }
    }

    /// A verdade da passagem de lotes. O store só vê um snapshot pontual;
    /// o throttle não pode participar da montagem.
    nonisolated struct BatchTurnAccumulator: Sendable {
        private(set) var turns: [MeetingTurn]
        private(set) var hasReplacement: Bool
        /// Cortes da diarização — a costura não atravessa nenhum deles.
        var speakerBoundaries: [TimeInterval]

        init(
            existing: [MeetingTurn] = [],
            hasReplacement: Bool = false,
            speakerBoundaries: [TimeInterval] = []
        ) {
            self.turns = existing
            self.hasReplacement = hasReplacement
            self.speakerBoundaries = speakerBoundaries
        }

        mutating func accept(_ turn: MeetingTurn) {
            let replacement = replacingTurnsIfNeeded(turns, alreadyReplaced: hasReplacement)
            var next = replacement.turns
            merge(turn: turn, into: &next, speakerBoundaries: speakerBoundaries)
            turns = next
            hasReplacement = replacement.replaced
        }
    }

    /// Reaplica o mapeamento de nomes da sessão fresca aos turns do acumulador.
    /// `speakerId` manda; sem id, um único falante daquela fonte. Ambiguidade
    /// (dois falantes na mesma fonte) mantém o nome do acumulador.
    static func applyingFreshSpeakerNames(
        to turns: [MeetingTurn],
        speakers: [MeetingSpeaker]
    ) -> [MeetingTurn] {
        let nameById = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.name) })
        var countBySource: [MeetingCaptureSource: Int] = [:]
        var uniqueNameBySource: [MeetingCaptureSource: String] = [:]
        for speaker in speakers {
            countBySource[speaker.source, default: 0] += 1
            uniqueNameBySource[speaker.source] = speaker.name
        }
        for (source, count) in countBySource where count != 1 {
            uniqueNameBySource[source] = nil
        }
        return turns.map { turn in
            var next = turn
            if let id = turn.speakerId, let name = nameById[id] {
                next.speakerName = name
            } else if turn.speakerId == nil, let name = uniqueNameBySource[turn.source] {
                next.speakerName = name
            }
            return next
        }
    }

    /// Reconcilia os falantes que um passo do pipeline devolveu com a sessão
    /// fresca lida DEPOIS do await. A UI pode renomear um participante enquanto
    /// o passo roda; escrever `speakers` a partir da cópia capturada antes do
    /// await reverteria o nome. Critério: o nome mudou entre `before` (leitura
    /// do começo do passo) e `fresh` ⇒ foi a UI, e a UI manda.
    ///
    /// Só volta para a lista o falante cujo ID **nasceu durante o await**
    /// (está em `fresh`, não estava em `before`). Preservar qualquer ausente
    /// ressuscitava o que o passo REMOVEU de propósito: o "Eles" genérico que a
    /// diarização troca por S1…Sn viraria fantasma sem turns no card e no
    /// export, e uma re-diarização arrastaria os clusters da rodada anterior.
    static func mergingPipelineSpeakers(
        stepSpeakers: [MeetingSpeaker],
        before: [MeetingSpeaker],
        fresh: [MeetingSpeaker]
    ) -> [MeetingSpeaker] {
        let beforeNameById = Dictionary(
            before.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        let freshById = Dictionary(
            fresh.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var merged = stepSpeakers.map { speaker -> MeetingSpeaker in
            var next = speaker
            if let renamed = freshById[speaker.id], renamed.name != beforeNameById[speaker.id] {
                next.name = renamed.name
            }
            return next
        }
        let known = Set(merged.map(\.id))
        let beforeIds = Set(before.map(\.id))
        merged.append(
            contentsOf: fresh.filter { !known.contains($0.id) && !beforeIds.contains($0.id) }
        )
        return merged
    }

    /// Persistência da passagem: acumulador + throttle de disco. Produção e
    /// teste atravessam o mesmo tipo.
    nonisolated struct BatchTurnPersistence: Sendable {
        var accumulator: BatchTurnAccumulator
        var writeClock: ThrottledWriteClock

        init(
            existing: [MeetingTurn] = [],
            writeInterval: TimeInterval = 10,
            speakerBoundaries: [TimeInterval] = []
        ) {
            accumulator = BatchTurnAccumulator(existing: existing, speakerBoundaries: speakerBoundaries)
            writeClock = ThrottledWriteClock(interval: writeInterval)
        }

        var turns: [MeetingTurn] { accumulator.turns }

        mutating func accept(_ turn: MeetingTurn) {
            accumulator.accept(turn)
        }

        mutating func shouldWriteToDisk(at now: TimeInterval) -> Bool {
            writeClock.shouldWrite(at: now)
        }

        func flush(speakers: [MeetingSpeaker]) -> [MeetingTurn] {
            applyingFreshSpeakerNames(to: accumulator.turns, speakers: speakers)
        }
    }

    /// Relógio do throttle de disco. `false` = não escreve; a memória continua.
    nonisolated struct ThrottledWriteClock: Equatable, Sendable {
        var lastWrite: TimeInterval
        var interval: TimeInterval

        init(interval: TimeInterval = 10, lastWrite: TimeInterval = -.infinity) {
            self.interval = interval
            self.lastWrite = lastWrite
        }

        mutating func shouldWrite(at now: TimeInterval) -> Bool {
            guard now - lastWrite >= interval else { return false }
            lastWrite = now
            return true
        }
    }

    /// Texto aberto da prévia (notch / Live Assist). O mic tem que ser o
    /// volátil **já gateado** — o cru vaza eco oculto no card.
    static func liveOpenPreviewPieces(
        currentParagraph: String,
        displayedMicrophoneVolatile: String,
        systemVolatile: String
    ) -> [String] {
        [currentParagraph, displayedMicrophoneVolatile, systemVolatile]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Provider ausente ou start() falhou: a sessão deixa de ser Granola para o pós-call.
    static func modeAfterLiveStart(
        requested: AppSettings.MeetingMode,
        liveTranscriberStarted: Bool
    ) -> AppSettings.MeetingMode {
        if requested == .granola && !liveTranscriberStarted { return .quality }
        return requested
    }

    /// Resultado do start ao vivo. O view model não decide o modo — só aplica isto.
    struct LiveStartAttempt {
        var mode: AppSettings.MeetingMode
        var transcriber: (any MeetingLiveTranscriber)?
        var stream: AsyncStream<MeetingLiveTranscriptionEvent>?
    }

    /// Tenta o provider e o `start`. Qualquer falha (nil ou throw) persiste Qualidade.
    static func attemptLiveStart(
        requested: AppSettings.MeetingMode,
        provider: (@Sendable () -> (any MeetingLiveTranscriber)?)?,
        locale: Locale
    ) async -> LiveStartAttempt {
        guard requested == .granola else {
            return LiveStartAttempt(mode: requested, transcriber: nil, stream: nil)
        }
        guard let transcriber = provider?() else {
            return LiveStartAttempt(
                mode: modeAfterLiveStart(requested: requested, liveTranscriberStarted: false),
                transcriber: nil,
                stream: nil
            )
        }
        do {
            let stream = try await transcriber.start(
                config: MeetingLiveTranscriberConfiguration(locale: locale)
            )
            return LiveStartAttempt(
                mode: modeAfterLiveStart(requested: requested, liveTranscriberStarted: true),
                transcriber: transcriber,
                stream: stream
            )
        } catch {
            return LiveStartAttempt(
                mode: modeAfterLiveStart(requested: requested, liveTranscriberStarted: false),
                transcriber: nil,
                stream: nil
            )
        }
    }

    static func applyLiveStart(
        to session: MeetingSession,
        attempt: LiveStartAttempt
    ) -> MeetingSession {
        var updated = session
        updated.meetingMode = attempt.mode
        return updated
    }

    /// Aplica o start e entrega o resultado a `save`. Quem persistir o valor pré-apply
    /// (descartar o retorno e gravar a sessão velha) deixa Granola no disco após um throw.
    static func persistLiveStart(
        to session: MeetingSession,
        attempt: LiveStartAttempt,
        save: (MeetingSession) -> Void
    ) -> MeetingSession {
        let updated = applyLiveStart(to: session, attempt: attempt)
        save(updated)
        return updated
    }

    /// Composition root: devolve a factory sem invocá-la.
    static func wireProvider(
        factory: @escaping @Sendable () -> any MeetingLiveTranscriber
    ) -> @Sendable () -> any MeetingLiveTranscriber {
        { factory() }
    }

    /// Locale do transcritor ao vivo a partir do idioma do plano congelado da sessão.
    /// Planos legados sem idioma continuam em pt-BR: o SpeechAnalyzer não detecta idioma.
    static func liveLocale(forPlanLanguage language: TranscriptionLanguage?) -> Locale {
        let identifier: String
        switch language?.primaryCode.lowercased() {
        case "en": identifier = AppleSpeechLocale.englishUS.identifier
        case "es": identifier = AppleSpeechLocale.spanishSpain.identifier
        case "fr": identifier = AppleSpeechLocale.frenchFrance.identifier
        case "de": identifier = AppleSpeechLocale.germanGermany.identifier
        case "ja": identifier = AppleSpeechLocale.japaneseJapan.identifier
        case "zh": identifier = AppleSpeechLocale.chineseChina.identifier
        default: identifier = AppleSpeechLocale.portugueseBrazil.identifier
        }
        return Locale(identifier: identifier)
    }

    /// O assistente depende do transcript oficial crescente do modo Ao vivo. A prévia opcional
    /// do modo Qualidade é apenas visual e não habilita esse contrato.
    static func liveAssistantIsAvailable(
        mode: AppSettings.MeetingMode?,
        liveTranscriberActive: Bool
    ) -> Bool {
        mode == .granola && liveTranscriberActive
    }

    /// Deltas do stop sobre a releitura fresca. Notas substituem; pausa sobe o piso
    /// (já persistido ou ainda só em memória) sem somar duas vezes.
    static func mergeStopDeltas(
        onto session: MeetingSession,
        notes: String?,
        pausedDurationFloor: TimeInterval?
    ) -> MeetingSession {
        var updated = session
        if let notes {
            updated.notes = notes
        }
        if let pausedDurationFloor {
            updated.pausedDuration = max(updated.pausedDuration ?? 0, pausedDurationFloor)
        }
        return updated
    }

    /// Título da IA só entra se o atual ainda é um default de sessão.
    /// Título de calendário/app (“Planejamento Q3”) não é default — não sobrescreve.
    static func shouldAdoptGeneratedTitle(
        current: String,
        generated: String,
        defaultTitles: Set<String>
    ) -> Bool {
        let generated = generated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !generated.isEmpty, generated != current else { return false }
        return defaultTitles.contains(current) || looksLikeDefaultTitle(current)
    }

    /// Título que o app deu sozinho ao criar a sessão: o nome do tipo seguido de data e hora,
    /// como "Reunião 17/09/2026, 17:01", "Meeting 9/17/26, 5:01 PM" ou "Entrevista 18.06.26, 07:22".
    /// É o que a IA pode substituir sem perguntar. Um título com qualquer outra palavra depois
    /// do tipo ("Reunião de alinhamento") foi escrito por alguém e fica.
    static func looksLikeDefaultTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Prefixo: a(s) palavra(s) do tipo. Sufixo: só dígitos, pontuação de data/hora e AM/PM.
        guard let firstDigit = trimmed.firstIndex(where: \.isNumber) else { return false }
        let prefix = trimmed[..<firstDigit].trimmingCharacters(in: .whitespaces)
        var suffix = String(trimmed[firstDigit...])
        guard !prefix.isEmpty, prefix.allSatisfy({ $0.isLetter || $0.isWhitespace }) else { return false }
        for meridiem in [" AM", " PM", " am", " pm"] where suffix.hasSuffix(meridiem) {
            suffix.removeLast(meridiem.count)
        }
        // Data (dois separadores) e hora (dois-pontos), e nada além de dígitos e pontuação:
        // "Planejamento Q3 2026" ou "Daily 17/09 com o Matheus" são de gente, não do app.
        let separators = suffix.filter { "/.-".contains($0) }.count
        guard separators >= 2, suffix.contains(":") else { return false }
        return suffix.allSatisfy { $0.isNumber || $0.isWhitespace || "/.-:,".contains($0) }
    }

    /// Captura falhou depois do transcritor subir: o ciclo ao vivo precisa do mesmo
    /// teardown do stop, senão o próximo start herda o objeto/task vazados.
    static func mustTeardownLiveCycleAfterCaptureFailure(liveTranscriberStarted: Bool) -> Bool {
        liveTranscriberStarted
    }

    /// Stop do transcritor A não roda se B já tomou a geração (mesmo objeto reutilizado).
    static func shouldStopLiveTranscriber(
        stoppingGeneration: Int,
        currentGeneration: Int
    ) -> Bool {
        stoppingGeneration == currentGeneration
    }

    /// DTO Sendable: `MeetingTurn.init` é MainActor no alvo do app; este helper
    /// não pode construí-lo (warning → erro no Swift 6).
    struct LiveFinalDraft: Sendable, Equatable {
        var text: String
        var source: MeetingCaptureSource
        var speakerName: String
        var startTime: TimeInterval
        var endTime: TimeInterval
    }

    static func draftFromLiveFinal(
        text: String,
        channel: MeetingLiveAudioChannel,
        window: MeetingLiveCaptureWindow,
        speakerName: String
    ) -> LiveFinalDraft? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let source: MeetingCaptureSource = channel == .microphone ? .microphone : .systemAudio
        return LiveFinalDraft(
            text: trimmed,
            source: source,
            speakerName: speakerName,
            startTime: window.startTime,
            endTime: window.endTime
        )
    }
}

/// Casamento textual do eco (mic vs system). Extraído do reconciler para a
/// live view reusar a mesma normalização e os mesmos blocos comuns, sem DSP.
nonisolated enum MeetingEchoTextMatch {
    struct Utterance: Equatable, Sendable {
        var text: String
        var startTime: TimeInterval
        var endTime: TimeInterval
        /// Partes de origem quando o candidato é um COMPOSTO de finais
        /// contíguos. Vazio = candidato simples (ele mesmo é a parte).
        var parts: [Utterance] = []

        /// O texto do candidato que pode explicar fala NESTE intervalo do mic.
        ///
        /// A admissibilidade é POR TOKEN: a posição de cada token é estimada
        /// por interpolação linear no intervalo da parte de origem, e só conta
        /// o token cuja posição cai no intervalo do mic mais o jitter de
        /// segmentação. Filtrar por PARTE inteira ainda deixava A[0,10]
        /// emprestar todo o seu texto para um mic em [9,3;12] — bastava a ponta
        /// da parte encostar no mic.
        ///
        /// `includingSimpleCandidate` decide se um candidato SEM partes também
        /// passa pelo filtro:
        ///
        /// - **PERSIST** (`shouldSuppressMicDisplay`): sim. Sobrepor ≥70% do
        ///   mic não impede um candidato simples longo de conter, no seu
        ///   próprio início, texto que o usuário repete no fim — e no Granola
        ///   suprimir ali é perda definitiva do turn.
        /// - **GATE do volátil**: não. No caminho normal do volátil o mic está
        ///   no MEIO da fala e a janela do system é mais longa; filtrar por
        ///   token derrubaria a cobertura a cada atualização e a bolha voltaria
        ///   a piscar. A divergência que sobra — bolha oculta por um instante e
        ///   o final aparecendo logo depois — é display-transitória, o mesmo
        ///   regime do hold-off, e não apaga nada.
        func admissibleText(
            micStart: TimeInterval,
            micEnd: TimeInterval,
            jitter: TimeInterval,
            includingSimpleCandidate: Bool = false
        ) -> String {
            let sources = parts.isEmpty ? (includingSimpleCandidate ? [self] : []) : parts
            guard !sources.isEmpty else { return text }
            let lowerBound = micStart - jitter
            let upperBound = micEnd + jitter
            var kept: [Substring] = []
            for part in sources {
                let tokens = part.text.split(separator: " ")
                guard !tokens.isEmpty else { continue }
                let span = max(0, part.endTime - part.startTime)
                for (index, token) in tokens.enumerated() {
                    let position = part.startTime
                        + span * (Double(index) + 0.5) / Double(tokens.count)
                    if position >= lowerBound, position <= upperBound { kept.append(token) }
                }
            }
            return kept.joined(separator: " ")
        }
    }

    struct Block: Equatable, Sendable {
        var start: Int
        var otherStart: Int
        var length: Int
    }

    static let defaultMinMicTokens = 4
    /// Histerese da bolha volátil: uma vez oculta, só reaparece quando o texto
    /// deixa de parecer eco de vez. Não é o limiar de supressão (ver acima).
    static let defaultCoverageThreshold = 0.7
    static let defaultTimeSlack: TimeInterval = 3.0
    /// Eco real sobrepõe ~1,0 do intervalo do mic (atraso ~200 ms). 0,7
    /// deixa o ataque (overlap 0,5 + cobertura alta) sobreviver: falso
    /// negativo (duplicata parcial) é preferível a apagar fala genuína.
    static let defaultOverlapFraction = 0.7
    /// Silêncio máximo entre dois finais do system para eles serem o MESMO eco.
    static let defaultCompositeGap: TimeInterval = 0.75
    /// Folga temporal para admitir um token de uma PARTE do composto: o jitter
    /// de segmentação do ASR (~0,6 s), que é o erro esperado da posição
    /// estimada de cada token.
    static let defaultTokenJitter: TimeInterval = 0.6
    /// Evidência **causal** do eco, além da sobreposição. Eco não pode começar
    /// antes da fonte nem sobrar depois dela além do jitter de segmentação do
    /// ASR (~0,6 s medido); então o tempo de mic FORA da janela do system, em
    /// cada borda, tem que caber em ~1 s. Sobreposição sozinha não distingue
    /// mic[0,10] × system[3,10] (overlap 0,70, cobertura 1, mas 3 s de fala
    /// própria antes) de eco — e no Granola suprimir apaga o turn de vez.
    static let defaultMaxExclusiveMicSeconds: TimeInterval = 1.0
    /// Volátil do system só expira na retração/substituição ou após o
    /// mesmo slack do julgamento do final (3 s). 1,5 s era curto demais.
    static let defaultVolatileStaleSeconds: TimeInterval = defaultTimeSlack
    static let fuzzyMinTokenLength = 5
    static let fuzzyMaxEditDistance = 1

    /// Como um token é normalizado antes da comparação.
    nonisolated enum Normalization: Sendable {
        /// Cobertura do gate: dobra diacrítico e joga fora tudo que não for
        /// alfanumérico. Serve para MEDIR semelhança e decidir se a bolha
        /// pisca — não decide o que fica no transcript.
        case display
        /// Persist: IDENTIDADE LITERAL. Nenhuma transformação — o token vai
        /// para a comparação exatamente como o ASR o entregou.
        case persist
    }

    /// **Fecho definitivo: o persist não transforma NADA.**
    ///
    /// A última candidata a "atributo inofensivo" era a caixa, e ela também
    /// carrega significado. IT/it, WHO/who e Polish/polish são pares em que a
    /// capitalização muda o lexema e a PRONÚNCIA — acrônimo contra pronome,
    /// organização contra interrogativo, gentílico contra verbo. A caixa é
    /// evidência do que o reconhecedor entendeu, não decoração dela.
    ///
    /// Foram três normalizações derrubadas pela mesma razão: remover
    /// não-alfanuméricos fundia C++/C, -10/10, 10%/10, 1.2/12; podar só as
    /// BORDAS, com conjunto fechado, ainda fundia .NET/NET, Int?/Int,
    /// !important/important, .1/1; e a caixa funde IT/it. Não existe
    /// transformação segura — o token vai inteiro.
    ///
    /// CONSEQUÊNCIA ACEITA, além da divergência de reconhecimento: dois canais
    /// que SEGMENTAM diferente capitalizam diferente. O mesmo trecho vira
    /// início de frase num canal e meio de frase no outro, e a primeira palavra
    /// diverge só na caixa — e duplica. A supressão fica restrita a strings
    /// idênticas, que é o eco literal de um mesmo motor com os canais
    /// alinhados. É o caso comum, e é o único em que apagar é seguro.
    ///
    /// O modo `.display` continua jogando fora tudo que não é alfanumérico e
    /// dobrando diacrítico: lá o objetivo é MEDIR semelhança para decidir se a
    /// bolha pisca, não decidir o que fica no transcript.
    static func normalizedWord(_ token: String, for mode: Normalization = .display) -> String {
        switch mode {
        case .display:
            return token.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                .unicodeScalars
                .filter { CharacterSet.alphanumerics.contains($0) }
                .reduce(into: "") { $0.unicodeScalars.append($1) }
        case .persist:
            return token
        }
    }

    static func tokenize(_ text: String, for mode: Normalization = .display) -> [String] {
        text.split(separator: " ")
            .map { normalizedWord(String($0), for: mode) }
            .filter { !$0.isEmpty }
    }

    /// Token casa se for igual, ou (no modo fuzzy) se ambos tiverem ≥5 chars e
    /// distância de edição ≤1 — cobre Cnition/Cnation. cognation/coodition tem
    /// distância 3 e NÃO casa no token; a frase inteira ainda suprime via cobertura.
    /// Usado só pelo caminho de DISPLAY (cobertura do gate do volátil). O
    /// persist não casa nada aproximado — ver `textIsEcho`.
    static func tokensMatch(_ a: String, _ b: String, fuzzy: Bool) -> Bool {
        if a == b { return true }
        guard fuzzy,
              a.count >= fuzzyMinTokenLength,
              b.count >= fuzzyMinTokenLength
        else { return false }
        return editDistance(a, b) <= fuzzyMaxEditDistance
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let lhs = Array(a)
        let rhs = Array(b)
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        var previous = Array(0...rhs.count)
        var current = Array(repeating: 0, count: rhs.count + 1)
        for i in 1...lhs.count {
            current[0] = i
            for j in 1...rhs.count {
                let cost = lhs[i - 1] == rhs[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }

    /// Pedaços comuns das duas sequências, na ordem. `fuzzy: false` é o
    /// algoritmo exato do `MeetingEchoReconciler` (pós-call Qualidade intacto).
    static func matchingBlocks(_ a: [String], _ b: [String], fuzzy: Bool = false) -> [Block] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = tokensMatch(a[i], b[j], fuzzy: fuzzy)
                    ? lcs[i + 1][j + 1] + 1
                    : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }

        var blocks: [Block] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if tokensMatch(a[i], b[j], fuzzy: fuzzy) {
                let start = i, otherStart = j
                var length = 0
                while i < a.count, j < b.count, tokensMatch(a[i], b[j], fuzzy: fuzzy) {
                    i += 1
                    j += 1
                    length += 1
                }
                blocks.append(Block(start: start, otherStart: otherStart, length: length))
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return blocks
    }

    /// Fração dos tokens do mic que entram na subsequência comum com o system.
    static func micCoverage(mic: String, system: String, fuzzy: Bool = true) -> Double {
        let micWords = tokenize(mic)
        let sysWords = tokenize(system)
        guard !micWords.isEmpty else { return 0 }
        let matched = matchingBlocks(micWords, sysWords, fuzzy: fuzzy).reduce(0) { $0 + $1.length }
        return Double(matched) / Double(micWords.count)
    }

    /// Quantos tokens do mic ficaram de fora do casamento com o system.
    static func unmatchedMicTokens(mic: String, system: String, fuzzy: Bool = true) -> Int {
        let micWords = tokenize(mic)
        let sysWords = tokenize(system)
        guard !micWords.isEmpty else { return 0 }
        let matched = matchingBlocks(micWords, sysWords, fuzzy: fuzzy).reduce(0) { $0 + $1.length }
        return micWords.count - matched
    }

    /// O texto do mic é eco do candidato?
    ///
    /// **Igualdade BIDIRECIONAL das sequências de tokens normalizados**, com
    /// acentos preservados. Os tokens do mic e os tokens ADMISSÍVEIS do system
    /// têm que ser o mesmo array, na mesma ordem. Token a mais de qualquer
    /// lado — inclusive do lado do system — mantém o turn.
    ///
    /// Não basta "todo token do mic aparece no system": isso é SUBSEQUÊNCIA, e
    /// subsequência inverte sentido. O system diz "não podemos aprovar essa
    /// proposta hoje" e o usuário diz "podemos aprovar essa proposta hoje" — a
    /// fala oposta é subsequência da primeira e era apagada.
    ///
    /// A régua chegou aqui por eliminação, e a razão é lógica, não de calibragem.
    /// Toda tentativa anterior tentou separar "ruído de transcrição" de "fala
    /// diferente" olhando só para o texto:
    ///
    /// - limiar de cobertura (0,7/0,8) apagava interjeição colada no eco;
    /// - orçamento proporcional dava mais folga quanto mais longo o turno;
    /// - inserção vs substituição não via a deleção do outro ASR;
    /// - quase-identidade (distância ≤1) casa palavras reais e distintas —
    ///   contrato/contato, pagar/parar, vamos/vimos, certo/perto;
    /// - léxico separa duas palavras CONHECIDAS, mas nunca prova que a
    ///   desconhecida é erro de ASR: Swift/Shift tem distância 1 e "Shift" não
    ///   está no dicionário pt-BR, então a correção genuína voltava a ser
    ///   apagada. Dois tokens fora do vocabulário, idem;
    /// - folding de diacríticos colide secretaria/secretária, e/é, avó/avô;
    /// - subsequência deixa passar a negação removida;
    /// - remoção genérica de não-alfanuméricos funde símbolos que carregam
    ///   sentido: C++/C, -10/10, 10%/10, 1.2/12;
    /// - poda de borda com conjunto fechado ainda funde símbolo semântico DE
    ///   BORDA: .NET/NET, Int?/Int, !important/important, .1/1;
    /// - `lowercased()` funde acrônimo e heterônimo: IT/it, WHO/who,
    ///   Polish/polish — a caixa muda o lexema e a pronúncia.
    ///
    /// O padrão que as dez desenham é sempre o mesmo: toda normalização criada
    /// para absorver RUÍDO acabou absorvendo SENTIDO. Não sobrou nenhuma.
    ///
    /// **Fecho: o persist não transforma NADA. Suprimir exige o texto IDÊNTICO,
    /// no tempo certo e com causalidade — todo o resto é fala.**
    ///
    /// Não existe critério textual que separe garble de correção com segurança.
    /// O que existe é a assimetria do custo: apagar fala é irreversível,
    /// duplicata é visível e corrigível pelo humano.
    ///
    /// **Consequências aceitas e deliberadas:**
    ///
    /// 1. Toda variância de ASR entre os canais duplica no transcript —
    ///    pontuação, acento e CAIXA inclusive, e por tabela a capitalização que
    ///    muda com a fronteira de segmento. A supressão pega só o texto
    ///    idêntico, que é o eco literal de um mesmo motor com os canais
    ///    alinhados: o caso comum, e o único em que apagar é seguro.
    /// 2. **Lápide da última classe restante** (decisão de produto, DECISOES
    ///    2026-08-19): fala do usuário VERBATIM idêntica e simultânea à da
    ///    caixa — leitura em coro, repetir junto uma frase lida na tela —
    ///    continua sendo suprimida. É indistinguível de eco por qualquer
    ///    critério de texto ou de tempo, e o desfecho não perde conteúdo: a
    ///    frase aparece uma vez, atribuída a Eles. Aceito e fechado.
    static func textIsEcho(
        micText: String,
        systemText: String,
        fuzzyTokenMatching: Bool = false
    ) -> Bool {
        // Caminho do GATE: semelhança aproximada, para a bolha não piscar.
        if fuzzyTokenMatching {
            let micTokens = tokenize(micText)
            guard !micTokens.isEmpty else { return false }
            return unmatchedMicTokens(mic: micText, system: systemText, fuzzy: true) == 0
        }
        let micTokens = tokenize(micText, for: .persist)
        guard !micTokens.isEmpty else { return false }
        return micTokens == tokenize(systemText, for: .persist)
    }

    /// Finais do system separados por menos de `maxGap` são UM eco só. Julgados
    /// um a um, [0,7] e [7,10] nunca explicam um mic [0,10] (trail 3 s e lead
    /// 7 s, cada um por si); juntos, explicam. Só o composto MAXIMAL de cada
    /// corrida contígua é emitido: como a cobertura conta tokens do MIC, um
    /// composto maior nunca piora a cobertura, e o intervalo maior só reduz
    /// lead e trail — qualquer sub-composto é dominado por ele.
    static func contiguousComposites(
        _ utterances: [Utterance],
        maxGap: TimeInterval = defaultCompositeGap
    ) -> [Utterance] {
        guard utterances.count > 1 else { return [] }
        let ordered = utterances.sorted { $0.startTime < $1.startTime }
        var composites: [Utterance] = []
        var run: [Utterance] = [ordered[0]]
        var runEnd = ordered[0].endTime

        func closeRun() {
            guard run.count > 1 else { return }
            composites.append(
                Utterance(
                    text: run.map(\.text).joined(separator: " "),
                    startTime: run[0].startTime,
                    endTime: runEnd,
                    parts: run
                )
            )
        }

        for utterance in ordered.dropFirst() {
            if utterance.startTime - runEnd <= maxGap {
                run.append(utterance)
                runEnd = max(runEnd, utterance.endTime)
            } else {
                closeRun()
                run = [utterance]
                runEnd = utterance.endTime
            }
        }
        closeRun()
        return composites
    }

    /// Os candidatos que o julgamento enxerga: cada final/volátil por si **e**
    /// os compostos contíguos.
    static func judgingCandidates(
        _ utterances: [Utterance],
        maxGap: TimeInterval = defaultCompositeGap
    ) -> [Utterance] {
        utterances + contiguousComposites(utterances, maxGap: maxGap)
    }

    /// Fração do intervalo do mic coberta pelo intervalo do system.
    static func intervalOverlapFraction(
        micStart: TimeInterval,
        micEnd: TimeInterval,
        systemStart: TimeInterval,
        systemEnd: TimeInterval
    ) -> Double {
        let duration = micEnd - micStart
        guard duration > 0 else { return 0 }
        let overlap = max(0, min(micEnd, systemEnd) - max(micStart, systemStart))
        return overlap / duration
    }

    static func intervalsNear(
        micStart: TimeInterval,
        micEnd: TimeInterval,
        systemStart: TimeInterval,
        systemEnd: TimeInterval,
        overlapFraction: Double = defaultOverlapFraction
    ) -> Bool {
        intervalOverlapFraction(
            micStart: micStart,
            micEnd: micEnd,
            systemStart: systemStart,
            systemEnd: systemEnd
        ) >= overlapFraction
    }

    /// Tempo de mic **exclusivo** antes do início do candidato do system.
    static func exclusiveMicLead(
        micStart: TimeInterval,
        systemStart: TimeInterval
    ) -> TimeInterval {
        max(0, systemStart - micStart)
    }

    /// Tempo de mic **exclusivo** depois do fim do candidato do system.
    static func exclusiveMicTrail(
        micEnd: TimeInterval,
        systemEnd: TimeInterval
    ) -> TimeInterval {
        max(0, micEnd - systemEnd)
    }

    /// Sobreposição alta **e** evidência causal nas duas bordas. É este o
    /// predicado que habilita a supressão — `intervalsNear` sozinho não basta.
    static func intervalsCausallyAligned(
        micStart: TimeInterval,
        micEnd: TimeInterval,
        systemStart: TimeInterval,
        systemEnd: TimeInterval,
        overlapFraction: Double = defaultOverlapFraction,
        maxExclusiveMic: TimeInterval = defaultMaxExclusiveMicSeconds
    ) -> Bool {
        guard intervalsNear(
            micStart: micStart,
            micEnd: micEnd,
            systemStart: systemStart,
            systemEnd: systemEnd,
            overlapFraction: overlapFraction
        ) else { return false }
        return exclusiveMicLead(micStart: micStart, systemStart: systemStart) <= maxExclusiveMic
            && exclusiveMicTrail(micEnd: micEnd, systemEnd: systemEnd) <= maxExclusiveMic
    }

    /// Prazo do atraso. Passado o trail máximo por mais que esta margem de
    /// progresso de relógio, o candidato está causalmente MORTO para este
    /// parágrafo: o persist do final reprovaria por trail de qualquer forma, e
    /// continuar "esperando" prenderia a bolha genuína para sempre.
    static let defaultLagGrace: TimeInterval = 2
    /// Janela de retenção dos finais do system como candidatos de eco.
    static let defaultFinalsRetention: TimeInterval = 15

    /// Candidato que ainda não ALCANÇOU o mic: começa dentro do lead e o mic
    /// passa do fim conhecido do system por mais que o jitter. Não é evidência
    /// contra o eco — é o system atrasado, e julgar agora é adivinhar.
    ///
    /// Mas o atraso tem PRAZO. Um final antigo com o system mudo depois dele
    /// ficava "atrasado" para sempre, e um parágrafo do mic que seguisse além
    /// dele nunca aparecia — o turn persistia sem nunca ter sido exibido, que é
    /// a WYSIWYG quebrada no sentido inverso.
    static func candidateIsLagging(
        micStart: TimeInterval,
        micEnd: TimeInterval,
        systemStart: TimeInterval,
        systemEnd: TimeInterval,
        maxExclusiveMic: TimeInterval = defaultMaxExclusiveMicSeconds,
        lagGrace: TimeInterval = defaultLagGrace
    ) -> Bool {
        guard systemEnd > micStart else { return false }
        guard exclusiveMicLead(micStart: micStart, systemStart: systemStart) <= maxExclusiveMic
        else { return false }
        let trail = exclusiveMicTrail(micEnd: micEnd, systemEnd: systemEnd)
        return trail > maxExclusiveMic && trail <= maxExclusiveMic + lagGrace
    }

    /// Finais do system + o volátil **corrente** e fresco. Hipótese retraída
    /// (texto vazio) ou sem atualização recente no relógio da captura não entra.
    static func echoCandidates(
        finals: [Utterance],
        currentVolatileText: String,
        currentVolatileWindow: Utterance?,
        captureClock: TimeInterval? = nil,
        staleAfter: TimeInterval = defaultVolatileStaleSeconds,
        finalsRetention: TimeInterval = defaultFinalsRetention
    ) -> [Utterance] {
        var candidates = finals
        // Poda por PROGRESSO DE RELÓGIO, não só na chegada de outro final: com
        // o system mudo, nenhum final novo chega e a lista envelhecia parada.
        //
        // LIMITAÇÃO CONHECIDA (decisão do Maestro, 2026-08-19 — não corrigir):
        // um final do mic muito longo (>15 s contínuos) pode precisar de um
        // final do system já podado para montar o composto. Com o system
        // finalizando [0,10] [10,20] [20,30] contra um mic [0,30], o primeiro
        // pedaço sai da retenção antes de o mic fechar, o composto fica
        // incompleto e o eco NÃO é suprimido. A falha é duplicata visível —
        // direção segura pelo critério de aceite: o que apaga fala genuína
        // bloqueia, o que deixa duplicata é limitação documentada.
        if let clock = captureClock {
            candidates.removeAll { clock - $0.endTime > finalsRetention }
        }
        let text = currentVolatileText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let window = currentVolatileWindow else { return candidates }
        if let clock = captureClock, clock - window.endTime > staleAfter {
            return candidates
        }
        candidates.append(
            Utterance(text: text, startTime: window.startTime, endTime: window.endTime)
        )
        return candidates
    }

    /// `perTokenOnSimpleCandidates` liga o filtro temporal por token também
    /// para candidato simples. Ligado no PERSIST (padrão); desligado no gate do
    /// volátil, que precisa enxergar o texto inteiro do candidato para não
    /// piscar — ver `Utterance.admissibleText`.
    ///
    /// O `.final` do mic é eco da caixa se casa forte com fala recente do system
    /// **e** os intervalos são causalmente compatíveis (`intervalsCausallyAligned`).
    /// Conservador — double-talk, fone e fala própria colada no eco não suprimem.
    /// No Granola isso agora impede o persist do turn (WYSIWYG).
    static func shouldSuppressMicDisplay(
        micText: String,
        micStart: TimeInterval,
        micEnd: TimeInterval,
        systemUtterances: [Utterance],
        minMicTokens: Int = defaultMinMicTokens,
        overlapFraction: Double = defaultOverlapFraction,
        maxExclusiveMic: TimeInterval = defaultMaxExclusiveMicSeconds,
        compositeGap: TimeInterval = defaultCompositeGap,
        tokenJitter: TimeInterval = defaultTokenJitter,
        perTokenOnSimpleCandidates: Bool = true,
        fuzzyTokenMatching: Bool = false
    ) -> Bool {
        let micWords = tokenize(micText)
        guard micWords.count >= minMicTokens else { return false }
        for candidate in judgingCandidates(systemUtterances, maxGap: compositeGap) {
            guard intervalsCausallyAligned(
                micStart: micStart,
                micEnd: micEnd,
                systemStart: candidate.startTime,
                systemEnd: candidate.endTime,
                overlapFraction: overlapFraction,
                maxExclusiveMic: maxExclusiveMic
            ) else { continue }
            let systemText = candidate.admissibleText(
                micStart: micStart,
                micEnd: micEnd,
                jitter: tokenJitter,
                includingSimpleCandidate: perTokenOnSimpleCandidates
            )
            if textIsEcho(
                micText: micText,
                systemText: systemText,
                fuzzyTokenMatching: fuzzyTokenMatching
            ) {
                return true
            }
        }
        return false
    }

    static func bestNearbyCoverage(
        micText: String,
        micStart: TimeInterval,
        micEnd: TimeInterval,
        systemUtterances: [Utterance],
        overlapFraction: Double = defaultOverlapFraction,
        maxExclusiveMic: TimeInterval = defaultMaxExclusiveMicSeconds,
        compositeGap: TimeInterval = defaultCompositeGap,
        tokenJitter: TimeInterval = defaultTokenJitter
    ) -> Double {
        var best = 0.0
        for candidate in judgingCandidates(systemUtterances, maxGap: compositeGap) {
            guard intervalsCausallyAligned(
                micStart: micStart,
                micEnd: micEnd,
                systemStart: candidate.startTime,
                systemEnd: candidate.endTime,
                overlapFraction: overlapFraction,
                maxExclusiveMic: maxExclusiveMic
            ) else { continue }
            let systemText = candidate.admissibleText(
                micStart: micStart,
                micEnd: micEnd,
                jitter: tokenJitter
            )
            best = max(best, micCoverage(mic: micText, system: systemText, fuzzy: true))
        }
        return best
    }
}

/// Display-only: decide se a bolha **volátil** do mic aparece. Persistência do
/// `.final` não passa por aqui.
///
/// Começa oculta (`holding`). Só vira `visible` depois de ~0,6 s de relógio da
/// captura continuamente elegível. Com fone (sem system) esse hold-off é o
/// único atraso — o final persiste igual. Uma vez `suppressed`, só reaparece
/// se a cobertura cair abaixo de `revealBelow` (histerese; double-talk <0,4).
///
/// Limitações conhecidas (sem código — DECISOES 2026-08-19): corrida de
/// finais já em voo no hangup (mitigada pelos voláteis); cap 120 do liveFeed
/// é só display; holding sem timeout de fala curta com system ativo.
nonisolated struct MeetingLiveMicVolatileGate: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case holding
        case visible
        case suppressed
    }

    static let defaultHoldOff: TimeInterval = 0.6
    static let revealBelow: Double = 0.45

    var phase: Phase = .idle
    var eligibleSince: TimeInterval?
    var lastClock: TimeInterval = 0
    var holdOff: TimeInterval = defaultHoldOff

    var displaysText: Bool { phase == .visible }

    mutating func reset() {
        phase = .idle
        eligibleSince = nil
        lastClock = 0
    }

    mutating func apply(
        micText: String,
        micStart: TimeInterval,
        micEnd: TimeInterval,
        clock incomingClock: TimeInterval,
        systemUtterances: [MeetingEchoTextMatch.Utterance]
    ) {
        let clock = max(lastClock, incomingClock)
        lastClock = clock

        let trimmed = micText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            reset()
            return
        }

        let tokenCount = MeetingEchoTextMatch.tokenize(trimmed).count
        let tooShort = tokenCount < MeetingEchoTextMatch.defaultMinMicTokens
        let candidates = MeetingEchoTextMatch.judgingCandidates(systemUtterances)
        let hasNearbySystem = candidates.contains { candidate in
            MeetingEchoTextMatch.intervalsCausallyAligned(
                micStart: micStart,
                micEnd: micEnd,
                systemStart: candidate.startTime,
                systemEnd: candidate.endTime
            )
        }
        let coverage = MeetingEchoTextMatch.bestNearbyCoverage(
            micText: trimmed,
            micStart: micStart,
            micEnd: micEnd,
            systemUtterances: systemUtterances
        )
        // Mesmo predicado do persist, com UMA divergência deliberada: aqui o
        // candidato simples não passa pelo filtro por token (`perTokenOn
        // SimpleCandidates: false`). O gate suprime num superconjunto dos casos
        // do persist, então o que pode acontecer é a bolha sumir e o final
        // aparecer logo depois — display-transitório, o mesmo regime do
        // hold-off. O sentido perigoso (bolha aparece e o turn some) continua
        // impossível. Ver `Utterance.admissibleText`.
        let suppressible = MeetingEchoTextMatch.shouldSuppressMicDisplay(
            micText: trimmed,
            micStart: micStart,
            micEnd: micEnd,
            systemUtterances: systemUtterances,
            perTokenOnSimpleCandidates: false,
            fuzzyTokenMatching: true
        )
        /// Candidato que ainda não alcançou o mic (system atrasado) e cujo texto
        /// AINDA parece eco. Enquanto isso, julgar é adivinhar: a bolha espera.
        /// Se o conteúdo já desmente o eco (cobertura abaixo do reveal), o atraso
        /// não segura mais nada — inelegibilidade por conteúdo libera.
        let laggingCandidate = candidates.contains { candidate in
            MeetingEchoTextMatch.candidateIsLagging(
                micStart: micStart,
                micEnd: micEnd,
                systemStart: candidate.startTime,
                systemEnd: candidate.endTime
            ) && MeetingEchoTextMatch.micCoverage(
                mic: trimmed,
                system: candidate.admissibleText(
                    micStart: micStart,
                    micEnd: micEnd,
                    jitter: MeetingEchoTextMatch.defaultTokenJitter
                )
            ) >= Self.revealBelow
        }
        /// Curto demais para julgar, mas o system já está falando perto: espera.
        let waitingToJudge = (tooShort && hasNearbySystem) || laggingCandidate
        let eligible = !waitingToJudge && !suppressible

        switch phase {
        case .idle:
            if suppressible {
                phase = .suppressed
                eligibleSince = nil
            } else {
                phase = .holding
                eligibleSince = eligible ? clock : nil
                promoteHoldingIfReady(clock)
            }
        case .holding:
            if suppressible {
                phase = .suppressed
                eligibleSince = nil
            } else if eligible {
                if eligibleSince == nil { eligibleSince = clock }
                promoteHoldingIfReady(clock)
            } else {
                eligibleSince = nil
            }
        case .suppressed:
            if !tooShort, !laggingCandidate, coverage < Self.revealBelow {
                phase = .holding
                eligibleSince = clock
                promoteHoldingIfReady(clock)
            }
        case .visible:
            if suppressible {
                phase = .suppressed
                eligibleSince = nil
            }
        }
    }

    private mutating func promoteHoldingIfReady(_ clock: TimeInterval) {
        guard phase == .holding, let since = eligibleSince, clock - since >= holdOff else { return }
        phase = .visible
        eligibleSince = nil
    }
}
