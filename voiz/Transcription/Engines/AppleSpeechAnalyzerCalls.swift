import AVFoundation
import Foundation
import Speech

// A única parte do adapter da T3.3 que os testes não compilam: aqui moram `SpeechAnalyzer`,
// `SpeechTranscriber`, `AssetInventory` e os buffers do `AVFAudio`.
//
// Por isso não há **decisão** neste arquivo: encaminhamento de chamada, conversão de tipo e um
// `switch` exaustivo. A ordem reservar → status → instalar → reverificar, o que conta como
// sucesso e o que vira qual erro estão em `AppleSpeechAssetRuntime`, que é puro e testado.

/// Encaminha as chamadas cruas do `Speech`.
///
/// `actor` porque o analyzer residente é estado mutável compartilhado: quem serializa o uso dele é
/// a vaga única do motor, e este ator só garante que a referência não seja lida e escrita ao mesmo
/// tempo.
actor AppleSpeechAnalyzerCalls: AppleSpeechCalls {

    /// O locale ativo e, enquanto ninguém o consumiu, o par analyzer+módulo que o `prepare`
    /// aqueceu.
    ///
    /// Guardamos o formato porque `bestAvailableAudioFormat` é uma consulta assíncrona ao sistema:
    /// refazê-la a cada lote seria trabalho repetido sem resposta diferente enquanto o locale não
    /// muda.
    ///
    /// `warm` é **opcional e consumível** porque um `SpeechAnalyzer` é de uso único: depois de
    /// `finalizeAndFinishThroughEndOfInput()` ele está encerrado e a sequência de resultados do
    /// módulo dele terminou. Ver `run(samples:sampleRate:locale:)` para o que isso significa na
    /// prática — e para o que o `.ready` do motor promete de fato.
    private struct Active {
        var locale: AppleSpeechLocale
        var format: AVAudioFormat
        /// O par aquecido por `activateAnalyzer`, ainda não usado. `nil` = já foi consumido por um
        /// lote.
        var warm: Warm?
    }

    private struct Warm {
        var analyzer: SpeechAnalyzer
        var module: SpeechTranscriber
    }

    private var active: Active?

    /// Opções do analyzer.
    ///
    /// `modelRetention: .processLifetime` é o que dá residência de verdade: sem ela o sistema
    /// solta os modelos assim que o analyzer termina, e cada lote de uma reunião pagaria a carga
    /// de novo. Em troca, `deactivateAnalyzer()` precisa chamar `SpeechModels.endRetention()` —
    /// senão "descarregar" não descarregaria nada, que é exatamente a mentira que o item 4 do
    /// contrato de ciclo de vida proíbe.
    private static let analyzerOptions = SpeechAnalyzer.Options(
        priority: .userInitiated,
        modelRetention: .processLifetime
    )

    /// O módulo do locale.
    ///
    /// Instância nova a cada uso, de propósito: a sonda da T0.2 mediu o estado do `AssetInventory`
    /// sempre com um módulo novo, porque cache de instância mascara mudança de estado — e a
    /// instalação de asset é revogável.
    ///
    /// Atributos pedidos explicitamente em vez de um preset pronto: `.audioTimeRange` é o que dá
    /// início/fim aos segmentos do contrato e `.transcriptionConfidence` é a confiança que o
    /// resultado carrega. Sem `.volatileResults`, porque em lote hipótese parcial é lixo.
    private static func module(for locale: AppleSpeechLocale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: Locale(identifier: locale.identifier),
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
    }

    // MARK: - AppleSpeechCalls

    var isAvailable: Bool {
        get async { SpeechTranscriber.isAvailable }
    }

    func isSupported(_ locale: AppleSpeechLocale) async -> Bool {
        await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale.identifier)) != nil
    }

    @discardableResult
    func reserve(_ locale: AppleSpeechLocale) async throws -> Bool {
        try await AssetInventory.reserve(locale: Locale(identifier: locale.identifier))
    }

    var maximumReservedLocales: Int {
        get async { AssetInventory.maximumReservedLocales }
    }

    func status(_ locale: AppleSpeechLocale) async -> AppleSpeechAssetStatus {
        switch await AssetInventory.status(forModules: [Self.module(for: locale)]) {
        case .unsupported: return .unsupported
        case .supported: return .supported
        case .downloading: return .downloading
        case .installed: return .installed
        @unknown default: return .unsupported
        }
    }

    @discardableResult
    func installAsset(_ locale: AppleSpeechLocale) async throws -> Bool {
        guard let request = try await AssetInventory.assetInstallationRequest(
            supporting: [Self.module(for: locale)]
        ) else {
            return false
        }
        try await request.downloadAndInstall()
        return true
    }

    /// Deixa o locale ativo e **aquece o par que o próximo lote vai usar de fato**.
    ///
    /// O aquecimento não é uma suposição sobre o framework: `run` consome exatamente este
    /// `analyzer`/`module`, não um par parecido. Antes desta correção o `prepare` aquecia um
    /// analyzer e o `run` analisava noutro, apostando que `.processLifetime` faria o segundo
    /// reaproveitar os modelos do primeiro — se a aposta não valesse, o `.ready` do motor
    /// prometia um aquecimento que não tinha acontecido (achado da Quilha; DECISOES, T3.3 (d)).
    func activateAnalyzer(_ locale: AppleSpeechLocale) async throws {
        await deactivateAnalyzer()

        let module = Self.module(for: locale)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw AppleSpeechCallFailure.noCompatibleAudioFormat
        }
        let analyzer = SpeechAnalyzer(modules: [module], options: Self.analyzerOptions)
        // É aqui que os modelos do locale entram na memória.
        try await analyzer.prepareToAnalyze(in: format)

        active = Active(locale: locale, format: format, warm: Warm(analyzer: analyzer, module: module))
    }

    var activeLocale: AppleSpeechLocale? {
        get async { active?.locale }
    }

    /// Analisa um lote.
    ///
    /// ## Qual analyzer roda
    ///
    /// Um `SpeechAnalyzer` é de **uso único**: `finalizeAndFinishThroughEndOfInput()` o encerra, e
    /// é justamente esse encerramento que faz a sequência de resultados do módulo terminar — o que
    /// torna a coleta determinística ("li tudo" = fim da sequência, não um prazo). Então:
    ///
    /// - o **primeiro** lote depois de um `prepare` usa o par que o `prepare` aqueceu;
    /// - os lotes seguintes constroem um par novo, sem `prepareToAnalyze`, sobre os modelos que a
    ///   retenção `.processLifetime` manteve no processo.
    ///
    /// É por isso que o `.ready` do motor promete exatamente "o primeiro lote não paga carga" — e
    /// nada além disso. Quanto os lotes seguintes economizam com a retenção é uma medição, e a
    /// Onda 3 é onde ela sai de graça.
    func run(
        samples: [Float],
        sampleRate: Double,
        locale: AppleSpeechLocale,
        context: TranscriptionContext = TranscriptionContext()
    ) async throws -> AppleSpeechRuntimeOutput {
        guard var current = active, current.locale == locale else {
            throw AppleSpeechCallFailure.analyzerNotActive
        }

        let started = Date()
        let buffer = try Self.buffer(samples: samples, sampleRate: sampleRate, target: current.format)

        // Consome o aquecido, se houver. O locale continua ativo: o que se esgota é o par, não a
        // residência.
        let warm: Warm
        if let prepared = current.warm {
            warm = prepared
            current.warm = nil
            active = current
        } else {
            let module = Self.module(for: locale)
            warm = Warm(
                analyzer: SpeechAnalyzer(modules: [module], options: Self.analyzerOptions),
                module: module
            )
        }

        let analyzer = warm.analyzer
        let module = warm.module
        let (inputs, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        let collector = Task {
            var collected: [AppleSpeechTranscriptSegment] = []
            for try await result in module.results {
                collected.append(Self.segment(from: result))
            }
            return collected
        }

        do {
            try await analyzer.start(inputSequence: inputs)
            continuation.yield(AnalyzerInput(buffer: buffer))
            continuation.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            continuation.finish()
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }

        // O prazo e a classificação do estouro são decisão, e moram no arquivo puro e testado.
        let audioSeconds = sampleRate > 0 ? Double(samples.count) / sampleRate : 0
        let segments: [AppleSpeechTranscriptSegment]
        do {
            segments = try await AppleSpeechBatchCollection.collect(
                collector,
                timeout: AppleSpeechBatchCollection.deadline(forAudioSeconds: audioSeconds)
            )
        } catch {
            await analyzer.cancelAndFinishNow()
            throw error
        }

        let base = AppleSpeechRuntimeOutput(
            segments: segments,
            processingTime: Date().timeIntervalSince(started)
        )
        guard context.usesAppleDictationVocabulary else { return base }
        let adapted = try await AppleDictationVocabularyCalls.transcribe(
            samples: samples, sampleRate: sampleRate, locale: locale, vocabulary: context.appleVocabulary
        )
        return AppleVocabularyFusion.combine(base: base, adapted: adapted, vocabulary: context.appleVocabulary)
    }

    func deactivateAnalyzer() async {
        guard let dying = active else { return }
        active = nil
        // O par aquecido pode já ter sido consumido por um lote (e nesse caso ele se encerrou
        // sozinho no `finalize`); só há o que encerrar se ninguém o usou.
        await dying.warm?.analyzer.cancelAndFinishNow()
        // Sem isto, `.processLifetime` manteria os modelos na memória e o `unload` do motor seria
        // só esquecer uma referência. Note o que NÃO acontece aqui: `AssetInventory.release(
        // reservedLocale:)`. A reserva é deliberadamente mantida — ver `AppleSpeechAssetRuntime.release()`.
        //
        // `endRetention()` é **do processo**, não desta instância — é a razão de o motor ser único
        // por processo. A regra completa (e o que a T4.2 pode e não pode fazer) está em
        // `AppleSpeechAnalyzerEngine.shared(descriptor:runtime:)`, que é onde ela é imposta.
        await SpeechModels.endRetention()
    }

    // MARK: - Conversões

    /// Um resultado do transcritor vira um trecho do vocabulário do app.
    ///
    /// Os atributos vêm por run da `AttributedString`; o tempo do trecho inteiro é o `range` do
    /// resultado, que existe sempre. A confiança é a média dos runs que a reportam — o transcritor
    /// dá confiança por run, e o contrato guarda uma por segmento.
    private static func segment(from result: SpeechTranscriber.Result) -> AppleSpeechTranscriptSegment {
        segment(text: result.text, range: result.range)
    }

    static func segment(text attributed: AttributedString, range: CMTimeRange) -> AppleSpeechTranscriptSegment {
        let text = String(attributed.characters)
        let start = range.start.seconds
        let end = (range.start + range.duration).seconds

        var confidences: [Double] = []
        for run in attributed.runs {
            if let confidence = run.transcriptionConfidence { confidences.append(confidence) }
        }
        let confidence = confidences.isEmpty
            ? nil
            : Float(confidences.reduce(0, +) / Double(confidences.count))

        var segment = AppleSpeechTranscriptSegment(
            text: text,
            start: start.isFinite ? start : 0,
            end: end.isFinite ? end : 0,
            confidence: confidence
        )
        // Keep the framework's actual word times, not estimates distributed over a sentence.
        // Runs with several lexical words cannot identify a replacement precisely and are skipped.
        for run in attributed.runs {
            guard let timing = run.audioTimeRange else { continue }
            let fragment = String(attributed[run.range].characters)
            let matches = AppleVocabularyFusion.lexicalRanges(in: fragment)
            guard matches.count == 1, let match = matches.first else { continue }
            let prefix = String(attributed[..<run.range.lowerBound].characters).utf16.count
            segment.words.append(AppleSpeechTimedWord(
                text: (fragment as NSString).substring(with: match),
                range: NSRange(location: prefix + match.location, length: match.length),
                start: timing.start.seconds, end: (timing.start + timing.duration).seconds,
                confidence: run.transcriptionConfidence.map(Float.init)
            ))
        }
        return segment
    }

    /// Empacota as amostras mono do pipeline no formato que o transcritor aceita.
    ///
    /// O pipeline do Voiz é `[Float]` 16 kHz mono e a T0.2 mediu 16 kHz/1ch entre os formatos
    /// compatíveis — mas `bestAvailableAudioFormat` é quem decide, e ele pode devolver outra coisa
    /// noutra máquina. Quando devolve, convertemos em vez de entregar áudio no formato errado
    /// (que não dá erro: dá texto errado).
    static func buffer(
        samples: [Float],
        sampleRate: Double,
        target: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AppleSpeechCallFailure.noCompatibleAudioFormat
        }

        guard let source = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw AppleSpeechCallFailure.noCompatibleAudioFormat
        }
        source.frameLength = AVAudioFrameCount(samples.count)
        if let channel = source.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { pointer in
                channel.update(from: pointer.baseAddress!, count: samples.count)
            }
        }

        if sourceFormat == target { return source }

        guard let converter = AVAudioConverter(from: sourceFormat, to: target) else {
            throw AppleSpeechCallFailure.noCompatibleAudioFormat
        }
        let ratio = target.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(samples.count) * ratio).rounded(.up)) + 1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw AppleSpeechCallFailure.noCompatibleAudioFormat
        }

        // O bloco de entrada do `AVAudioConverter` é `@Sendable`, mas roda **síncrono** dentro de
        // `convert(to:error:)` e o buffer nunca escapa desta função. A caixa diz isso ao
        // compilador sem `@preconcurrency` no import inteiro, que silenciaria avisos legítimos.
        let boxed = UncheckedSendableBox(value: source)
        var delivered = false
        var conversionError: NSError?
        converter.convert(to: converted, error: &conversionError) { _, status in
            if delivered {
                status.pointee = .endOfStream
                return nil
            }
            delivered = true
            status.pointee = .haveData
            return boxed.value
        }
        if let conversionError { throw conversionError }
        return converted
    }
}

