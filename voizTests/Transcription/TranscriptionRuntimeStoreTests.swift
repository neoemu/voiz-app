import Testing
import Foundation

/// Testes do `TranscriptionRuntimeStore`.
///
/// O store existe para uma coisa só: transformar eventos que chegam **fora de ordem** — porque
/// hopam para a main actor a partir de dois atores e de uma thread de download — num estado que
/// nunca mente. Todos os testes daqui injetam a desordem de propósito; um teste que só entregasse
/// eventos em ordem passaria com um store que não tem regra nenhuma.
@Suite("Store de runtime — ordenação dos eventos de carga")
@MainActor
struct TranscriptionRuntimeStoreTests {

    // MARK: - Geração

    @Test("Evento de geração menor é descartado, não sobrescreve o vivo")
    func staleGenerationIsDiscarded() {
        let store = TranscriptionRuntimeStore()

        store.apply(WhisperKitLoadEvent(generation: 2, stage: .ready(model: .whisperSmall)))
        // O `.loading` da carga 1, que morreu, chega atrasado.
        store.apply(WhisperKitLoadEvent(generation: 1, stage: .loading(model: .whisperBase)))

        #expect(store.stage(of: .whisperKit) == .ready(model: .whisperSmall))
        #expect(store.state(of: .whisperKit).generation == 2)
        #expect(store.discardedEvents[.whisperKit] == 1)
    }

    @Test("Dentro da MESMA geração, .downloading atrasado não regride o .ready")
    func lateDownloadingDoesNotRegressReady() {
        // Este é o MENOR que a Quilha registrou como item da T2.3: o `.downloading` do Whisper sai
        // do callback do HubApi, FORA do ator, enquanto `.ready` sai de dentro dele. Com a mesma
        // geração, "descarte geração menor" não protege — a UI voltava para "baixando" com o
        // modelo pronto e ficava lá.
        let store = TranscriptionRuntimeStore()

        store.apply(WhisperKitLoadEvent(generation: 3, stage: .downloading(model: .whisperSmall, fraction: 0.4)))
        store.apply(WhisperKitLoadEvent(generation: 3, stage: .loading(model: .whisperSmall)))
        store.apply(WhisperKitLoadEvent(generation: 3, stage: .ready(model: .whisperSmall)))
        store.apply(WhisperKitLoadEvent(generation: 3, stage: .downloading(model: .whisperSmall, fraction: 0.99)))

        #expect(store.stage(of: .whisperKit) == .ready(model: .whisperSmall))
        #expect(store.state(of: .whisperKit).generation == 3)
        #expect(store.discardedEvents[.whisperKit] == 1)
    }

    @Test("Dentro da mesma geração, .downloading atrasado também não regride o .failed")
    func lateDownloadingDoesNotRegressFailure() {
        let store = TranscriptionRuntimeStore()
        let failure = TranscriptionEngineFailure.modelUnavailable(.whisperMedium)

        store.apply(WhisperKitLoadEvent(generation: 1, stage: .failed(model: .whisperMedium, failure: failure)))
        store.apply(WhisperKitLoadEvent(generation: 1, stage: .downloading(model: .whisperMedium, fraction: 0.8)))
        store.apply(WhisperKitLoadEvent(generation: 1, stage: .loading(model: .whisperMedium)))

        #expect(store.stage(of: .whisperKit) == .failed(model: .whisperMedium, failure: failure))
        #expect(store.discardedEvents[.whisperKit] == 2)
    }

    @Test("A barra de progresso não anda para trás dentro da mesma geração")
    func downloadFractionNeverGoesBackwards() {
        let store = TranscriptionRuntimeStore()

        store.apply(WhisperKitLoadEvent(generation: 1, stage: .downloading(model: .whisperSmall, fraction: 0.7)))
        store.apply(WhisperKitLoadEvent(generation: 1, stage: .downloading(model: .whisperSmall, fraction: 0.3)))

        #expect(store.stage(of: .whisperKit) == .downloading(model: .whisperSmall, fraction: 0.7))

        store.apply(WhisperKitLoadEvent(generation: 1, stage: .downloading(model: .whisperSmall, fraction: 0.9)))
        #expect(store.stage(of: .whisperKit) == .downloading(model: .whisperSmall, fraction: 0.9))
    }

