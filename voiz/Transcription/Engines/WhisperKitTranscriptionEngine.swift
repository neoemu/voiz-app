import Foundation

/// O estágio de carga dos pesos, para quem quiser mostrar isso na tela.
///
/// Carrega o id da **geração** porque o observador é chamado de dois lugares com latências
/// diferentes — de dentro do ator e do callback de progresso do download, que roda na thread da
/// biblioteca — e o `TranscriptionRuntimeStore` da T2.3 é `@MainActor`, logo vai ter que hopar.
/// Sem a geração, um `.downloading(0.97)` atrasado de uma carga já abortada chegaria depois do
/// `.ready` da carga viva e prenderia a UI em "baixando" com o modelo pronto.
///
/// A geração é monotônica **por instância de motor** e nasce **com a vaga do runtime na mão**,
/// não na entrada da operação: ela ordena as **mutações** de estado, e não o início das
/// chamadas. É a mesma regra do Parakeet, e é o que faz "maior geração vence" levar sempre ao
/// estado real — inclusive quando um `unload` e um `prepare` se cruzam: quem executa por último
/// vence, e é dele o evento de geração maior.
///
/// A regra para o store: chavear a geração **por motor** (o Parakeet tem o contador dele, com o
/// mesmo significado mas em outro tipo de evento) e descartar todo evento cuja geração seja
/// menor que a maior já vista daquele motor.
nonisolated struct WhisperKitLoadEvent: Sendable, Equatable {
    nonisolated enum Stage: Sendable, Equatable {
        /// Baixando os pesos: fração de 0 a 1.
        case downloading(model: TranscriptionModelID, fraction: Double)
        /// Já no disco, carregando na Neural Engine.
        case loading(model: TranscriptionModelID)
        case ready(model: TranscriptionModelID)
        case failed(model: TranscriptionModelID, failure: TranscriptionEngineFailure)
        /// Pesos liberados; nenhum modelo residente.
        case unloaded
    }

    var generation: Int
    var stage: Stage

    init(generation: Int, stage: Stage) {
        self.generation = generation
        self.stage = stage
    }
}

