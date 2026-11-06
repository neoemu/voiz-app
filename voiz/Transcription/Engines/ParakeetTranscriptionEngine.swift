import Foundation

// Adapter da T2.2: liga o `ParakeetTranscriptionService` — o spike que já roda no app — ao
// contrato `BatchTranscriptionEngine` da Onda 1, sob o contrato de ciclo de vida fechado em
// DECISOES (2026-08-07, pós-reviews T2.1/T2.2).
//
// Este arquivo depende **só de Foundation**, igual a `Transcription/Contracts/`. É isso que
// permite compilá-lo no alvo `voizTests` e exercitar o motor inteiro com dublê, sem FluidAudio,
// sem CoreML e sem baixar 600 MB de pesos. Quem fala com o serviço de verdade é
// `ParakeetServiceRuntime` (também puro, também testado) sobre `ParakeetServiceCalls`, cuja
// única implementação de produção — a que precisa de FluidAudio — mora em
// `ParakeetTranscriptionServiceCalls.swift`, fora dos testes.
//
// Nada no app instancia este motor: quem constrói motores é o coordenador da T2.3. Até lá o
// comportamento do Parakeet no app continua sendo exatamente o do serviço.

/// O runtime do Parakeet, reduzido ao que o motor precisa.
///
/// Parametrizado por `TranscriptionModelID` de propósito: na Onda 5 o TAGARELA CoreML entra no
/// mesmo runtime (`AsrModels.load(from:)`), e um seam que carrega "o Parakeet" sem dizer qual
/// deixaria a proveniência mentir sobre o modelo que produziu o texto — que é justamente o dado
/// em que o gate de benchmark se apoia. Quem não sabe carregar um id **recusa**.
nonisolated protocol ParakeetRuntime: Sendable {
    /// Baixa (se preciso) e carrega os pesos de `model`.
    ///
    /// Lança `ParakeetRuntimeError`. Cancelamento chega como `.cancelled`, nunca disfarçado de
    /// falha de runtime — é o que impede o coordenador de tratar um cancelamento como defeito do
    /// modelo e cair para outro motor.
    func load(model: TranscriptionModelID) async throws

    /// Transcreve um bloco de áudio mono a 16 kHz com os pesos de `model` já carregados.
    ///
    /// `language == nil` é detecção automática — o Parakeet v3 é multilíngue e decide sozinho;
    /// o idioma pedido só rotula o resultado.
    func transcribe(
        samples: [Float],
        language: TranscriptionLanguage?,
        model: TranscriptionModelID
    ) async throws -> ParakeetRuntimeOutput

    /// Libera os pesos de fato. Sem isto a regra de "um modelo pesado residente" da T2.3 é
    /// inexequível para o Parakeet (600 MB, `weight: .heavy` no descritor).
    func release() async
}

/// O resultado cru de uma inferência do Parakeet, sem os tipos de UI do app.
///
/// O Parakeet v3 devolve uma utterance só — daí não haver lista de segmentos aqui; quem monta o
/// segmento único do contrato é o motor.
nonisolated struct ParakeetRuntimeOutput: Sendable, Equatable {
    var text: String
    /// Confiança que o runtime reportou. Escala própria do Parakeet.
    var confidence: Float
    /// Duração do áudio reconhecido, em segundos, como o runtime reportou. `0` = não reportou.
    var duration: TimeInterval
    /// Tempo de parede da inferência, medido pelo serviço.
    var processingTime: TimeInterval

    init(
        text: String,
        confidence: Float = 0,
        duration: TimeInterval = 0,
        processingTime: TimeInterval = 0
    ) {
        self.text = text
        self.confidence = confidence
        self.duration = duration
        self.processingTime = processingTime
    }
}

/// As falhas que o runtime do Parakeet sabe distinguir.
///
/// Enum próprio, e não `TranscriptionService.TranscriptionError`: aquele é o erro do singleton do
/// Whisper, e classificar falha do Parakeet por ele acopla dois motores que não têm nada a ver um
/// com o outro (MENOR da review de arquitetura). Nenhum caso carrega texto transcrito — as
/// descrições são técnicas, para log.
nonisolated enum ParakeetRuntimeError: Error, Sendable, Equatable {
    /// Download ou carga dos pesos falhou; o runtime não está utilizável.
    case modelsUnavailable(String)
    /// O runtime não sabe carregar este id de modelo.
    case unsupportedModel(TranscriptionModelID)
    /// O runtime está carregado mas a inferência falhou.
    case runtimeFailure(String)
    /// O trabalho foi cancelado. Caso próprio porque cancelamento **não** é defeito do modelo:
    /// não permite fallback e não pode entrar no cache negativo.
    case cancelled
}

