#if DEBUG
import Foundation

// Sonda histórica de cadência (antes da segmentação por fala) da tradução ao vivo (diagnóstico da reprovação do CHECKLIST-ONDA2).
//
// Existe para responder uma pergunta que só o app real responde: **quanto custa um trecho de 1,2 s
// pelo coordenador, e quanto custava pelo serviço legado**. O laço da tradução dorme 1,2 s, e
// quando um trecho passa a custar mais que isso o `guard !isProcessingChunk` pula ciclos — o
// `lastProcessedIndex` não anda, e o trecho seguinte carrega todo o áudio acumulado. É o efeito
// bola de neve que o humano viu como "blocos grandes".
//
// Só DEBUG, e só por argumento de linha de comando: nada disto entra no caminho do usuário.
//
//   --voiz-translation-probe                 liga a sonda
//   --voiz-translation-probe-audio <caminho> áudio de fala (qualquer formato que o AVFoundation abra)
//   --voiz-translation-probe-legacy          mede também o caminho legado (carrega um 2º WhisperKit)
//   --voiz-translation-probe-live            replica o laço de 1,2 s em tempo real (mostra a bola de neve)
//   --voiz-translation-probe-mic <s>         grava pelo TranslationViewModel real, com o microfone real
//   --voiz-translation-probe-rounds <n>      quantas gravações seguidas no modo microfone
//   --voiz-translation-probe-threshold <n>   limiar do replay, em amostras (A/B do fio de navalha)
//   --voiz-translation-probe-exit            encerra o app ao terminar
//
// Sem transcript no stdout, como manda a regra 7: a sonda imprime tamanhos e tempos, nunca texto.