/// O WhisperKit como `BatchTranscriptionEngine`.
///
/// É o `TranscriptionService` de hoje virado do avesso: o modelo deixa de ser estado global
/// mutável (`configure(modelName:)` + singleton) e passa a chegar por `prepare(model:)` /
/// `transcribe(_:candidate:)`. As decisões de qualidade continuam as mesmas — mesmas
/// `DecodingOptions` (em `LiveWhisperKitRuntime`), mesma sanitização, mesma recuperação de
/// modelo corrompido.
///
/// ## A vaga única
///
/// Um ator serializa o acesso ao **estado** deste objeto, e só: ele libera o executor em todo
/// `await`, então não serializa o recurso caro. E o recurso caro não é disputado só por
/// inferências entre si — carregar, trocar de modelo e descarregar mexem no mesmo `WhisperKit`,
/// que é `open class` com estado mutável. Liberar os pesos por baixo de uma inferência viva é
/// tão corrida quanto duas inferências simultâneas.
///
/// Por isso **tudo que toca o runtime disputa uma vaga única FIFO**: inferência, carga, troca de
/// modelo e `unload`. É a mesma semântica do `ParakeetTranscriptionEngine`, para o coordenador
/// da T2.3 poder assumir a mesma coisa dos dois motores. Consequências:
/// - no máximo uma inferência em voo por instância;
/// - a sessão anterior só é liberada com a vaga na mão, isto é, com a fila drenada;
/// - quem esperava na fila **re-confere a residência ao acordar** (`residencyToken`): entre
///   entrar na fila e ser servido, o modelo pode ter sido trocado ou descarregado.
///
/// ## Garantia pós-`prepare`
///
/// **Quando houve carga**, ao devolver sem erro o modelo pedido está residente e nenhuma
/// inferência iniciada antes continua em voo — a carga só termina com a vaga na mão. (Um
/// `transcribe` enfileirado *depois* pode ser servido assim que a carga solta a vaga; isso vale
/// igual nos dois motores e é o que permite o coordenador ordenar a fila dele por prioridade.)
/// O caminho rápido — o modelo pedido já é o residente — devolve sem tomar a vaga, e portanto
/// pode devolver com uma inferência anterior em voo. Também é igual nos dois motores.
///
/// ## `unload` × `prepare`: quem executa por último vence
///
/// `unload()` **sempre** descarrega quando executa; ele nunca vira no-op por ter sido superado.
/// Quando o `await unload()` devolve, os pesos que estavam residentes naquele instante foram
/// liberados. Um `prepare` enfileirado depois recarrega — e a ordem é a ordem das próprias
/// chamadas, visível ao coordenador. `unload()` devolve `Void`: quem precisar de prova de
/// residência confirma com um `prepare` subsequente.
///
/// ## Residência é do coordenador
///
/// `transcribe` **não** prepara sozinho: modelo não preparado é `.modelUnavailable`.
///
/// **Ninguém no app usa este motor ainda.** Os três view models seguem no
/// `TranscriptionService.shared`; a troca é a T2.4a/b/T2.5, depois que o coordenador existir.
actor WhisperKitTranscriptionEngine: BatchTranscriptionEngine {

    nonisolated let descriptor: TranscriptionEngineDescriptor

    private let runtime: any WhisperKitRuntime
    private let observer: (@Sendable (WhisperKitLoadEvent) -> Void)?

    /// Pesos residentes, de que modelo eles são, e o token que identifica **esta** residência.
    private var loaded: LoadedModel?

    /// Carga em voo. É o single-flight: enquanto existir, ninguém abre uma segunda carga do
    /// mesmo modelo (2× rede e 2× RAM — o motivo declarado de o `TranscriptionService` ser
    /// singleton) nem recebe um `.modelUnavailable` espúrio por chegar durante a carga.
    private var loadTask: InflightLoad?

    /// Contador das gerações. Uma geração **nasce com a vaga na mão** (`nextGeneration()`), e não
    /// na entrada da operação: assim a ordem das gerações é a ordem das **mutações** de estado, e
    /// não a ordem em que as chamadas começaram. É a mesma regra do Parakeet.
    private var generationCounter = 0

    /// Contador das cargas. Quem decide se uma carga em voo ainda vale é este id (`isCurrent`),
    /// e não a geração: desde que a geração passou a nascer só com a vaga, ela deixou de servir
    /// para identificar quem foi superado.
    private var loadIDCounter = 0

    private var ticketCounter = 0

    /// Modelo cuja preparação já falhou em definitivo, com a falha. Enquanto for este o modelo
    /// pedido, `prepare` re-lança na hora em vez de tentar baixar de novo — sem isso, uma
    /// reunião de 40 lotes tentaria 40 downloads do mesmo modelo quebrado.
    ///
    /// O latch só sai com troca de modelo ou `unload()`. Quando limpar (retry por lote da T2.5,
    /// prazo) é decisão da T2.3: o motor reporta a falha, não decide sozinho quando esquecê-la.
    private var failedModel: FailedModel?

    /// Modelo para o qual já gastamos a única tentativa de apagar-e-re-baixar.
    private var recoveryAttemptedModel: TranscriptionModelID?

    // A vaga única do runtime caro.
    private var slotBusy = false
    private var slotWaiters: [SlotWaiter] = []

    private struct LoadedModel {
        var model: TranscriptionModelID
        var session: any WhisperKitSession
        /// Identifica esta residência. Um trabalho que entrou na fila com o token X e acorda com
        /// outro token na mão sabe que a sessão em que ele ia entrar não existe mais.
        var residencyToken: Int
    }

    private struct InflightLoad {
        var model: TranscriptionModelID
        var id: Int
        var task: Task<Void, any Error>
    }

    private struct FailedModel {
        var model: TranscriptionModelID
        var failure: TranscriptionEngineFailure
    }

    private struct SlotWaiter {
        var ticket: Int
        /// O valor com que a continuation é retomada **é** a posse da vaga: `true` = fomos
        /// servidos e devemos devolvê-la; `false` = saímos da fila por cancelamento e não a
        /// temos. Distinguir isso por efeito colateral (um `Set` de desistentes preenchido por
        /// um hop assíncrono) foi o que vazou a vaga na rodada 3: o `releaseSlot` podia servir o
        /// waiter antes de o hop rodar, e aí ninguém sabia que a vaga tinha dono.
        var continuation: CheckedContinuation<Bool, Never>
    }

    /// Sem instância default de propósito: quem monta o motor é o coordenador da T2.3, e um
    /// construtor de conveniência criaria runtimes soltos que ele não controla — a regra de
    /// residência não se aplica sobre pesos que não são dele. A fábrica com o runtime de
    /// produção é `make(observer:)`, em `LiveWhisperKitRuntime.swift`.
    init(
        runtime: any WhisperKitRuntime,
        descriptor: TranscriptionEngineDescriptor = .whisperKit,
        observer: (@Sendable (WhisperKitLoadEvent) -> Void)? = nil
    ) {
        self.runtime = runtime
        self.descriptor = descriptor
        self.observer = observer
    }

    // MARK: - TranscriptionEngine

    /// Idempotente e single-flight: com o modelo já carregado não faz nada; com uma carga do
    /// mesmo modelo em voo, aguarda **aquela**; com outro modelo em voo, aborta a antiga antes
    /// de começar a nova.
    ///
    /// **Quando houve carga**, ao devolver sem erro o modelo pedido está residente e nada que
    /// estava inferindo antes continua em voo — a carga só termina com a vaga na mão. O caminho
    /// rápido (o modelo pedido já é o residente) devolve sem tomar a vaga, e por isso pode
    /// devolver com uma inferência anterior ainda rodando: não há o que carregar, e fazer o
    /// caminho rápido disputar a vaga transformaria um `prepare` barato em espera de fila.
    /// O caminho rápido é igual no Parakeet.
    func prepare(model: TranscriptionModelID) async throws {
        try checkCancelled()

        // Antes de tocar em QUALQUER estado: um id que não pertence a este motor (seleção salva
        // de uma versão antiga, catálogo que mudou) não pode evictar o modelo que está
        // funcionando nem criar latch. Ele só falha.
        let variant = try WhisperKitEngineSupport.resolveVariant(for: model, descriptor: descriptor)

        while true {
            if let loaded, loaded.model == model { return }
            if let failedModel, failedModel.model == model { throw failedModel.failure }

            if let inflight = loadTask {
                guard inflight.model == model else {
                    // Carga de outro modelo: abortada antes de começarmos a nossa, senão os
                    // dois conjuntos de pesos ficariam residentes ao mesmo tempo.
                    await abort(inflight)
                    // O `await` acima devolveu o ator: o laço reavalia tudo do zero porque
                    // outra chamada pode ter mexido no estado enquanto isso.
                    continue
                }
                // Single-flight: a falha da carga compartilhada é a nossa falha.
                try await inflight.task.value
                try checkCancelled()
                return
            }

            // Daqui até registrar a nova carga não há `await`: a decisão de abrir a carga e o
            // registro dela são atômicos do ponto de vista do ator, então nunca há duas.
            // `loaded` **não** é zerado aqui: quem troca o modelo residente é o `runLoad`, com
            // a vaga na mão. Zerar antes deixaria a sessão anterior sem dono enquanto uma
            // inferência ainda estivesse dentro dela.
            failedModel = nil
            if recoveryAttemptedModel != model { recoveryAttemptedModel = nil }

            let id = nextLoadID()
            let task = Task<Void, any Error> {
                try await self.runLoad(model: model, variant: variant, id: id)
            }
            loadTask = InflightLoad(model: model, id: id, task: task)

            try await task.value
            try checkCancelled()
            return
        }
    }

    /// Cancela e aguarda a carga em voo, toma a vaga (o que drena a inferência) e **libera os
    /// pesos de fato**.
    ///
    /// Semântica de `unload` × `prepare` concorrentes: **quem executa por último vence**. Este
    /// `unload` sempre descarrega quando executa — nunca vira no-op silencioso por ter sido
    /// "superado" por um `prepare`. A garantia que o coordenador da T2.3 pode usar: quando o
    /// `await unload()` devolve, os pesos que estavam residentes naquele instante foram
    /// liberados. Um `prepare` enfileirado depois recarrega, e isso é visível pela ordem das
    /// próprias chamadas. É a mesma semântica do Parakeet.
    func unload() async {
        // A carga moribunda é cancelada e aguardada FORA da vaga: ela precisa da vaga para
        // terminar, e esperá-la já segurando a vaga seria deadlock.
        if let inflight = loadTask {
            loadTask = nil
            inflight.task.cancel()
            _ = try? await inflight.task.value
        }

        // Não-cancelável: descarregar memória é justamente o que não pode desistir no meio.
        _ = await acquireSlot()
        defer { releaseSlot() }

        // Geração tirada aqui, com a vaga na mão: a ordem das gerações é a ordem das mutações.
        let generation = nextGeneration()

        // Toda a mutação de estado mora dentro da vaga — inclusive a limpeza do latch, que na
        // rodada 3 acontecia lá em cima, fora dela.
        let session = loaded?.session
        loaded = nil
        failedModel = nil
        recoveryAttemptedModel = nil
        await session?.release()

        emit(.unloaded, generation: generation)
    }

    // MARK: - BatchTranscriptionEngine

    func transcribe(
        _ request: TranscriptionRequest,
        candidate: TranscriptionRoutingCandidate
    ) async throws -> TranscriptionEngineResult {
        try validate(request)
        try checkCancelled()

        // Residência é do coordenador: este motor não carrega nada por conta própria.
        guard let resident = loaded, resident.model == candidate.model else {
            throw TranscriptionEngineFailure.modelUnavailable(candidate.model)
        }
        let token = resident.residencyToken
        let languageCode = WhisperKitEngineSupport.whisperLanguageCode(for: request.language)

        // A espera é cancelável: um lote descartado não segura a fila de quem vem depois. A
        // posse da vaga é o valor devolvido — `false` significa que saímos da fila e NÃO a
        // temos, então não há o que devolver.
        guard await acquireSlot(cancellable: true) else {
            throw TranscriptionEngineFailure.cancelled
        }
        defer { releaseSlot() }

        // Cancelamento PRIMEIRO, residência depois — a ordem importa. No handoff em que o
        // waiter é servido já cancelado, quem zerou `loaded` foi justamente o `unload` que
        // acabou de soltar a vaga para ele: conferir a residência antes faria um trabalho
        // **cancelado** sair como `modelUnavailable`, que permite fallback — e o coordenador
        // transcreveria em outro motor um lote que ninguém queria mais. É a mesma ordem que o
        // Parakeet usa depois de conquistar a vaga.
        try checkCancelled()

        // Re-confere a residência ao acordar: entre entrar na fila e ser servido, um `unload`
        // ou uma troca de modelo pode ter liberado a sessão em que íamos entrar.
        guard let current = loaded, current.residencyToken == token else {
            throw TranscriptionEngineFailure.modelUnavailable(candidate.model)
        }

        let startTime = Date()
        let output: WhisperKitSessionOutput
        do {
            output = try await current.session.transcribe(
                samples: request.audio.samples,
                languageCode: languageCode,
                context: request.context
            )
        } catch {
            throw WhisperKitEngineSupport.inferenceFailure(for: error, model: candidate.model)
        }

        // Borda posterior: `WhisperKit.transcribe` não é interrompível por dentro, então ele
        // pode ter terminado normalmente **depois** do cancelamento. Devolver sucesso para um
        // trabalho que já foi descartado seria mentira — e, no coordenador, texto de um lote
        // que ninguém queria mais.
        try checkCancelled()

        return Self.makeResult(
            output: output,
            requestedLanguageCode: languageCode,
            request: request,
            candidate: candidate,
            processingTime: Date().timeIntervalSince(startTime)
        )
    }

    // MARK: - Carga

    /// Executa UMA carga, com a recuperação de modelo corrompido embutida.
    ///
    /// Roda com a vaga na mão do começo ao fim: é isso que impede a sessão anterior de ser
    /// liberada por baixo de uma inferência viva, e é o que dá a garantia pós-`prepare`.
    private func runLoad(
        model: TranscriptionModelID,
        variant: String,
        id: Int
    ) async throws {
        guard await acquireSlot(cancellable: true) else {
            // Desistiu da fila por cancelamento. Não conquistou a vaga, então não a devolve.
            if isCurrent(id) { loadTask = nil }
            throw TranscriptionEngineFailure.cancelled
        }
        defer { releaseSlot() }

        // Superada enquanto esperávamos a vez: nem começa.
        guard isCurrent(id) else { throw TranscriptionEngineFailure.cancelled }

        // A geração nasce aqui, com a vaga na mão.
        let generation = nextGeneration()

        // Com a vaga na mão, a troca de modelo é segura: nenhuma inferência está dentro da
        // sessão antiga, e nenhuma nova entra até soltarmos a vaga.
        let previous = loaded
        loaded = nil
        await previous?.session.release()

        // Laço, e não recursão: a recuperação é uma volta só, e o `continue` mantém óbvio que
        // não há caminho para um segundo re-download.
        var recoveryAvailable = recoveryAttemptedModel != model

        while true {
            do {
                try checkCancelled()
                guard isCurrent(id) else { throw TranscriptionEngineFailure.cancelled }

                // Já no disco → vai direto pro "carregando"; senão, começa o gauge em 0.
                emit(
                    runtime.isModelDownloaded(variant: variant)
                        ? .loading(model: model)
                        : .downloading(model: model, fraction: 0),
                    generation: generation
                )

                let observer = self.observer
                let folder = try await runtime.downloadModel(
                    variant: variant,
                    onProgress: { fraction in
                        observer?(WhisperKitLoadEvent(
                            generation: generation,
                            stage: .downloading(model: model, fraction: fraction)
                        ))
                    }
                )

                try checkCancelled()
                guard isCurrent(id) else { throw TranscriptionEngineFailure.cancelled }
                emit(.loading(model: model), generation: generation)

                let session = try await runtime.loadSession(modelFolder: folder)

                // Ponto crítico: a sessão existe, mas talvez ninguém a queira mais. Soltá-la
                // aqui é o que faz `unload()` valer mesmo quando corre contra a carga.
                guard !Task.isCancelled, isCurrent(id) else {
                    await session.release()
                    throw TranscriptionEngineFailure.cancelled
                }

                loadTask = nil
                loaded = LoadedModel(model: model, session: session, residencyToken: generation)
                emit(.ready(model: model), generation: generation)
                return
            } catch {
                let failure = WhisperKitEngineSupport.loadFailure(for: error, model: model)

                // Modelo incompleto/corrompido (ex.: download interrompido deixou um weight.bin
                // faltando). Apaga a pasta e re-baixa limpo — uma vez só, por modelo.
                if recoveryAvailable, WhisperKitEngineSupport.isIncompleteModelError(error) {
                    recoveryAvailable = false
                    recoveryAttemptedModel = model
                    try checkCancelled()
                    guard isCurrent(id) else { throw TranscriptionEngineFailure.cancelled }
                    print("⚠️ Modelo '\(variant)' incompleto/corrompido — apagando e re-baixando…")
                    runtime.removeModelFolder(variant: variant)
                    continue
                }

                // Superada enquanto falhava: a falha é de uma carga que ninguém quer mais.
                guard isCurrent(id) else { throw TranscriptionEngineFailure.cancelled }
                loadTask = nil

                // Cancelamento não é defeito do modelo: fora do cache negativo, senão a próxima
                // tentativa do usuário nasceria condenada.
                if failure != .cancelled {
                    failedModel = FailedModel(model: model, failure: failure)
                    emit(.failed(model: model, failure: failure), generation: generation)
                    print("❌ WhisperKit initialization failed (\(model.rawValue)): \(failure)")
                }
                throw failure
            }
        }
    }

    /// A carga `id` ainda é a que vale?
    private func isCurrent(_ id: Int) -> Bool {
        loadTask?.id == id
    }

    // MARK: - Validação e resultado

    /// Barra o que o motor sabe de antemão que não vai dar certo. Simétrico ao Parakeet da
    /// T2.2: o coordenador não pode assumir que um motor pré-valida e o outro não.
    private func validate(_ request: TranscriptionRequest) throws {
        // O descritor declara `supportsStreaming: true` por causa da janela deslizante da T4.1,
        // que é outro objeto. Este aqui é o caminho em lote: a prévia da reunião não entra.
        guard descriptor.supportedUseCases.contains(request.useCase), !request.useCase.requiresStreaming else {
            throw TranscriptionEngineFailure.engineInternal(
                "caso de uso \(request.useCase.rawValue) fora do WhisperKit em lote"
            )
        }

        if let language = request.language {
            guard descriptor.supports(language: language) else {
                throw TranscriptionEngineFailure.languageUnsupported(language)
            }
        } else {
            guard descriptor.detectsLanguageAutomatically else {
                throw TranscriptionEngineFailure.engineInternal(
                    "pedido com detecção automática num motor que não detecta idioma"
                )
            }
        }

        if let invalid = WhisperKitEngineSupport.validate(request.audio) {
            throw invalid
        }
    }

    private nonisolated static func makeResult(
        output: WhisperKitSessionOutput,
        requestedLanguageCode: String?,
        request: TranscriptionRequest,
        candidate: TranscriptionRoutingCandidate,
        processingTime: TimeInterval
    ) -> TranscriptionEngineResult {
        TranscriptionEngineResult(
            text: request.useCase == .dictation ? output.text.trimmingCharacters(in: .whitespacesAndNewlines)
                : WhisperKitEngineSupport.sanitize(output.text),
            segments: output.segments.map {
                TranscriptionTextSegment(text: $0.text, start: $0.start, end: $0.end, confidence: $0.confidence)
            },
            detectedLanguage: WhisperKitEngineSupport.detectedLanguage(
                fromWhisperCode: requestedLanguageCode ?? output.language
            ),
            provenance: TranscriptionProvenance(candidate: candidate, useCase: request.useCase),
            processingTime: processingTime,
            vocabularyTermsUsed: output.vocabularyTermsUsed
        )
    }

    // MARK: - Vaga única

    /// Conquista a vaga. Devolve `false` só quando `cancellable` e o chamador foi cancelado
    /// enquanto esperava — nesse caso ele **não** tem a vaga e não deve chamar `releaseSlot()`.
    ///
    /// A posse é o valor devolvido, e não um efeito colateral observado depois: o `onCancel` de
    /// um `withTaskCancellationHandler` não pode tocar o ator direto, então ele agenda um hop, e
    /// o `releaseSlot()` pode servir este mesmo waiter antes de o hop rodar. Decidir a posse por
    /// "alguém me marcou como desistente?" perde essa corrida e faz um chamador lançar já sendo
    /// dono da vaga — vaga vazada, motor travado para sempre. Com o `Bool`, quem foi servido
    /// recebe `true` haja o que houver, registra o `defer` e devolve a vaga mesmo se lançar
    /// logo em seguida por cancelamento.
    private func acquireSlot(cancellable: Bool = false) async -> Bool {
        guard slotBusy else {
            slotBusy = true
            return true
        }
        let ticket = nextTicket()
        guard cancellable else {
            return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                slotWaiters.append(SlotWaiter(ticket: ticket, continuation: continuation))
            }
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                slotWaiters.append(SlotWaiter(ticket: ticket, continuation: continuation))
            }
        } onCancel: {
            Task { await self.abandonSlot(ticket: ticket) }
        }
    }

    /// Sai da fila. Se já tiver sido servido, não faz nada: quem foi servido tem a vaga e é ele
    /// quem a devolve.
    private func abandonSlot(ticket: Int) {
        guard let index = slotWaiters.firstIndex(where: { $0.ticket == ticket }) else { return }
        slotWaiters.remove(at: index).continuation.resume(returning: false)
    }

    /// Passa a vaga adiante em ordem de chegada. Não solta `slotBusy` quando há fila, senão um
    /// recém-chegado furaria a fila de quem já espera.
    private func releaseSlot() {
        if slotWaiters.isEmpty {
            slotBusy = false
        } else {
            slotWaiters.removeFirst().continuation.resume(returning: true)
        }
    }

    // MARK: - Estado em voo

    /// Cancela a carga em voo e aguarda ela terminar de verdade.
    private func abort(_ inflight: InflightLoad) async {
        guard loadTask?.id == inflight.id else { return }
        loadTask = nil
        inflight.task.cancel()
        _ = try? await inflight.task.value
    }

    private func checkCancelled() throws {
        if Task.isCancelled { throw TranscriptionEngineFailure.cancelled }
    }

    private func nextGeneration() -> Int {
        generationCounter += 1
        return generationCounter
    }

    private func nextLoadID() -> Int {
        loadIDCounter += 1
        return loadIDCounter
    }

    private func nextTicket() -> Int {
        ticketCounter += 1
        return ticketCounter
    }

    private func emit(_ stage: WhisperKitLoadEvent.Stage, generation gen: Int) {
        observer?(WhisperKitLoadEvent(generation: gen, stage: stage))
    }
}