    @Test("Geração nova sempre vence, inclusive voltando de .ready para .loading")
    func newerGenerationAlwaysWins() {
        // Trocar de modelo é geração nova: sair de "pronto" para "carregando" é a verdade, não
        // regressão. A regra de não-regressão vale DENTRO de uma geração, e só.
        let store = TranscriptionRuntimeStore()

        store.apply(WhisperKitLoadEvent(generation: 1, stage: .ready(model: .whisperSmall)))
        store.apply(WhisperKitLoadEvent(generation: 2, stage: .loading(model: .whisperMedium)))

        #expect(store.stage(of: .whisperKit) == .loading(model: .whisperMedium))
        #expect(store.discardedEvents[.whisperKit] == nil)
    }

    @Test("unload vira .idle e nunca é engolido por um .ready anterior")
    func unloadClearsTheStage() {
        let store = TranscriptionRuntimeStore()

        store.apply(WhisperKitLoadEvent(generation: 4, stage: .ready(model: .whisperSmall)))
        store.apply(WhisperKitLoadEvent(generation: 5, stage: .unloaded))

        #expect(store.stage(of: .whisperKit) == .idle)
        #expect(store.stage(of: .whisperKit).model == nil)
        #expect(store.isAnyEngineWorking == false)
    }

    // MARK: - Geração POR MOTOR

    @Test("A geração é chaveada por motor: a do Whisper não cala a do Parakeet")
    func generationsAreKeyedPerEngine() {
        // Cada motor tem o contador dele. Comparar a geração do Whisper com a do Parakeet não
        // significa nada — e um store com um contador global descartaria os eventos do motor que
        // começou depois.
        let store = TranscriptionRuntimeStore()

        store.apply(WhisperKitLoadEvent(generation: 9, stage: .ready(model: .whisperSmall)))
        store.apply(ParakeetTranscriptionEngine.LoadEvent.loading(model: .parakeetTDT06BV3, generation: 1))

        #expect(store.stage(of: .whisperKit) == .ready(model: .whisperSmall))
        #expect(store.stage(of: .parakeet) == .loading(model: .parakeetTDT06BV3))
        #expect(store.discardedEvents.isEmpty)
        #expect(store.isAnyEngineWorking)
    }

    // MARK: - Os dois tipos de evento

    @Test("Os quatro eventos do Parakeet viram os estágios certos")
    func parakeetEventsAreTranslated() {
        let store = TranscriptionRuntimeStore()
        let failure = TranscriptionEngineFailure.engineInternal("ANE ocupada")

        store.apply(ParakeetTranscriptionEngine.LoadEvent.loading(model: .parakeetTDT06BV3, generation: 1))
        #expect(store.stage(of: .parakeet) == .loading(model: .parakeetTDT06BV3))

        store.apply(ParakeetTranscriptionEngine.LoadEvent.ready(model: .parakeetTDT06BV3, generation: 2))
        #expect(store.stage(of: .parakeet) == .ready(model: .parakeetTDT06BV3))

        store.apply(
            ParakeetTranscriptionEngine.LoadEvent.failed(
                model: .parakeetTDT06BV3,
                failure: failure,
                generation: 3
            )
        )
        #expect(store.stage(of: .parakeet) == .failed(model: .parakeetTDT06BV3, failure: failure))

        store.apply(ParakeetTranscriptionEngine.LoadEvent.unloaded(generation: 4))
        #expect(store.stage(of: .parakeet) == .idle)
    }