/// Transporta um valor não-`Sendable` por um bloco `@Sendable` que roda síncrono no mesmo escopo.
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
}

extension AppleSpeechAnalyzerEngine {
    /// O motor ligado ao `Speech` de verdade — **a instância única do processo**.
    ///
    /// Chamar duas vezes devolve o mesmo motor, e a segunda chamada nem constrói uma camada de
    /// chamadas nova: `AssetInventory` e `SpeechModels` são estado do processo, então duas
    /// instâncias seriam dois donos do mesmo recurso. O porquê inteiro (e a regra de retenção que
    /// a T4.2 tem de respeitar) está em `shared(descriptor:runtime:)`.
    ///
    /// Sem parâmetro de observador de propósito: numa instância compartilhada ele seria ignorado
    /// na segunda chamada ou substituiria o do dono anterior em silêncio. Quem quer observar chama
    /// `setObserver(_:)`.
    ///
    /// `nonisolated` porque nada aqui é do main actor — ao contrário do Parakeet, este motor não
    /// depende de nenhum serviço `@MainActor`. Ninguém chama isto ainda: quem monta motores é a T2.3.
    nonisolated static func make() -> AppleSpeechAnalyzerEngine {
        shared { AppleSpeechAssetRuntime(calls: AppleSpeechAnalyzerCalls()) }
    }
}