nonisolated struct TranslationCadenceProbeOptions: Sendable, Equatable {
    /// `nil` no modo microfone, que não lê arquivo nenhum.
    var audioPath: String?
    var measuresLegacy: Bool
    var replaysLoop: Bool
    /// Segundos de gravação pelo `TranslationViewModel` de verdade, com o microfone de verdade.
    var micSeconds: Double?
    /// Quantas gravações seguidas — o salvamento da segunda é o que o checklist reprovou.
    var micRounds: Int
    /// Em vez de parar num instante qualquer, espera o próximo trecho aparecer e para
    /// `stopPhase` segundos depois dele — deixando ~1,1 s de áudio pendente, que é a janela em que
    /// a volta extra do laço (o `try?` que engolia o cancelamento) fazia trabalho duplicado.
    var stopPhase: Double?
    /// Só observa o histórico por N segundos e imprime quando ele muda — sem gravar nada. É como
    /// se verifica se a recarga por `UserDefaults.didChangeNotification` realmente atravessa
    /// processos: `entries` só muda por gravação local ou por essa notificação.
    var watchSeconds: Double?
    /// Quantas amostras novas um ciclo do replay exige. Existe para o A/B do limiar do laço:
    /// 19200 é o valor de 1,2 s exatos (o fio de navalha) e 17280 é o limiar com folga.
    var loopThreshold: Int
    var shouldExit: Bool

    /// `nil` quando a sonda não foi pedida.
    static func parse(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> TranslationCadenceProbeOptions? {
        guard arguments.contains("--voiz-translation-probe") else { return nil }
        return TranslationCadenceProbeOptions(
            audioPath: value(of: "--voiz-translation-probe-audio", in: arguments),
            measuresLegacy: arguments.contains("--voiz-translation-probe-legacy"),
            replaysLoop: arguments.contains("--voiz-translation-probe-live"),
            micSeconds: value(of: "--voiz-translation-probe-mic", in: arguments).flatMap(Double.init),
            micRounds: value(of: "--voiz-translation-probe-rounds", in: arguments).flatMap(Int.init) ?? 1,
            stopPhase: value(of: "--voiz-translation-probe-stop-phase", in: arguments).flatMap(Double.init),
            watchSeconds: value(of: "--voiz-translation-probe-watch", in: arguments).flatMap(Double.init),
            loopThreshold: value(of: "--voiz-translation-probe-threshold", in: arguments).flatMap(Int.init) ?? 19_200,
            shouldExit: arguments.contains("--voiz-translation-probe-exit")
        )
    }

    private static func value(of flag: String, in arguments: [String]) -> String? {
        guard
            let index = arguments.firstIndex(of: flag),
            arguments.index(after: index) < arguments.endIndex
        else {
            return nil
        }
        return arguments[arguments.index(after: index)]
    }
}

/// Uma medição de um trecho: quanto o chamador esperou e quanto disso foi inferência de verdade.
nonisolated struct TranslationCadenceSample: Sendable {
    var index: Int
    var audioSeconds: Double
    var wallSeconds: Double
    /// Só o `WhisperKit.transcribe`, cronometrado dentro do motor. `nil` no caminho legado, que não
    /// devolve essa separação.
    var inferenceSeconds: Double?
    var characters: Int

    var overheadSeconds: Double? {
        inferenceSeconds.map { wallSeconds - $0 }
    }
}

@MainActor
enum TranslationCadenceProbe {

    /// O mesmo laço da tradução: dorme 1,2 s e exige 1,2 s de áudio novo.
    private static let cycleSeconds: Double = 1.2

    static func runIfRequested() {
        guard let options = TranslationCadenceProbeOptions.parse() else { return }
        Task { await run(options) }
    }

    static func run(_ options: TranslationCadenceProbeOptions) async {
        if let seconds = options.watchSeconds {
            await watchHistory(seconds: seconds)
            print("🧪 [sonda-cadência] fim")
            finish(options)
            return
        }
        if let seconds = options.micSeconds {
            await runMicrophoneRounds(
                seconds: seconds,
                rounds: options.micRounds,
                stopPhase: options.stopPhase
            )
            print("🧪 [sonda-cadência] fim")
            finish(options)
            return
        }

        guard let audioPath = options.audioPath else {
            print("🧪 [sonda-cadência] faltou --voiz-translation-probe-audio ou --voiz-translation-probe-mic")
            finish(options)
            return
        }
        print("🧪 [sonda-cadência] início — áudio: \(URL(fileURLWithPath: audioPath).lastPathComponent)")

        let audio: TranscriptionAudio
        do {
            audio = try BenchmarkAudioLoader.load(url: URL(fileURLWithPath: audioPath))
        } catch {
            print("🧪 [sonda-cadência] falha ao abrir o áudio: \(error.localizedDescription)")
            finish(options)
            return
        }

        let chunkSamples = Int(cycleSeconds * TranscriptionAudio.defaultSampleRate)
        let chunks = stride(from: 0, to: audio.samples.count - chunkSamples, by: chunkSamples).map {
            Array(audio.samples[$0..<($0 + chunkSamples)])
        }
        guard !chunks.isEmpty else {
            print("🧪 [sonda-cadência] áudio curto demais para um trecho de 1,2 s")
            finish(options)
            return
        }

        let settings = SettingsStore().load()
        let selection = settings.transcriptionSelection(for: .translationChunk, strict: true)
        let preferred = selection.preferred
        print(
            "🧪 [sonda-cadência] seleção: motor \(preferred?.engine.rawValue ?? "auto")"
                + " modelo \(preferred?.model?.rawValue ?? "padrão")"
                + " strict \(selection.strictEngineSelection)"
        )
        print("🧪 [sonda-cadência] \(chunks.count) trechos de \(String(format: "%.1f", cycleSeconds))s")

        let coordinator = AppTranscriptionCoordinator.shared.coordinator

        // Aquecimento fora da medição — o que interessa é o regime, não a primeira carga.
        let warmUpStart = Date()
        await coordinator.warmUp(for: .translationChunk, language: .english, selection: selection)
        print("🧪 [sonda-cadência] aquecimento do coordenador: \(seconds(since: warmUpStart))")

        let coordinatorSamples = await measureCoordinator(chunks, selection: selection, coordinator: coordinator)
        report("COORDENADOR (.translationChunk, strict, silentInteractive)", coordinatorSamples)

        if options.measuresLegacy {
            // Um WhisperKit por vez: medir os dois residentes ao mesmo tempo mediria a disputa
            // pela ANE, não o custo de cada caminho.
            await coordinator.unloadAll()
            let legacySamples = await measureLegacy(chunks)
            report("LEGADO (TranscriptionService.shared)", legacySamples)
            TranscriptionService.shared.release()
        }

        if options.replaysLoop {
            await replayLoop(
                audio: audio,
                selection: selection,
                coordinator: coordinator,
                threshold: options.loopThreshold
            )
        }

        print("🧪 [sonda-cadência] fim")
        finish(options)
    }

    /// Observa o histórico sem tocar nele. `entries` só muda por gravação local (não há nenhuma
    /// aqui) ou pela recarga vinda da notificação — então qualquer mudança impressa veio de outro
    /// processo.
    private static func watchHistory(seconds: Double) async {
        let store = TranslationHistoryStore()
        var last = store.entries.count
        var lastRaw = (UserDefaults.standard.data(forKey: "translationHistory"))
            .flatMap { try? JSONDecoder().decode([TranslationEntry].self, from: $0) }?.count ?? -1
        print("🧪 [sonda-cadência] observando o histórico por \(seconds)s — começa em \(last) entradas")

        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
            let now = store.entries.count
            let raw = (UserDefaults.standard.data(forKey: "translationHistory"))
                .flatMap { try? JSONDecoder().decode([TranslationEntry].self, from: $0) }?.count ?? -1
            if now != last || raw != lastRaw {
                print(
                    "🧪 [sonda-cadência] mudou sem esta instância gravar — store: \(last) -> \(now)"
                        + " | leitura crua do UserDefaults: \(lastRaw) -> \(raw)"
                )
                last = now
                lastRaw = raw
            }
        }
        print("🧪 [sonda-cadência] fim da observação em \(last) entradas")
    }

    // MARK: - O caminho de verdade (view model + microfone)

    /// Grava pelo `TranslationViewModel` REAL, com o microfone REAL, e conta o que entrou no
    /// histórico. É o que o checklist humano fez com o mouse — a sonda só substitui os cliques,
    /// para o log de cadência sair no stdout e o antes/depois do histórico ser verificável.
    private static func runMicrophoneRounds(
        seconds: Double,
        rounds: Int,
        stopPhase: Double? = nil
    ) async {
        print("🧪 [sonda-cadência] modo microfone: \(rounds) rodada(s) de \(seconds)s")
        // Headless mode has no TranscriptionViewModel to bootstrap the credential cache.
        let settingsStore = SettingsStore()
        guard await settingsStore.loadCredentialsForWork() else {
            print("🧪 [sonda-cadência] credenciais indisponíveis; rodada não iniciada")
            return
        }
        let viewModel = TranslationViewModel(settingsStore: settingsStore)
        // O aquecimento do `init` precisa terminar antes de a primeira rodada começar, senão o
        // primeiro trecho pagaria a carga e a medição mediria a carga.
        try? await Task.sleep(nanoseconds: 8_000_000_000)

        for round in 1...max(1, rounds) {
            // Espera a gravação anterior fechar de verdade. O `startListening` é ignorado enquanto
            // o estado é `.processing`, e com o teto do dreno essa janela pode durar 15 s — sem
            // esta espera a rodada seguinte simplesmente não acontece e a medição mente.
            let idleDeadline = Date().addingTimeInterval(40)
            while viewModel.state != .idle, Date() < idleDeadline {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }

            let before = viewModel.historyStore.entries.count
            print("🧪 [sonda-cadência] rodada \(round): histórico ANTES = \(before) | estado = \(describe(viewModel.state))")

            viewModel.startListening()
            try? await Task.sleep(nanoseconds: 700_000_000)
            print("🧪 [sonda-cadência] rodada \(round): gravando (estado = \(describe(viewModel.state)))")

            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))

            if let stopPhase {
                // Ancora no instante em que um trecho POUSOU (o texto cresceu) e para `stopPhase`
                // depois: assim o áudio pendente é conhecido, e não sorteado.
                let anchor = viewModel.sourceText.count
                let deadline = Date().addingTimeInterval(4)
                while viewModel.sourceText.count == anchor, Date() < deadline {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                print("🧪 [sonda-cadência] rodada \(round): trecho pousou, parando em \(stopPhase)s")
                try? await Task.sleep(nanoseconds: UInt64(stopPhase * 1_000_000_000))
            }

            // De propósito NO MEIO da fala (quem toca o áudio não para junto): é assim que existe
            // um trecho periódico em voo e uma tradução pendente no instante do Parar — a corrida
            // que o Farol apontou.
            print("🧪 [sonda-cadência] rodada \(round): PARAR (estado = \(describe(viewModel.state)))")
            viewModel.stopListening()

            // O `stopListening` salva 500 ms depois; damos folga para o último trecho e a tradução —
            // e, se o dreno estiver esperando o teto, para o teto inteiro.
            let archiveDeadline = Date().addingTimeInterval(25)
            while viewModel.state != .idle, Date() < archiveDeadline {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let after = viewModel.historyStore.entries.count
            let newest = viewModel.historyStore.entries.first
            print(
                "🧪 [sonda-cadência] rodada \(round): histórico DEPOIS = \(after)"
                    + " (delta \(after - before)) | estado = \(describe(viewModel.state))"
                    + " | caixas: original \(viewModel.sourceText.count) chars,"
                    + " tradução \(viewModel.translatedText.count) chars"
                    + " | ARQUIVADO: original \(newest?.sourceText.count ?? -1) chars,"
                    + " tradução \(newest?.translatedText.count ?? -1) chars"
                    + " | aviso = \(describe(viewModel.archiveNotice))"
            )

            // A janela do órfão: o trabalho que sobrou tem alguns segundos para reaparecer na tela.
            // Se as caixas continuarem vazias aqui, nada da sessão arquivada escreveu depois dela.
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            print(
                "🧪 [sonda-cadência] rodada \(round): 6s DEPOIS do arquivamento — caixas:"
                    + " original \(viewModel.sourceText.count) chars,"
                    + " tradução \(viewModel.translatedText.count) chars"
                    + " (caixas preservadas quando a tradução falhou)"
            )
        }
    }

    private static func describe(_ notice: TranslationArchiveNotice?) -> String {
        switch notice {
        case .none: return "nenhum"
        case .complete: return "completo"
        case .missingTail: return "SEM O FINAL"
        case .translationIncomplete: return "TRADUÇÃO INCOMPLETA"
        }
    }

    private static func describe(_ state: TranscriptionState) -> String {
        switch state {
        case .idle: return "idle"
        case .listening: return "listening"
        case .processing: return "processing"
        case .error: return "error"
        }
    }

    // MARK: - Medições

    private static func measureCoordinator(
        _ chunks: [[Float]],
        selection: TranscriptionUserSelection,
        coordinator: TranscriptionCoordinator
    ) async -> [TranslationCadenceSample] {
        var samples: [TranslationCadenceSample] = []
        for (index, chunk) in chunks.enumerated() {
            let start = Date()
            do {
                let outcome = try await coordinator.transcribe(
                    TranscriptionRequest(
                        useCase: .translationChunk,
                        language: .english,
                        audio: TranscriptionAudio(samples: chunk)
                    ),
                    selection: selection,
                    retryPolicy: .silentInteractive
                )
                samples.append(
                    TranslationCadenceSample(
                        index: index,
                        audioSeconds: Double(chunk.count) / TranscriptionAudio.defaultSampleRate,
                        wallSeconds: Date().timeIntervalSince(start),
                        inferenceSeconds: outcome.result.processingTime,
                        characters: outcome.text.count
                    )
                )
            } catch {
                print("🧪 [sonda-cadência] trecho \(index) falhou: \(error.localizedDescription)")
            }
        }
        return samples
    }

    private static func measureLegacy(_ chunks: [[Float]]) async -> [TranslationCadenceSample] {
        let service = TranscriptionService.shared
        let start = Date()
        await service.ensureInitialized()
        print("🧪 [sonda-cadência] inicialização do legado: \(seconds(since: start))")

        var samples: [TranslationCadenceSample] = []
        for (index, chunk) in chunks.enumerated() {
            let chunkStart = Date()
            do {
                let result = try await service.transcribe(audioSamples: chunk, language: .english)
                samples.append(
                    TranslationCadenceSample(
                        index: index,
                        audioSeconds: Double(chunk.count) / TranscriptionAudio.defaultSampleRate,
                        wallSeconds: Date().timeIntervalSince(chunkStart),
                        inferenceSeconds: result.processingTime,
                        characters: result.fullText.count
                    )
                )
            } catch {
                print("🧪 [sonda-cadência] trecho legado \(index) falhou: \(error.localizedDescription)")
            }
        }
        return samples
    }

    /// O laço de verdade, em tempo real: um produtor despeja o áudio no ritmo do microfone e o
    /// consumidor reproduz o laço antigo de 1,2 s. A validação atual de segmentação usa
    /// `TranslationSpeechProbe` e `TranslationSpeechPipeline`, compartilhado com a captura real. É aqui que a bola de
    /// neve aparece — ou não.
    private static func replayLoop(
        audio: TranscriptionAudio,
        selection: TranscriptionUserSelection,
        coordinator: TranscriptionCoordinator,
        threshold: Int
    ) async {
        print("🧪 [sonda-cadência] --- replay do laço de 1,2 s em tempo real (limiar \(threshold) amostras) ---")

        let buffer = ProbeAudioBuffer()
        let producer = Task {
            // O microfone entrega em blocos pequenos e contínuos; 0,1 s é a granularidade real.
            let step = Int(0.1 * TranscriptionAudio.defaultSampleRate)
            var offset = 0
            while offset < audio.samples.count, !Task.isCancelled {
                let end = min(offset + step, audio.samples.count)
                await buffer.append(Array(audio.samples[offset..<end]))
                offset = end
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        let started = Date()
        var lastProcessedIndex = 0
        var isProcessingChunk = false
        var skipped = 0
        var served = 0
        var sizes: [Double] = []
        let inflight = ProbeFlag()

        while Date().timeIntervalSince(started) < audio.duration + 3 {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            let total = await buffer.count
            guard total - lastProcessedIndex >= threshold else { continue }

            isProcessingChunk = await inflight.value
            guard !isProcessingChunk else {
                skipped += 1
                continue
            }

            let chunk = await buffer.slice(from: lastProcessedIndex)
            lastProcessedIndex = total
            served += 1
            let chunkSeconds = Double(chunk.count) / TranscriptionAudio.defaultSampleRate
            sizes.append(chunkSeconds)
            print(
                "🧪 [sonda-cadência] t+\(seconds(since: started)) trecho #\(served): "
                    + "\(String(format: "%.1f", chunkSeconds))s de áudio (ciclos pulados até aqui: \(skipped))"
            )

            await inflight.set(true)
            // `served` continua sendo mutado pelo laço: sem esta cópia o Task imprimiria o número
            // de um trecho posterior (e o compilador avisa).
            let servedIndex = served
            Task {
                let start = Date()
                _ = try? await coordinator.transcribe(
                    TranscriptionRequest(
                        useCase: .translationChunk,
                        language: .english,
                        audio: TranscriptionAudio(samples: chunk)
                    ),
                    selection: selection,
                    retryPolicy: .silentInteractive
                )
                print(
                    "🧪 [sonda-cadência]     trecho #\(servedIndex) devolveu em \(seconds(since: start))"
                        + " (áudio \(String(format: "%.1f", chunkSeconds))s)"
                )
                await inflight.set(false)
            }
        }

        producer.cancel()
        let doubled = sizes.count { $0 > cycleSeconds * 1.6 }
        print(
            "🧪 [sonda-cadência] replay (limiar \(threshold)): \(served) trechos servidos,"
                + " \(skipped) ciclos pulados, \(doubled) trechos DOBRADOS (> 1,9 s de áudio)"
        )
    }

    // MARK: - Relatório

    private static func report(_ title: String, _ samples: [TranslationCadenceSample]) {
        guard !samples.isEmpty else {
            print("🧪 [sonda-cadência] \(title): nenhuma medição")
            return
        }
        print("🧪 [sonda-cadência] === \(title) ===")
        for sample in samples {
            let inference = sample.inferenceSeconds.map { String(format: "%.3f", $0) } ?? "—"
            let overhead = sample.overheadSeconds.map { String(format: "%.3f", $0) } ?? "—"
            print(
                "🧪 [sonda-cadência] #\(sample.index) áudio \(String(format: "%.1f", sample.audioSeconds))s"
                    + " | total \(String(format: "%.3f", sample.wallSeconds))s"
                    + " | inferência \(inference)s | fora da inferência \(overhead)s"
                    + " | \(sample.characters) chars"
            )
        }
        let walls = samples.map(\.wallSeconds).sorted()
        let mean = walls.reduce(0, +) / Double(walls.count)
        let overCycle = walls.count { $0 > cycleSeconds }
        print(
            "🧪 [sonda-cadência] \(title): média \(String(format: "%.3f", mean))s"
                + " | mediana \(String(format: "%.3f", walls[walls.count / 2]))s"
                + " | pior \(String(format: "%.3f", walls[walls.count - 1]))s"
                + " | acima de 1,2 s: \(overCycle)/\(walls.count)"
        )
    }

    private static func seconds(since date: Date) -> String {
        String(format: "%.3fs", Date().timeIntervalSince(date))
    }

    private static func finish(_ options: TranslationCadenceProbeOptions) {
        guard options.shouldExit else { return }
        exit(0)
    }
}

/// O buffer do produtor, isolado — o laço da sonda lê de outra tarefa.
private actor ProbeAudioBuffer {
    private var samples: [Float] = []

    var count: Int { samples.count }

    func append(_ new: [Float]) {
        samples.append(contentsOf: new)
    }

    func slice(from index: Int) -> [Float] {
        guard index < samples.count else { return [] }
        return Array(samples[index...])
    }
}

/// O `isProcessingChunk` da tradução, atravessando tarefas.
private actor ProbeFlag {
    private(set) var value = false
    func set(_ newValue: Bool) { value = newValue }
}
#endif
