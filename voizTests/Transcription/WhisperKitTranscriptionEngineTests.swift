import Testing
import Foundation

/// Testes do ciclo de vida do `WhisperKitTranscriptionEngine` com o runtime dublê.
///
/// A primeira versão desta tarefa foi reprovada com três CRÍTICOS — carga duplicada sob
/// concorrência, inferência não serializada e `unload` que não descarregava — todos no trecho
/// que nenhum teste tocava, porque o motor falava direto com a biblioteca. Estes testes existem
/// para que esse trecho passe a ser justamente o mais coberto: cada um deles reprova se a
/// respectiva garantia sumir.
@Suite("Motor WhisperKit — ciclo de vida")
struct WhisperKitTranscriptionEngineTests {

    private func makeEngine(
        runtime: FakeWhisperKitRuntime,
        recorder: LoadEventRecorder? = nil
    ) -> WhisperKitTranscriptionEngine {
        WhisperKitTranscriptionEngine(runtime: runtime, observer: recorder?.record)
    }

    // MARK: - prepare: single-flight

    @Test("prepare concorrente para o mesmo modelo faz UM download e UMA carga")
    func concurrentPrepareIsSingleFlight() async throws {
        // O CRÍTICO original: duas chamadas a frio passavam as duas pelo guard de `loaded` e
        // abriam duas cargas — 2× rede e 2× RAM, o motivo declarado de o serviço ser singleton.
        let downloadGate = TestGate()
        let runtime = FakeWhisperKitRuntime(downloadGate: downloadGate)
        let engine = makeEngine(runtime: runtime)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { try await engine.prepare(model: .whisperSmall) }
            }
            // Alguém já chegou ao download: as outras sete só podem estar aguardando a MESMA
            // carga, porque nenhuma segunda foi aberta.
            await downloadGate.waitForArrivals(1)
            downloadGate.open()
            try await group.waitForAll()
        }

        #expect(runtime.downloadCalls == ["openai_whisper-small"])
        #expect(runtime.loadCalls == 1)
        #expect(runtime.sessions.count == 1)
    }

    @Test("prepare sequencial repetido não recarrega nada")
    func repeatedPrepareIsIdempotent() async throws {
        let runtime = FakeWhisperKitRuntime()
        let engine = makeEngine(runtime: runtime)

        try await engine.prepare(model: .whisperSmall)
        try await engine.prepare(model: .whisperSmall)
        try await engine.prepare(model: .whisperSmall)

        #expect(runtime.downloadCalls.count == 1)
        #expect(runtime.loadCalls == 1)
    }

    @Test("Quem chega durante a carga recebe o sucesso dela, não modelUnavailable espúrio")
    func lateJoinerGetsTheRunningLoad() async throws {
        let downloadGate = TestGate()
        let runtime = FakeWhisperKitRuntime(downloadGate: downloadGate)
        let engine = makeEngine(runtime: runtime)

        let first = Task { try await engine.prepare(model: .whisperSmall) }
        await downloadGate.waitForArrivals(1)
        let second = Task { try await engine.prepare(model: .whisperSmall) }

        downloadGate.open()
        try await first.value
        try await second.value

        // Ambas voltaram sem erro e o modelo está utilizável.
        let result = try await engine.transcribe(.test(), candidate: .test())
        #expect(result.text == "[MÚSICA] olá  mundo")
        #expect(runtime.loadCalls == 1)
    }

    // MARK: - Ciclo de vida × inferência (CRITICO da rodada 2)

    @Test("Trocar de modelo com inferência EM VOO não libera os pesos por baixo dela")
    func switchingModelDrainsTheRunningInference() async throws {
        // O CRITICO convergente da rodada 2: o dreno existia só no `unload`. A troca de modelo
        // capturava a sessão anterior e chamava `release()` — que é `kit.unloadModels()` —
        // enquanto uma inferência ainda estava dentro de `kit.transcribe`.
        let sessionGate = TestGate()
        let runtime = FakeWhisperKitRuntime()
        runtime.useSessionGate(sessionGate)
        let engine = makeEngine(runtime: runtime)
        try await engine.prepare(model: .whisperSmall)
        let first = try #require(runtime.sessions.first)

        let transcribing = Task { try await engine.transcribe(.test(), candidate: .test()) }
        await sessionGate.waitForArrivals(1)

        let switching = Task { try await engine.prepare(model: .whisperLargeV3Turbo) }
        await Task.yield()
        #expect(first.releases == 0, "a troca de modelo não pode soltar os pesos com inferência viva")
        #expect(runtime.downloadCalls.count == 1, "a carga nova não pode começar antes do dreno")

        sessionGate.open()
        _ = try await transcribing.value
        try await switching.value

        #expect(first.releases == 1)
        #expect(first.concurrentAtRelease == 0, "os pesos foram soltos com a inferência ainda rodando")
    }

    @Test("Quando prepare retorna, o modelo pedido está residente e nada de antes segue em voo")
    func prepareGuaranteesResidencyAndDrain() async throws {
        // A garantia pós-prepare que o coordenador da T2.3 pode assumir dos DOIS motores.
        let sessionGate = TestGate()
        let runtime = FakeWhisperKitRuntime()
        runtime.useSessionGate(sessionGate)
        let engine = makeEngine(runtime: runtime)
        try await engine.prepare(model: .whisperSmall)
        let first = try #require(runtime.sessions.first)

        let transcribing = Task { try await engine.transcribe(.test(), candidate: .test()) }
        await sessionGate.waitForArrivals(1)
        let switching = Task { try await engine.prepare(model: .whisperBase) }
        await Task.yield()
        sessionGate.open()
        try await switching.value

        // No instante em que `prepare` devolveu: nada da sessão antiga em voo, e é o modelo
        // pedido que está residente.
        #expect(first.concurrentAtRelease == 0)
        _ = try await engine.transcribe(.test(), candidate: .test(model: .whisperBase))
        await #expect(throws: TranscriptionEngineFailure.modelUnavailable(.whisperSmall)) {
            try await engine.transcribe(.test(), candidate: .test(model: .whisperSmall))
        }
        _ = try await transcribing.value
    }

    @Test("Trabalho enfileirado re-confere a residência ao acordar")
    func queuedWorkRechecksResidency() async throws {
        // Entre entrar na fila e ser servido, o modelo pode ter sido trocado. Sem a
        // re-conferência, o trabalho entraria numa sessão já descarregada.
        let sessionGate = TestGate()
        let runtime = FakeWhisperKitRuntime()
        runtime.useSessionGate(sessionGate)
        let engine = makeEngine(runtime: runtime)
        try await engine.prepare(model: .whisperSmall)
        let first = try #require(runtime.sessions.first)

        let running = Task { try await engine.transcribe(.test(), candidate: .test()) }
        await sessionGate.waitForArrivals(1)
        // Este entra na fila atrás do que está rodando.
        let queued = Task { try await engine.transcribe(.test(), candidate: .test()) }
        await Task.yield()
        // E a troca de modelo entra atrás dos dois.
        let switching = Task { try await engine.prepare(model: .whisperBase) }
        await Task.yield()

        sessionGate.open()
        _ = try await running.value
        try await switching.value

        // O enfileirado foi servido antes da troca (FIFO) e rodou na sessão certa; depois da
        // troca, a sessão antiga está liberada e ninguém mais entra nela.
        _ = try await queued.value
        #expect(first.calls == 2)
        #expect(first.concurrentAtRelease == 0)
        await #expect(throws: TranscriptionEngineFailure.modelUnavailable(.whisperSmall)) {
            try await engine.transcribe(.test(), candidate: .test(model: .whisperSmall))
        }
    }

    @Test("Carga e inferência disputam a MESMA vaga")
    func loadAndInferenceShareTheSlot() async throws {
        let sessionGate = TestGate()
        let runtime = FakeWhisperKitRuntime()
        runtime.useSessionGate(sessionGate)
        let engine = makeEngine(runtime: runtime)
        try await engine.prepare(model: .whisperSmall)

        let transcribing = Task { try await engine.transcribe(.test(), candidate: .test()) }
        await sessionGate.waitForArrivals(1)

        let loading = Task { try await engine.prepare(model: .whisperBase) }
        await Task.yield()
        await Task.yield()
        // A carga nem começou: ela está na fila da vaga, atrás da inferência.
        #expect(runtime.downloadCalls.count == 1)

        sessionGate.open()
        _ = try await transcribing.value
        try await loading.value
        #expect(runtime.downloadCalls.count == 2)
    }

    @Test("Trocar de modelo aborta a carga em voo e libera o modelo anterior")
    func switchingModelAbortsAndReleases() async throws {
        let runtime = FakeWhisperKitRuntime()
        let engine = makeEngine(runtime: runtime)

        try await engine.prepare(model: .whisperSmall)
        let firstSession = try #require(runtime.sessions.first)
        try await engine.prepare(model: .whisperLargeV3Turbo)

        #expect(firstSession.releases == 1, "o modelo anterior tem que sair da memória")
        #expect(runtime.downloadCalls == ["openai_whisper-small", "openai_whisper-large-v3_turbo"])

        // O motor agora só atende o modelo novo.
        await #expect(throws: TranscriptionEngineFailure.modelUnavailable(.whisperSmall)) {
            try await engine.transcribe(.test(), candidate: .test(model: .whisperSmall))
        }
        _ = try await engine.transcribe(.test(), candidate: .test(model: .whisperLargeV3Turbo))
    }

    @Test("Modelo de outro motor é recusado sem tocar a rede")
    func foreignModelNeverReachesTheNetwork() async {
        let runtime = FakeWhisperKitRuntime()
        let engine = makeEngine(runtime: runtime)

        await #expect(throws: TranscriptionEngineFailure.modelUnavailable(.parakeetTDT06BV3)) {
            try await engine.prepare(model: .parakeetTDT06BV3)
        }
        #expect(runtime.downloadCalls.isEmpty)
    }

    @Test("Modelo desconhecido NÃO evicta o modelo residente nem cria latch")
    func unknownModelDoesNotEvictTheResidentOne() async throws {
        // O teste anterior passava com o motor vazio. Este roda com o motor CARREGADO: a
        // validação do id tem que acontecer antes de tocar em qualquer estado.
        let runtime = FakeWhisperKitRuntime()
        let engine = makeEngine(runtime: runtime)
        try await engine.prepare(model: .whisperSmall)
        let session = try #require(runtime.sessions.first)

        let unknown = TranscriptionModelID("openai_whisper-tiny")
        await #expect(throws: TranscriptionEngineFailure.modelUnavailable(unknown)) {
            try await engine.prepare(model: unknown)
        }

        #expect(session.releases == 0, "um id inválido não pode descarregar quem estava funcionando")
        #expect(runtime.loadCalls == 1)
        // O modelo residente continua atendendo.
        _ = try await engine.transcribe(.test(), candidate: .test())

        // E não ficou latch: pedir o mesmo id de novo dá o mesmo erro, não um latch de outra coisa.
        await #expect(throws: TranscriptionEngineFailure.modelUnavailable(unknown)) {
            try await engine.prepare(model: unknown)
        }
        // O modelo bom também não foi latchado.
        try await engine.prepare(model: .whisperSmall)
        #expect(runtime.loadCalls == 1)
    }

    // MARK: - prepare: latch de falha

    @Test("Falha de carga vira latch: o modelo não é re-baixado a cada chamada")
    func failedModelIsLatched() async throws {
        // Sem o latch, uma reunião de 40 lotes tentaria 40 downloads do mesmo modelo quebrado.
        let runtime = FakeWhisperKitRuntime()
        runtime.failDownload(onAttempt: 1, with: FakeRuntimeError("Server returned 503"))
        let engine = makeEngine(runtime: runtime)

        do {
            try await engine.prepare(model: .whisperSmall)
            Issue.record("esperava falha de carga")
        } catch let failure as TranscriptionEngineFailure {
            // A mensagem sai de `localizedDescription`, que depende do idioma da máquina — o
            // que importa aqui é a classificação, não o texto.
            guard case .engineInternal = failure else {
                Issue.record("esperava engineInternal, veio \(failure)")
                return
            }
        }
        for _ in 0..<5 {
            _ = try? await engine.prepare(model: .whisperSmall)
        }

        #expect(runtime.downloadCalls.count == 1, "o latch deve impedir novas tentativas")
    }

    @Test("O latch sai com troca de modelo e com unload")
    func latchClearsOnModelSwitchAndUnload() async throws {
        let runtime = FakeWhisperKitRuntime()
        runtime.failDownload(onAttempt: 1, with: FakeRuntimeError("Server returned 503"))
        let engine = makeEngine(runtime: runtime)

        _ = try? await engine.prepare(model: .whisperSmall)
        #expect(runtime.downloadCalls.count == 1)

        // Troca de modelo: tentativa nova.
        try await engine.prepare(model: .whisperBase)
        #expect(runtime.downloadCalls.count == 2)

        runtime.failDownload(onAttempt: 3, with: FakeRuntimeError("Server returned 503"))
        _ = try? await engine.prepare(model: .whisperSmall)
        #expect(runtime.downloadCalls.count == 3)

        await engine.unload()
        try await engine.prepare(model: .whisperSmall)
        #expect(runtime.downloadCalls.count == 4, "unload limpa o latch")
    }

    // MARK: - prepare: recuperação de modelo corrompido

    @Test("Modelo corrompido é apagado e re-baixado — uma vez só")
    func corruptedModelIsRecoveredOnce() async throws {
        let runtime = FakeWhisperKitRuntime(downloadedVariants: ["openai_whisper-small"])
        runtime.failLoad(onAttempt: 1, with: FakeRuntimeError.corruptedModel)
        let engine = makeEngine(runtime: runtime)

        try await engine.prepare(model: .whisperSmall)

        #expect(runtime.removedVariants == ["openai_whisper-small"])
        #expect(runtime.downloadCalls.count == 2, "apagou e re-baixou")
        #expect(runtime.loadCalls == 2)
    }

    @Test("Corrompido duas vezes falha de vez: não há segundo re-download")
    func corruptedTwiceGivesUp() async {
        let runtime = FakeWhisperKitRuntime(downloadedVariants: ["openai_whisper-small"])
        runtime.failLoad(onAttempt: 1, with: FakeRuntimeError.corruptedModel)
        runtime.failLoad(onAttempt: 2, with: FakeRuntimeError.corruptedModel)
        let engine = makeEngine(runtime: runtime)

        await #expect(throws: TranscriptionEngineFailure.modelUnavailable(.whisperSmall)) {
            try await engine.prepare(model: .whisperSmall)
        }
        #expect(runtime.removedVariants.count == 1)
        #expect(runtime.downloadCalls.count == 2)
    }

    // MARK: - transcribe: sem auto-prepare

    @Test("transcribe sem prepare é modelUnavailable — residência é do coordenador")
    func transcribeDoesNotAutoPrepare() async {
        // Auto-preparar tirava do coordenador o controle de "um modelo pesado residente": o
        // próximo lote da fila recarregaria por trás dele o que ele acabou de descarregar.
        let runtime = FakeWhisperKitRuntime()
        let engine = makeEngine(runtime: runtime)

        await #expect(throws: TranscriptionEngineFailure.modelUnavailable(.whisperSmall)) {
            try await engine.transcribe(.test(), candidate: .test())
        }
        #expect(runtime.downloadCalls.isEmpty)
        #expect(runtime.loadCalls == 0)
    }

    @Test("transcribe com outro modelo preparado é modelUnavailable do modelo pedido")
    func transcribeRefusesAnotherModel() async throws {
        let runtime = FakeWhisperKitRuntime()
        let engine = makeEngine(runtime: runtime)
        try await engine.prepare(model: .whisperSmall)

        await #expect(throws: TranscriptionEngineFailure.modelUnavailable(.whisperMedium)) {
            try await engine.transcribe(.test(), candidate: .test(model: .whisperMedium))
        }
    }

    // MARK: - transcribe: serialização real

    @Test("Inferências concorrentes são serializadas: nunca duas na mesma sessão")
    func concurrentInferenceIsSerialized() async throws {
        // O ator NÃO garante isto: ele libera o executor em todo `await`. Quem garante é a fila
        // encadeada do motor. Duas inferências simultâneas na ANE são a regressão de
        // performance já vivida nas reuniões.
        let runtime = FakeWhisperKitRuntime()
        let engine = makeEngine(runtime: runtime)
        try await engine.prepare(model: .whisperSmall)
        let session = try #require(runtime.sessions.first)

        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<6 {
                group.addTask { try await engine.transcribe(.test(), candidate: .test()).text }
            }
            for try await text in group {
                #expect(text == "[MÚSICA] olá  mundo")
            }
        }

        #expect(session.calls == 6)
        #expect(session.maxConcurrent == 1, "houve mais de uma inferência em voo na mesma sessão")
    }

    @Test("Uma inferência presa não deixa a próxima entrar na sessão")
    func inferenceQueueBlocksBehindTheRunningOne() async throws {
        let sessionGate = TestGate()
        let runtime = FakeWhisperKitRuntime()
        runtime.useSessionGate(sessionGate)
        let engine = makeEngine(runtime: runtime)
        try await engine.prepare(model: .whisperSmall)
        let session = try #require(runtime.sessions.first)

        let first = Task { try await engine.transcribe(.test(), candidate: .test()) }
        await sessionGate.waitForArrivals(1)
        let second = Task { try await engine.transcribe(.test(), candidate: .test()) }

        // A segunda não pode ter chegado ao portão: ela está na fila do motor, não na sessão.
        await Task.yield()
        #expect(sessionGate.arrivals == 1)

        sessionGate.open()
        _ = try await first.value
        _ = try await second.value
        #expect(session.maxConcurrent == 1)
    }

    // MARK: - unload

    @Test("unload libera os pesos de fato e exige nova carga")
    func unloadReleasesWeights() async throws {
        let runtime = FakeWhisperKitRuntime()
        let engine = makeEngine(runtime: runtime)
        try await engine.prepare(model: .whisperSmall)
        let session = try #require(runtime.sessions.first)

        await engine.unload()

        #expect(session.releases == 1, "esquecer a referência não é descarregar")
        await #expect(throws: TranscriptionEngineFailure.modelUnavailable(.whisperSmall)) {
            try await engine.transcribe(.test(), candidate: .test())
        }
        try await engine.prepare(model: .whisperSmall)
        #expect(runtime.loadCalls == 2)
    }

    @Test("unload durante a carga: o modelo NÃO ressuscita depois")
    func unloadDuringLoadDoesNotResurrect() async throws {
        // O guard antigo era `loaded != nil || failedModel != nil`; durante a carga os dois são
        // nil, então `unload()` era no-op e a carga terminava publicando o modelo DEPOIS do
        // descarte — dois modelos pesados residentes.
        let loadGate = TestGate()
        let runtime = FakeWhisperKitRuntime(loadGate: loadGate)
        let engine = makeEngine(runtime: runtime)

        let preparing = Task { try await engine.prepare(model: .whisperSmall) }
        await loadGate.waitForArrivals(1)

        let unloading = Task { await engine.unload() }
        loadGate.open()
        await unloading.value
        _ = try? await preparing.value

        // A sessão chegou a ser criada, e foi liberada em vez de virar estado do motor.
        let session = try #require(runtime.sessions.first)
        #expect(session.releases == 1)
        await #expect(throws: TranscriptionEngineFailure.modelUnavailable(.whisperSmall)) {
            try await engine.transcribe(.test(), candidate: .test())
        }
    }

    @Test("unload durante o download cancela a carga e não deixa modelo carregado")
    func unloadDuringDownloadCancelsTheLoad() async throws {
        let downloadGate = TestGate()
        let runtime = FakeWhisperKitRuntime(downloadGate: downloadGate)
        let engine = makeEngine(runtime: runtime)

        let preparing = Task { try await engine.prepare(model: .whisperSmall) }
        await downloadGate.waitForArrivals(1)

        let unloading = Task { await engine.unload() }
        downloadGate.open()
        await unloading.value
        _ = try? await preparing.value

        #expect(runtime.loadCalls == 0, "a carga foi abortada antes de instanciar a sessão")
        await #expect(throws: TranscriptionEngineFailure.modelUnavailable(.whisperSmall)) {
            try await engine.transcribe(.test(), candidate: .test())
        }
    }

    @Test("unload durante a inferência aguarda ela terminar antes de soltar os pesos")
    func unloadDuringInferenceDrainsFirst() async throws {
        // `loaded = nil` não libera nada enquanto a inferência em voo segura a sessão: o
        // coordenador acharia que liberou memória e carregaria o pesado por cima.
        let sessionGate = TestGate()
        let runtime = FakeWhisperKitRuntime()
        runtime.useSessionGate(sessionGate)
        let engine = makeEngine(runtime: runtime)
        try await engine.prepare(model: .whisperSmall)
        let session = try #require(runtime.sessions.first)

        let transcribing = Task { try await engine.transcribe(.test(), candidate: .test()) }
        await sessionGate.waitForArrivals(1)

        let unloading = Task { await engine.unload() }
        await Task.yield()
        #expect(session.releases == 0, "não pode soltar os pesos com inferência em voo")

        sessionGate.open()
        let result = try await transcribing.value
        await unloading.value

        #expect(result.text == "[MÚSICA] olá  mundo")
        #expect(session.releases == 1)
        #expect(session.concurrentAtRelease == 0, "os pesos foram soltos com uma inferência ainda rodando")
    }

    @Test("unload é idempotente e não libera duas vezes")
    func unloadIsIdempotent() async throws {
        let runtime = FakeWhisperKitRuntime()
        let engine = makeEngine(runtime: runtime)
        try await engine.prepare(model: .whisperSmall)
        let session = try #require(runtime.sessions.first)

        await engine.unload()
        await engine.unload()
        #expect(session.releases == 1)
    }

    // MARK: - Cancelamento

    @Test("prepare cancelado devolve .cancelled e NÃO marca o modelo como falho")
    func cancelledPrepareDoesNotLatch() async throws {
        // Marcar o modelo condenaria a próxima tentativa do usuário a nascer falhando.
        let downloadGate = TestGate()
        let runtime = FakeWhisperKitRuntime(downloadGate: downloadGate)
        let engine = makeEngine(runtime: runtime)

        let preparing = Task { try await engine.prepare(model: .whisperSmall) }
        await downloadGate.waitForArrivals(1)
        preparing.cancel()
        downloadGate.open()

        await #expect(throws: TranscriptionEngineFailure.cancelled) {
            try await preparing.value
        }
        #expect(!TranscriptionEngineFailure.cancelled.allowsFallback)

        // Nada de latch: o modelo continua utilizável.
        try await engine.prepare(model: .whisperSmall)
        _ = try await engine.transcribe(.test(), candidate: .test())
    }

    @Test("transcribe cancelado antes de entrar na sessão devolve .cancelled sem fallback")
    func cancelledTranscribeNeverReachesTheSession() async throws {
        let sessionGate = TestGate()
        let runtime = FakeWhisperKitRuntime()
        runtime.useSessionGate(sessionGate)
        let engine = makeEngine(runtime: runtime)
        try await engine.prepare(model: .whisperSmall)
        let session = try #require(runtime.sessions.first)

        let first = Task { try await engine.transcribe(.test(), candidate: .test()) }
        await sessionGate.waitForArrivals(1)
        let queued = Task { try await engine.transcribe(.test(), candidate: .test()) }
        await Task.yield()
        queued.cancel()

        sessionGate.open()
        _ = try await first.value
        await #expect(throws: TranscriptionEngineFailure.cancelled) {
            try await queued.value
        }
        // O trabalho cancelado não gastou a Neural Engine.
        #expect(session.calls == 1)
    }

    @Test("Cancelamento DURANTE a inferência não vira sucesso, mesmo ela terminando normalmente")
    func cancellationDuringInferenceIsNotReportedAsSuccess() async throws {
        // `WhisperKit.transcribe` não é interrompível por dentro: ele termina normalmente depois
        // do `cancel()`. Sem a borda posterior, o motor devolveria texto para um lote que o
        // coordenador já descartou.
        let sessionGate = TestGate()
        let runtime = FakeWhisperKitRuntime()
        runtime.useSessionGate(sessionGate)
        let engine = makeEngine(runtime: runtime)
        try await engine.prepare(model: .whisperSmall)
        let session = try #require(runtime.sessions.first)

        let transcribing = Task { try await engine.transcribe(.test(), candidate: .test()) }
        await sessionGate.waitForArrivals(1)
        transcribing.cancel()
        sessionGate.open()

        await #expect(throws: TranscriptionEngineFailure.cancelled) {
            try await transcribing.value
        }
        // A inferência de fato rodou até o fim — o que mudou é o que o motor reporta.
        #expect(session.calls == 1)
    }

    @Test("Um trabalho cancelado sai da fila em vez de segurar o lugar dele")
    func cancelledWaiterLeavesTheQueue() async throws {
        // "Interativo antes de batch" depende disto: um lote descartado não pode atrasar quem
        // vem depois na vaga.
        let sessionGate = TestGate()
        let runtime = FakeWhisperKitRuntime()
        runtime.useSessionGate(sessionGate)
        let engine = makeEngine(runtime: runtime)
        try await engine.prepare(model: .whisperSmall)
        let session = try #require(runtime.sessions.first)

        let running = Task { try await engine.transcribe(.test(), candidate: .test()) }
        await sessionGate.waitForArrivals(1)
        let waiting = Task { try await engine.transcribe(.test(), candidate: .test()) }
        await Task.yield()
        waiting.cancel()

        // Sai da fila já cancelado, sem esperar a vaga.
        await #expect(throws: TranscriptionEngineFailure.cancelled) {
            try await waiting.value
        }
        #expect(session.calls == 1, "o cancelado não pode ter entrado na sessão")

        sessionGate.open()
        _ = try await running.value
        // A vaga continua sadia depois de um abandono: o próximo é servido normalmente.
        _ = try await engine.transcribe(.test(), candidate: .test())
        #expect(session.calls == 2)
    }

    @Test("Servido e cancelado no MESMO turno do ator: a vaga volta")
    func slotHandoffToACancelledWaiterDoesNotLeak() async throws {
        // A regressão determinística do CRITICO da rodada 3.
        //
        // O interleaving que vaza é: o `releaseSlot()` serve o waiter — que passa a ser dono da
        // vaga — e só DEPOIS a desistência dele é observada; o hop do `onCancel` chega tarde e
        // não encontra mais ninguém na fila para marcar. De fora não dá para forçar por corrida:
        // o hop é um único job do ator e sempre vence o retorno do detentor, que precisa de dois
        // saltos para voltar ao ator.
        //
        // O que torna isto determinístico é o observador, que o motor chama **sincronamente,
        // dentro do ator**: no `unload`, o `.unloaded` é emitido e, no MESMO turno, o `defer`
        // devolve a vaga. Cancelar o waiter de dentro do observador põe o cancelamento e o
        // handoff no mesmo turno, antes de qualquer hop.
        let sessionGate = TestGate()
        let waiter = TaskBox()
        let runtime = FakeWhisperKitRuntime()
        // Antes do primeiro `prepare`: o portão só vale para as sessões criadas depois dele.
        runtime.useSessionGate(sessionGate)
        let engine = WhisperKitTranscriptionEngine(runtime: runtime) { event in
            if case .unloaded = event.stage { waiter.cancel() }
        }

        try await engine.prepare(model: .whisperSmall)

        // Detentor da vaga: uma inferência presa no portão.
        let holder = Task { _ = try await engine.transcribe(.test(), candidate: .test()) }
        await sessionGate.waitForArrivals(1)

        // Atrás dele, o `unload`.
        let unloading = Task { await engine.unload() }
        await Task.yield()
        await Task.yield()

        // E atrás do `unload`, o waiter — que ainda passa pelo guard de residência, porque o
        // `unload` só zera `loaded` quando conquistar a vaga.
        let queued = Task { _ = try await engine.transcribe(.test(), candidate: .test()) }
        waiter.hold(queued)
        await Task.yield()
        await Task.yield()

        // Solta tudo: detentor → `unload` (que emite `.unloaded`, o observador cancela o
        // waiter, e o `defer` do mesmo turno passa a vaga para ele) → waiter.
        sessionGate.open()
        _ = try await holder.value
        await unloading.value
        // O trabalho servido-e-já-cancelado sai como `.cancelled`, e NÃO como
        // `modelUnavailable`: quem zerou `loaded` foi o próprio `unload` que acabou de lhe
        // passar a vaga, então conferir a residência antes do cancelamento faria um lote
        // cancelado virar "modelo indisponível" — que PERMITE fallback, e o coordenador
        // transcreveria em outro motor algo que ninguém queria mais.
        await #expect(throws: TranscriptionEngineFailure.cancelled) {
            try await queued.value
        }
        #expect(!TranscriptionEngineFailure.cancelled.allowsFallback)

        // Se a vaga vazou, nada aqui volta.
        let recovered = try await withDeadline(seconds: 30) {
            try await engine.prepare(model: .whisperSmall)
        }
        #expect(recovered != nil, "a vaga vazou no handoff para um waiter cancelado")

        let served = try await withDeadline(seconds: 30) {
            try await engine.transcribe(.test(), candidate: .test())
        }
        #expect(served != nil, "a vaga vazou: o motor parou de servir")
    }

    @Test("Cancelamento vindo da sessão é preservado como .cancelled")
    func cancellationFromTheSessionIsPreserved() async throws {
        let runtime = FakeWhisperKitRuntime()
        let engine = makeEngine(runtime: runtime)
        try await engine.prepare(model: .whisperSmall)
        try #require(runtime.sessions.first).setError(CancellationError())

        await #expect(throws: TranscriptionEngineFailure.cancelled) {
            try await engine.transcribe(.test(), candidate: .test())
        }
    }

    // MARK: - Erros de inferência

    @Test("Rede caída DURANTE a inferência não vira modelUnavailable")
    func networkErrorDuringInferenceIsNotModelUnavailable() async throws {
        // Os pesos estão carregados: chamar de "modelo indisponível" gravaria proveniência e
        // telemetria erradas.
        let runtime = FakeWhisperKitRuntime()
        let engine = makeEngine(runtime: runtime)
        try await engine.prepare(model: .whisperSmall)
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        try #require(runtime.sessions.first).setError(offline)

        do {
            _ = try await engine.transcribe(.test(), candidate: .test())
            Issue.record("esperava falha")
        } catch let failure as TranscriptionEngineFailure {
            guard case .engineInternal = failure else {
                Issue.record("esperava engineInternal, veio \(failure)")
                return
            }
        }
    }

    // MARK: - Validação simétrica ao Parakeet

    @Test("A prévia da reunião não é atendida pelo caminho em lote")
    func meetingPreviewIsRefused() async throws {
        let runtime = FakeWhisperKitRuntime()
        let engine = makeEngine(runtime: runtime)
        try await engine.prepare(model: .whisperSmall)

        do {
            _ = try await engine.transcribe(.test(useCase: .meetingPreview), candidate: .test())
            Issue.record("esperava recusa do caso de uso")
        } catch let failure as TranscriptionEngineFailure {
            guard case .engineInternal = failure else {
                Issue.record("esperava engineInternal, veio \(failure)")
                return
            }
        }
        #expect(try #require(runtime.sessions.first).calls == 0)
    }

    @Test("Idioma fora do descritor é languageUnsupported")
    func unsupportedLanguageIsRefused() async throws {
        let runtime = FakeWhisperKitRuntime()
        let engine = makeEngine(runtime: runtime)
        try await engine.prepare(model: .whisperSmall)

        // Italiano, e não francês: o francês entrou no seletor em 29/08/2026. O teste precisa de
        // um idioma que o modelo sabe falar e o **app** não oferece — é essa a fronteira aqui.
        await #expect(throws: TranscriptionEngineFailure.languageUnsupported(TranscriptionLanguage("it"))) {
            try await engine.transcribe(.test(language: TranscriptionLanguage("it")), candidate: .test())
        }
    }

    @Test("Áudio inválido é recusado antes de qualquer inferência")
    func invalidAudioIsRefused() async throws {
        let runtime = FakeWhisperKitRuntime()
        let engine = makeEngine(runtime: runtime)
        try await engine.prepare(model: .whisperSmall)

        await #expect(throws: TranscriptionEngineFailure.invalidAudio("áudio vazio")) {
            try await engine.transcribe(.test(sampleCount: 0), candidate: .test())
        }
        #expect(try #require(runtime.sessions.first).calls == 0)
    }

    @Test("A validação roda mesmo sem modelo preparado — recusa antes de modelUnavailable")
    func validationPrecedesResidencyCheck() async {
        let runtime = FakeWhisperKitRuntime()
        let engine = makeEngine(runtime: runtime)

        await #expect(throws: TranscriptionEngineFailure.invalidAudio("áudio vazio")) {
            try await engine.transcribe(.test(sampleCount: 0), candidate: .test())
        }
    }

    // MARK: - Resultado e proveniência

    @Test("O resultado leva texto sanitizado, segmentos, idioma e proveniência do candidato")
    func resultCarriesEverything() async throws {
        let runtime = FakeWhisperKitRuntime()
        let engine = makeEngine(runtime: runtime)
        try await engine.prepare(model: .whisperSmall)

        let candidate = TranscriptionRoutingCandidate.test(rank: 2, origin: .automatic)
        let result = try await engine.transcribe(
            .test(useCase: .meetingFinal, language: .portugueseBrazil),
            candidate: candidate
        )

        #expect(result.text == "olá mundo")
        #expect(result.segments == [
            TranscriptionTextSegment(text: "olá mundo", start: 0, end: 1.5, confidence: -0.25)
        ])
        #expect(result.detectedLanguage == .portuguese)
        #expect(result.provenance.engine == .whisperKit)
        #expect(result.provenance.model == .whisperSmall)
        #expect(result.provenance.useCase == .meetingFinal)
        #expect(result.provenance.candidateRank == 2)
        #expect(result.provenance.origin == .automatic)
        #expect(result.provenance.isFallback)
        #expect(result.processingTime >= 0)

        // pt-BR chega ao Whisper como `pt`; a detecção automática vai como nil.
        #expect(try #require(runtime.sessions.first).languageCodes == ["pt"])
    }

    @Test("Detecção automática manda nil e reporta o idioma que a sessão devolveu")
    func automaticLanguagePassesNil() async throws {
        let runtime = FakeWhisperKitRuntime()
        let engine = makeEngine(runtime: runtime)
        try await engine.prepare(model: .whisperSmall)

        let result = try await engine.transcribe(.test(language: nil), candidate: .test())
        #expect(try #require(runtime.sessions.first).languageCodes == [nil])
        #expect(result.detectedLanguage == .portuguese)
    }

    // MARK: - Eventos de carga

    @Test("A carga emite downloading → loading → ready na mesma geração")
    func loadEventsFollowTheStages() async throws {
        let runtime = FakeWhisperKitRuntime()
        let recorder = LoadEventRecorder()
        let engine = makeEngine(runtime: runtime, recorder: recorder)

        try await engine.prepare(model: .whisperSmall)

        let stages = recorder.stages
        #expect(stages.first == .downloading(model: .whisperSmall, fraction: 0))
        #expect(stages.contains(.loading(model: .whisperSmall)))
        #expect(stages.last == .ready(model: .whisperSmall))
        #expect(Set(recorder.events.map(\.generation)).count == 1)
    }

    @Test("Modelo já no disco pula direto para loading, sem gauge de download")
    func alreadyDownloadedSkipsTheGauge() async throws {
        let runtime = FakeWhisperKitRuntime(downloadedVariants: ["openai_whisper-small"])
        let recorder = LoadEventRecorder()
        let engine = makeEngine(runtime: runtime, recorder: recorder)

        try await engine.prepare(model: .whisperSmall)
        #expect(recorder.stages.first == .loading(model: .whisperSmall))
    }

    @Test("Eventos de uma carga descartada têm geração menor que a da carga viva")
    func staleEventsCarryAnOlderGeneration() async throws {
        // É isto que deixa o store da T2.3 descartar um `.downloading(0.97)` atrasado que
        // chegaria depois do `.ready` e prenderia a UI em "baixando".
        let downloadGate = TestGate()
        let runtime = FakeWhisperKitRuntime(downloadGate: downloadGate)
        let recorder = LoadEventRecorder()
        let engine = makeEngine(runtime: runtime, recorder: recorder)

        let preparing = Task { try await engine.prepare(model: .whisperSmall) }
        await downloadGate.waitForArrivals(1)
        let switching = Task { try await engine.prepare(model: .whisperBase) }
        downloadGate.open()
        _ = try? await preparing.value
        try await switching.value

        let smallGenerations = recorder.generations {
            if case .downloading(let model, _) = $0 { return model == .whisperSmall }
            if case .loading(let model) = $0 { return model == .whisperSmall }
            return false
        }
        let readyGeneration = try #require(recorder.generations {
            $0 == .ready(model: .whisperBase)
        }.last)

        #expect(!smallGenerations.isEmpty)
        #expect(smallGenerations.allSatisfy { $0 < readyGeneration })
    }

    @Test("unload emite .unloaded com a geração nova")
    func unloadEmitsUnloaded() async throws {
        let runtime = FakeWhisperKitRuntime()
        let recorder = LoadEventRecorder()
        let engine = makeEngine(runtime: runtime, recorder: recorder)

        try await engine.prepare(model: .whisperSmall)
        let readyGeneration = try #require(recorder.events.last?.generation)
        await engine.unload()

        let last = try #require(recorder.events.last)
        #expect(last.stage == .unloaded)
        #expect(last.generation > readyGeneration)
    }

    @Test("unload × prepare: quem executa por último vence, e a geração segue a mutação")
    func unloadRacingPrepareNeverLies() async throws {
        // Semântica fechada em DECISOES (reescrita do item 14): a geração nasce com a vaga na
        // mão, então ela ordena as MUTAÇÕES. O `unload` nunca desiste por ter sido superado.
        // A invariante afirmada aqui não fixa um interleaving: ela diz que o evento de maior
        // geração descreve o estado real, qualquer que tenha sido a ordem.
        for round in 0..<25 {
            let runtime = FakeWhisperKitRuntime()
            let recorder = LoadEventRecorder()
            let engine = makeEngine(runtime: runtime, recorder: recorder)
            try await engine.prepare(model: .whisperSmall)

            async let unloading: Void = engine.unload()
            async let preparing: Void = engine.prepare(model: .whisperBase)
            await unloading
            _ = try? await preparing

            let last = try #require(recorder.events.last, "rodada \(round)")
            #expect(recorder.events.map(\.generation) == recorder.events.map(\.generation).sorted(),
                    "gerações fora de ordem na rodada \(round)")

            // O estado real tem que bater com o último evento — se ele diz `.ready(base)`, o
            // motor transcreve com base; se diz `.unloaded`, ele recusa.
            switch last.stage {
            case .ready(let model):
                #expect(model == .whisperBase)
                _ = try await engine.transcribe(.test(), candidate: .test(model: .whisperBase))
            case .unloaded:
                await #expect(throws: TranscriptionEngineFailure.modelUnavailable(.whisperBase)) {
                    try await engine.transcribe(.test(), candidate: .test(model: .whisperBase))
                }
                await #expect(throws: TranscriptionEngineFailure.modelUnavailable(.whisperSmall)) {
                    try await engine.transcribe(.test(), candidate: .test(model: .whisperSmall))
                }
            default:
                Issue.record("último evento inesperado na rodada \(round): \(last.stage)")
            }
        }
    }

    @Test("Quando await unload() devolve, os pesos que estavam residentes foram liberados")
    func unloadAlwaysReleasesWhatWasResident() async throws {
        // A garantia que o coordenador da T2.3 pode usar. O `unload` não é mais no-op silencioso
        // quando um `prepare` se intercala: ele descarrega o que estava residente naquele
        // instante, e um `prepare` posterior é que recarrega.
        let sessionGate = TestGate()
        let runtime = FakeWhisperKitRuntime()
        runtime.useSessionGate(sessionGate)
        let engine = makeEngine(runtime: runtime)
        try await engine.prepare(model: .whisperSmall)
        let resident = try #require(runtime.sessions.first)

        // Prende a vaga com uma inferência para o `unload` suspender de forma determinística, e
        // deixa um `prepare` entrar atrás dele.
        let transcribing = Task { try await engine.transcribe(.test(), candidate: .test()) }
        await sessionGate.waitForArrivals(1)
        let unloading = Task { await engine.unload() }
        await Task.yield()
        let preparing = Task { try await engine.prepare(model: .whisperBase) }
        await Task.yield()

        sessionGate.open()
        _ = try await transcribing.value
        await unloading.value

        // O que estava residente quando o unload rodou saiu da memória — mesmo com um prepare
        // enfileirado atrás dele.
        #expect(resident.releases == 1)
        #expect(resident.concurrentAtRelease == 0)
        _ = try? await preparing.value
    }

    @Test("Falha de carga emite .failed com a falha classificada")
    func failedLoadEmitsFailure() async {
        let runtime = FakeWhisperKitRuntime()
        runtime.failDownload(onAttempt: 1, with: FakeRuntimeError.corruptedModel)
        runtime.failDownload(onAttempt: 2, with: FakeRuntimeError.corruptedModel)
        let recorder = LoadEventRecorder()
        let engine = makeEngine(runtime: runtime, recorder: recorder)

        _ = try? await engine.prepare(model: .whisperSmall)

        #expect(recorder.stages.last == .failed(model: .whisperSmall, failure: .modelUnavailable(.whisperSmall)))
    }
}