    @Test("Os cinco estágios do Whisper viram os estágios certos")
    func whisperEventsAreTranslated() {
        let store = TranscriptionRuntimeStore()
        let failure = TranscriptionEngineFailure.modelUnavailable(.whisperLargeV3Turbo)

        store.apply(WhisperKitLoadEvent(generation: 1, stage: .downloading(model: .whisperSmall, fraction: 0.25)))
        #expect(store.stage(of: .whisperKit) == .downloading(model: .whisperSmall, fraction: 0.25))
        #expect(store.stage(of: .whisperKit).isWorking)

        store.apply(WhisperKitLoadEvent(generation: 2, stage: .loading(model: .whisperSmall)))
        #expect(store.stage(of: .whisperKit) == .loading(model: .whisperSmall))

        store.apply(WhisperKitLoadEvent(generation: 3, stage: .ready(model: .whisperSmall)))
        #expect(store.stage(of: .whisperKit) == .ready(model: .whisperSmall))
        #expect(store.stage(of: .whisperKit).isWorking == false)

        store.apply(
            WhisperKitLoadEvent(generation: 4, stage: .failed(model: .whisperLargeV3Turbo, failure: failure))
        )
        #expect(store.stage(of: .whisperKit) == .failed(model: .whisperLargeV3Turbo, failure: failure))

        store.apply(WhisperKitLoadEvent(generation: 5, stage: .unloaded))
        #expect(store.stage(of: .whisperKit) == .idle)
    }

    @Test("Motor sem evento nenhum começa em .idle, geração 0")
    func unknownEngineStartsIdle() {
        let store = TranscriptionRuntimeStore()

        #expect(store.state(of: .parakeet) == .initial)
        #expect(store.stage(of: .parakeet) == .idle)
        #expect(store.isAnyEngineWorking == false)
    }

    // MARK: - Os observadores que os motores recebem

    @Test("O observador nonisolated hopa para a main actor e aplica o evento")
    func observerHopsToTheMainActor() async {
        // O motor chama o observador de DENTRO do ator dele e, no progresso do download, de uma
        // thread da biblioteca. Um `assumeIsolated` aqui seria crash garantido.
        let store = TranscriptionRuntimeStore()
        let whisper = store.whisperObserver()
        let parakeet = store.parakeetObserver()

        await Task.detached {
            whisper(WhisperKitLoadEvent(generation: 1, stage: .ready(model: .whisperSmall)))
            parakeet(.ready(model: .parakeetTDT06BV3, generation: 1))
        }.value

        #expect(await waitUntil { await MainActor.run { store.stage(of: .whisperKit) == .ready(model: .whisperSmall) } })
        #expect(await waitUntil { await MainActor.run { store.stage(of: .parakeet) == .ready(model: .parakeetTDT06BV3) } })
    }

    // MARK: - A regra, direto

    @Test("reduce devolve nil exatamente quando o evento deve ser descartado")
    func reduceIsTheWholeRule() {
        let ready = TranscriptionRuntimeState(stage: .ready(model: .whisperSmall), generation: 5)

        // Geração menor: descarta.
        #expect(
            TranscriptionRuntimeStore.reduce(ready, generation: 4, stage: .loading(model: .whisperSmall)) == nil
        )
        // Mesma geração, estágio anterior: descarta.
        #expect(
            TranscriptionRuntimeStore.reduce(
                ready,
                generation: 5,
                stage: .downloading(model: .whisperSmall, fraction: 1)
            ) == nil
        )
        // Mesma geração, estágio igual ou posterior: aceita.
        #expect(
            TranscriptionRuntimeStore.reduce(ready, generation: 5, stage: .idle)
                == TranscriptionRuntimeState(stage: .idle, generation: 5)
        )
        // Geração maior: aceita sempre.
        #expect(
            TranscriptionRuntimeStore.reduce(
                ready,
                generation: 6,
                stage: .downloading(model: .whisperMedium, fraction: 0)
            ) == TranscriptionRuntimeState(stage: .downloading(model: .whisperMedium, fraction: 0), generation: 6)
        )
    }
}