/// O Parakeet v3 (FluidAudio) como motor em lote do contrato da Onda 1.
///
/// `actor` porque `TranscriptionEngine` é `Sendable` e o coordenador vai usá-lo de tarefas
/// concorrentes. Atenção ao que o ator **não** dá: ele serializa o acesso ao estado do motor, não
/// ao recurso caro — em todo `await` o executor é liberado. A serialização do runtime é a vaga
/// única explícita mais abaixo.
///
/// O motor é fino de propósito: valida o pedido contra o descritor, controla o ciclo de vida dos
/// pesos e traduz erro. Reconhecimento de fala continua inteiro no serviço.
actor ParakeetTranscriptionEngine: BatchTranscriptionEngine {

    /// O que acontece com os pesos, para quem quiser mostrar isso na tela.
    ///
    /// `generation` é o id monotônico da carga que emitiu o evento. Existe porque o
    /// `TranscriptionRuntimeStore` da T2.3 é `@MainActor` e vai precisar hopar: sem o id, um
    /// evento de uma carga já morta (cancelada por `unload` ou por troca de modelo) chegaria
    /// depois e sobrescreveria o estado da carga viva. Regra do store: descartar evento com
    /// geração menor que a última vista.
    ///
    /// Não há `downloading(fraction:)`: o serviço baixa e carrega numa chamada só
    /// (`AsrModels.downloadAndLoad()`) e não expõe progresso. Inventar fração aqui seria mentira
    /// na barra de progresso.
    nonisolated enum LoadEvent: Sendable, Equatable {
        /// Baixando e/ou carregando os pesos.
        case loading(model: TranscriptionModelID, generation: Int)
        case ready(model: TranscriptionModelID, generation: Int)
        case failed(model: TranscriptionModelID, failure: TranscriptionEngineFailure, generation: Int)
        /// Pesos liberados; nenhum modelo residente.
        case unloaded(generation: Int)
    }

    /// Uma carga em voo.
    ///
    /// `id` é identidade (serve ao "esta carga ainda é a que vale?"); a **geração** do evento é
    /// outra coisa e nasce lá dentro, já com a vaga na mão — ver `runLoad`.
    private struct Load {
        var id: Int
        var model: TranscriptionModelID
        var task: Task<Void, any Error>
    }

    /// Alguém esperando a vaga do runtime.
    private struct SlotWaiter {
        var ticket: Int
        /// `true` = a vaga é sua; `false` = você desistiu (foi cancelado) e não deve devolvê-la.
        var continuation: CheckedContinuation<Bool, Never>
    }

    nonisolated let descriptor: TranscriptionEngineDescriptor

    private let runtime: any ParakeetRuntime
    private let observer: (@Sendable (LoadEvent) -> Void)?

    /// Modelo com pesos residentes. `nil` = nada carregado.
    private var loadedModel: TranscriptionModelID?

    /// A carga em voo, compartilhada por todos que a estiverem esperando. É o single-flight: sem
    /// ela, um `prepare` concorrente bate no `guard !isInitialized && !isLoading` do serviço,
    /// volta na hora e vira `modelUnavailable` **espúrio** enquanto a carga certa segue saudável
    /// — no coordenador isso viraria fallback com proveniência mentirosa e, sob
    /// `strictEngineSelection`, falha dura.
    private var loading: Load?

    /// Modelo cuja carga já falhou, com a falha. Enquanto for este o modelo pedido, `prepare`
    /// re-lança na hora em vez de tentar baixar de novo.
    ///
    /// É o `failedModel` do motor do Whisper, e existe pelo mesmo motivo: sem ele, uma reunião de
    /// 40 lotes tentaria 40 downloads do mesmo modelo quebrado. Simetria entre os dois motores é
    /// requisito do contrato de ciclo de vida — política de retry é da T2.3/T2.5, não daqui. Sai
    /// do caminho ao pedir outro modelo ou ao chamar `unload()`.
    private var failedModel: (model: TranscriptionModelID, failure: TranscriptionEngineFailure)?

    private var generationCounter = 0
    private var loadIDCounter = 0
    private var ticketCounter = 0

    // MARK: Vaga única do runtime
    //
    // O ator libera o executor em todo `await`: duas chamadas de `transcribe` entram as duas e
    // chegam juntas ao `AsrManager`. Duas inferências simultâneas na ANE é exatamente a regressão
    // de performance já registrada nas reuniões (o worker único com lotes veio disso). Esta fila
    // FIFO é o gate explícito.
    //
    // A exclusão é **total** (contrato de ciclo de vida, item 11): inferência × inferência,
    // ciclo de vida × inferência e ciclo de vida × ciclo de vida. Toda mutação de estado que
    // acompanha os pesos — trocar de modelo, carregar, liberar — acontece com a vaga na mão. Sem
    // isso, a troca de modelo chamava `AsrManager.cleanup()` por baixo de uma inferência viva
    // (violando a precondição que o próprio `ParakeetTranscriptionService.release()` documenta),
    // e um `unload` que se intercalasse num `prepare` soltava os pesos recém-carregados deixando
    // `loadedModel` apontar para o que não existe mais.
    private var slotBusy = false
    private var slotWaiters: [SlotWaiter] = []

    /// O descritor entra por parâmetro só para os testes conseguirem descrever um Parakeet
    /// hipotético; em produção é sempre o do catálogo — motor e descritor discordarem é bug.
    ///
    /// O runtime é injeção **obrigatória**: sem construtor default, ninguém cria um segundo
    /// serviço Parakeet por engano, e a residência dos pesos continua sendo do coordenador.
    init(
        runtime: any ParakeetRuntime,
        descriptor: TranscriptionEngineDescriptor = .parakeet,
        observer: (@Sendable (LoadEvent) -> Void)? = nil
    ) {
        self.runtime = runtime
        self.descriptor = descriptor
        self.observer = observer
    }

    // MARK: - TranscriptionEngine

    /// Idempotente e single-flight: com o modelo já carregado não faz nada; com a carga dele em
    /// voo, **aguarda a mesma carga** em vez de disparar outra.
    ///
    /// Garantia pós-`prepare` (contrato, item 12): quando esta função devolve sem erro, o modelo
    /// pedido está residente.
    ///
    /// **Quando houve carga** — isto é, em todo caminho que passou por `runLoad`, inclusive o de
    /// quem aguardou a carga de outro —, vale também a parte forte: nenhuma inferência anterior a
    /// esta chamada continua em voo, porque carga e inferência dividem a mesma vaga e tudo que
    /// estava na fila antes já terminou.
    ///
    /// No caminho rápido (o modelo pedido já é o residente) esta função devolve **sem tomar a
    /// vaga**, então uma inferência que já estava rodando pode continuar rodando. É deliberado, e
    /// igual nos dois motores: fazer o caminho rápido enfileirar transformaria um `prepare`
    /// barato — que o coordenador chama por lote — numa espera pela inferência anterior. Quem
    /// precisa de "nada em voo" precisa de `unload()`, que sempre drena.
    func prepare(model: TranscriptionModelID) async throws {
        try checkCancellation()
        // Validação do id ANTES de tocar em qualquer estado (contrato, item 13): um id
        // desconhecido — seleção salva de uma versão antiga, catálogo que mudou — não pode
        // evictar o modelo que está funcionando, nem deixar latch.
        guard descriptor.model(model) != nil else {
            throw TranscriptionEngineFailure.modelUnavailable(model)
        }

        // Carga em voo: ou é a que queremos (e esperamos a MESMA Task), ou ela perde a vez.
        if let inFlight = loading {
            if inFlight.model == model {
                try await inFlight.task.value
                try checkCancellation()
                return
            }
            // Cancela e **espera terminar** fora da vaga — a Task dela é quem segura a vaga, e
            // esperá-la segurando seria travar o motor contra si mesmo.
            loading = nil
            inFlight.task.cancel()
            _ = try? await inFlight.task.value
        }

        // Caminho rápido: já é o residente, devolve sem tomar a vaga. Ver a ressalva no doc
        // comment — aqui a garantia é "o modelo pedido está residente", e só.
        if loadedModel == model { return }
        if let failedModel, failedModel.model == model { throw failedModel.failure }
        failedModel = nil

        let id = nextLoadID()
        let load = Load(
            id: id,
            model: model,
            // `Task` herda o isolamento do ator, então `runLoad` roda aqui dentro e a mutação de
            // estado acontece exatamente uma vez, por mais gente que esteja esperando.
            task: Task { try await self.runLoad(model: model, id: id) }
        )
        loading = load

        try await load.task.value
        try checkCancellation()
    }

    func unload() async {
        // Fora da vaga: matar a carga em voo. A Task dela é quem segura a vaga.
        if let dying = loading {
            loading = nil
            dying.task.cancel()
            // Esperar de verdade: um `unload` que devolve com a carga ainda correndo faz o
            // coordenador achar que abriu espaço e carregar o pesado do outro motor por cima.
            _ = try? await dying.task.value
        }

        // Daqui para baixo, com a vaga na mão: estado, pesos e evento mudam juntos.
        //
        // O `loadedModel = nil` mora **aqui dentro**, e não lá em cima, de propósito: se um
        // `prepare` se intercalou enquanto esperávamos, a carga dele terminou antes de nós (a
        // fila é FIFO) e deixou `loadedModel` preenchido. Zerar antes e não zerar de novo era o
        // que deixava o motor afirmar estar preparado sobre pesos já descartados — e aí o
        // auto-init legado do serviço recarregava 600 MB em silêncio, fora dos livros do
        // coordenador.
        _ = await acquireSlot()
        defer { releaseSlot() }

        // Geração tirada aqui, e não na entrada: assim a ordem das gerações é a ordem das
        // mutações, e o store nunca recebe um `.unloaded` mais novo que um `.ready` posterior.
        let generation = nextGeneration()
        loadedModel = nil
        failedModel = nil
        await runtime.release()
        observer?(.unloaded(generation: generation))
    }

    // MARK: - BatchTranscriptionEngine

    func transcribe(
        _ request: TranscriptionRequest,
        candidate: TranscriptionRoutingCandidate
    ) async throws -> TranscriptionEngineResult {
        try checkCancellation()
        try validate(request)

        // **Não** prepara sozinho: a residência dos pesos é decisão do coordenador (T2.3). Um
        // `transcribe` que carrega 600 MB por trás de uma fila de lotes desfaz a prioridade
        // "interativo antes de batch" — vira thrash de carga/descarga.
        guard loadedModel == candidate.model else {
            throw TranscriptionEngineFailure.modelUnavailable(candidate.model)
        }

        guard await acquireSlot(cancellable: true) else {
            throw TranscriptionEngineFailure.cancelled
        }
        defer { releaseSlot() }

        // Entre a fila e a inferência o mundo muda: o coordenador pode ter descarregado para
        // atender um pedido interativo, ou este trabalho pode ter sido abortado.
        try checkCancellation()
        guard loadedModel == candidate.model else {
            throw TranscriptionEngineFailure.modelUnavailable(candidate.model)
        }

        let output: ParakeetRuntimeOutput
        do {
            output = try await runtime.transcribe(
                samples: request.audio.samples,
                language: request.language,
                model: candidate.model
            )
        } catch {
            throw Self.failure(from: error, model: candidate.model)
        }

        // Borda **posterior**: `AsrManager.transcribe` não é interrompível por dentro, então uma
        // inferência cancelada no meio ainda termina normalmente. Entregar esse texto como
        // sucesso seria devolver resultado de um trabalho que alguém mandou parar.
        try checkCancellation()

        let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Quando o runtime não reporta duração, o segmento cobre o áudio pedido — é a única
        // informação verdadeira que temos, e um segmento de duração zero não serve para ninguém.
        let end = output.duration > 0 ? output.duration : request.audio.duration

        return TranscriptionEngineResult(
            text: text,
            // O Parakeet v3 não segmenta: é uma utterance só. Texto vazio não vira segmento
            // vazio — segmento sem texto só polui o transcript de quem consome o resultado.
            segments: text.isEmpty ? [] : [
                TranscriptionTextSegment(text: text, start: 0, end: end, confidence: output.confidence)
            ],
            // O Parakeet não expõe o idioma que detectou. O app já resolve isso assumindo
            // português quando o pedido é automático, e a T2.2 não pode mudar esse comportamento.
            detectedLanguage: request.language ?? .portuguese,
            provenance: TranscriptionProvenance(candidate: candidate, useCase: request.useCase),
            processingTime: output.processingTime
        )
    }

    // MARK: - Carga

    /// O corpo da carga, rodando dentro do ator. Só ele mexe no estado de carga — por isso a
    /// mutação acontece uma vez só, independentemente de quantos `prepare` estejam esperando.
    private func runLoad(model: TranscriptionModelID, id: Int) async throws {
        guard await acquireSlot(cancellable: true) else {
            // Desistiu da fila por cancelamento. Não conquistou a vaga, então não a devolve.
            if isCurrent(id) { loading = nil }
            throw TranscriptionEngineFailure.cancelled
        }
        defer { releaseSlot() }

        // Superada enquanto esperávamos a vez: nem começa.
        guard isCurrent(id) else { throw TranscriptionEngineFailure.cancelled }

        // A geração nasce aqui, com a vaga na mão — não na fila. É o que mantém a ordem das
        // gerações igual à ordem das mutações para quem observa de fora.
        let generation = nextGeneration()
        observer?(.loading(model: model, generation: generation))

        do {
            try checkCancellation()
            // Troca de modelo: os pesos antigos saem **aqui**, com a vaga na mão. Fora dela isto
            // era `AsrManager.cleanup()` por baixo de uma inferência viva.
            if loadedModel != nil {
                loadedModel = nil
                await runtime.release()
            }
            try checkCancellation()
            try await runtime.load(model: model)
        } catch {
            let failure = Self.failure(from: error, model: model)
            guard isCurrent(id) else { throw TranscriptionEngineFailure.cancelled }
            loading = nil
            // Cancelamento não é defeito do modelo: fora do cache negativo, senão a próxima
            // tentativa do usuário nasceria condenada.
            if failure != .cancelled { failedModel = (model, failure) }
            observer?(.failed(model: model, failure: failure, generation: generation))
            throw failure
        }

        guard isCurrent(id) else {
            // Um `unload` (ou uma troca de modelo) aconteceu enquanto carregávamos. O modelo
            // **não** ressuscita: solta o que a carga acabou de deixar pronto.
            await runtime.release()
            throw TranscriptionEngineFailure.cancelled
        }
        loading = nil
        loadedModel = model
        observer?(.ready(model: model, generation: generation))
    }

    /// A carga `id` ainda é a que vale?
    private func isCurrent(_ id: Int) -> Bool {
        loading?.id == id
    }

    private func nextGeneration() -> Int {
        generationCounter += 1
        return generationCounter
    }

    private func nextLoadID() -> Int {
        loadIDCounter += 1
        return loadIDCounter
    }

    // MARK: - Vaga única

    /// Conquista a vaga. Devolve `false` só quando `cancellable` e o chamador foi cancelado
    /// enquanto esperava — nesse caso ele **não** tem a vaga e não deve chamar `releaseSlot()`.
    ///
    /// `cancellable: false` é para o `unload`: descarregar memória é justamente o que não pode
    /// desistir no meio.
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
        // Trabalho cancelado sai da fila em vez de segurar a vez de quem vem depois — com
        // "interativo antes de batch", um lote cancelado segurando a fila é atraso puro.
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

    private func nextTicket() -> Int {
        ticketCounter += 1
        return ticketCounter
    }

    // MARK: - Validação e erro

    /// Barra o que o motor sabe de antemão que não vai dar certo — antes de gastar a vaga do
    /// runtime com um pedido que não tem como ser atendido.
    private func validate(_ request: TranscriptionRequest) throws {
        guard descriptor.supports(useCase: request.useCase) else {
            // Na prática é a prévia da reunião: ela exige streaming, e este motor é só lote.
            throw TranscriptionEngineFailure.engineInternal(
                "caso de uso \(request.useCase.rawValue) fora do Parakeet em lote"
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

        guard !request.audio.isEmpty else {
            throw TranscriptionEngineFailure.invalidAudio("áudio vazio")
        }
        guard request.audio.sampleRate == TranscriptionAudio.defaultSampleRate else {
            throw TranscriptionEngineFailure.invalidAudio(
                "áudio a \(Int(request.audio.sampleRate)) Hz; o Parakeet só aceita 16 kHz"
            )
        }
    }

    /// Cancelamento cooperativo nas bordas. `AsrManager.transcribe` não é interrompível por
    /// dentro, mas checar aqui evita gastar download e inferência em trabalho já descartado — que
    /// é a única alavanca que o coordenador tem para priorizar o interativo sobre o batch.
    private func checkCancellation() throws {
        if Task.isCancelled { throw TranscriptionEngineFailure.cancelled }
    }

    /// Traduz o erro do runtime para o vocabulário que o coordenador entende.
    ///
    /// O que está em jogo é o `allowsFallback`: `cancelled` não tenta outro motor,
    /// `modelUnavailable` e `engineInternal` tentam.
    private static func failure(
        from error: any Error,
        model: TranscriptionModelID
    ) -> TranscriptionEngineFailure {
        switch error {
        case let failure as TranscriptionEngineFailure:
            return failure
        case let runtime as ParakeetRuntimeError:
            switch runtime {
            case .modelsUnavailable, .unsupportedModel:
                return .modelUnavailable(model)
            case .runtimeFailure(let description):
                return .engineInternal(description)
            case .cancelled:
                return .cancelled
            }
        case is CancellationError:
            return .cancelled
        default:
            return .engineInternal(error.localizedDescription)
        }
    }
}
