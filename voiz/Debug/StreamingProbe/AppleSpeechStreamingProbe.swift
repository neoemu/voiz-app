#if DEBUG
import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Sonda de STREAMING do `SpeechAnalyzer` (spike do modo leve — Brisa, 2026-08-18).
///
/// Roda DENTRO do app (bundle com `NSSpeechRecognitionUsageDescription` + grant do usuário):
/// um executável CLI sem bundle sofre trap do Speech framework em `preRunRecognition`.
///
/// Mede, com números desta máquina:
///  1) a API de sessão ao vivo funciona em pt-BR (start + feed incremental de buffers);
///  2) latências: setup, primeiro parcial volátil, cadência dos parciais, atraso dos
///     resultados finais (chegada − fim do trecho falado), finalização após o fim do áudio;
///  3) custo: CPU DESTE processo (getrusage) durante a sessão em tempo real — o grosso da
///     inferência roda no daemon de fala/ANE, então é o número que interessa para bateria.
///
/// Regra 7: NENHUM caractere de transcript no stderr. Só contagens e tempos. O texto final
/// (para diff de qualidade) vai para um arquivo cujo path vem de flag, dentro do container.
///
/// Uso:
///   voiz --voiz-stream-probe <wav16k> [--rt] [--preset custom|progressive]
///        [--locale pt-BR|en-US] [--single-buffer] [--hypothesis-out p] [--events-out p]
///     --rt  = alimenta em ritmo de tempo real; incompatível com --single-buffer
///             (sem pacing a telemetria mentiria — o parse rejeita, provado em teste).
/// Parse e plano de alimentação moram em `StreamProbePlan.swift` (puro, testado).
enum AppleSpeechStreamingProbe {
    static let flag = StreamProbeOptions.flag

    static var isRequested: Bool {
        StreamProbeOptions.isRequested
    }

    private struct ResultEvent {
        var wall: Double // segundos desde o início do feed
        var isFinal: Bool
        var rangeStart: Double
        var rangeEnd: Double
        var charCount: Int
    }

    private static func rusageSeconds() -> Double {
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        return Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6
            + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
    }

    private static func log(_ message: String) {
        fputs("[stream-probe] \(message)\n", stderr)
    }

    /// Entrada chamada pelo VoizApp.init (main runloop já garantido).
    @MainActor
    static func runIfRequested() {
        guard isRequested else { return }
        log("headless mode: UI stack suppressed")
        Task {
            let code = await run()
            exit(code)
        }
    }

    private static func run() async -> Int32 {
        let options: StreamProbeOptions
        switch StreamProbeOptionsParse.parse(ProcessInfo.processInfo.arguments) {
        case .success(let parsed):
            options = parsed
        case .failure(.realTimeWithSingleBuffer):
            log("combinação inválida: --rt com --single-buffer (sem pacing, a telemetria mentiria)")
            return 2
        case .failure(.missingWavPath), .none:
            log("uso: \(flag) <wav16k> [--rt] [--preset custom|progressive] [--locale pt-BR|en-US] [--single-buffer] [--hypothesis-out path] [--events-out path]")
            return 2
        }
        let wavPath = options.wavPath ?? ""

        let sourceSamples: [Float]
        do {
            sourceSamples = try loadWAV16kMono(wavPath)
        } catch {
            log("falha ao ler wav: \(type(of: error))")
            return 2
        }
        let audioSeconds = Double(sourceSamples.count) / 16000.0
        log("áudio: \(String(format: "%.2f", audioSeconds))s | modo: \(options.realTime ? "tempo real" : "rajada")")

        // Setup (medido)
        let setupStart = ContinuousClock.now
        let module: SpeechTranscriber
        if options.preset == "progressive" {
            module = SpeechTranscriber(
                locale: Locale(identifier: options.locale),
                preset: .progressiveTranscription
            )
        } else {
            module = SpeechTranscriber(
                locale: Locale(identifier: options.locale),
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: [.audioTimeRange, .transcriptionConfidence]
            )
        }
        log("preset: \(options.preset) | locale: \(options.locale) | finalize-every: \(options.finalizeEvery)s")
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            log("sem formato compatível")
            return 1
        }
        let analyzer = SpeechAnalyzer(
            modules: [module],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
        )
        do {
            try await analyzer.prepareToAnalyze(in: format)
        } catch {
            log("prepareToAnalyze falhou: \(type(of: error))")
            return 1
        }
        log("setup (módulo+analyzer+prepare): \(String(format: "%.3f", seconds(since: setupStart)))s")
        log("formato do analyzer: \(Int(format.sampleRate))Hz ch=\(format.channelCount) fmt=\(format.commonFormat.rawValue) interleaved=\(format.isInterleaved)")

        // O batch da T3.3 entrega o buffer NO FORMATO DO ANALYZER (bestAvailableAudioFormat),
        // não em 16 kHz cru — alimentar em formato diferente dá trap dentro do Speech
        // (SpeechRecognizerWorker.preRunRecognition). Converte uma vez e fatia no formato alvo.
        let fullBuffer: AVAudioPCMBuffer
        do {
            fullBuffer = try convertToAnalyzerFormat(sourceSamples, target: format)
        } catch {
            log("conversão para formato do analyzer falhou: \(type(of: error))")
            return 1
        }
        let totalFrames = Int(fullBuffer.frameLength)
        // O plano de alimentação é o núcleo puro testado em voizTests (StreamProbePlan).
        let feedRanges = StreamProbeFeedPlan.ranges(
            totalFrames: totalFrames,
            sampleRate: format.sampleRate,
            singleBuffer: options.singleBuffer
        )

        // Sessão
        let cpuStart = rusageSeconds()
        let feedStart = ContinuousClock.now
        let (inputs, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        let collector = Task { () -> (events: [ResultEvent], finals: [String]) in
            var events: [ResultEvent] = []
            var finals: [String] = []
            do {
                for try await result in module.results {
                    let wall = seconds(since: feedStart)
                    let text = String(result.text.characters)
                    let startS = result.range.start.seconds
                    let endS = (result.range.start + result.range.duration).seconds
                    events.append(ResultEvent(
                        wall: wall,
                        isFinal: result.isFinal,
                        rangeStart: startS.isFinite ? startS : 0,
                        rangeEnd: endS.isFinite ? endS : 0,
                        charCount: text.count
                    ))
                    if result.isFinal { finals.append(text) }
                }
            } catch {
                log("collector erro: \(type(of: error))")
            }
            return (events, finals)
        }

        do {
            try await analyzer.start(inputSequence: inputs)
        } catch {
            log("start falhou: \(type(of: error))")
            return 1
        }

        // Feeder: o plano (StreamProbeFeedPlan) decide as fatias; em --rt, pautado pelo
        // relógio do áudio. --single-buffer entrega um range integral (réplica do lote).
        var fedSeconds = 0.0
        var yielded = 0
        var nilSlices = 0
        var nextFinalizeAt = options.finalizeEvery
        var finalizeCalls = 0
        for range in feedRanges {
            if let buf = slice(fullBuffer, from: range.offset, count: range.count, format: format) {
                continuation.yield(AnalyzerInput(buffer: buf))
                yielded += 1
            } else {
                nilSlices += 1
            }
            fedSeconds = Double(range.offset + range.count) / format.sampleRate
            if options.realTime {
                let target = fedSeconds
                let elapsed = seconds(since: feedStart)
                if target > elapsed {
                    try? await Task.sleep(for: .seconds(target - elapsed))
                }
            }
            // REPRO do achado: esta chamada não retorna em sessão viva (ver StreamProbePlan).
            if nextFinalizeAt > 0, fedSeconds >= nextFinalizeAt {
                log("finalize(through: \(String(format: "%.1f", fedSeconds))) iniciando…")
                let fStart = ContinuousClock.now
                do {
                    try await analyzer.finalize(through: CMTime(seconds: fedSeconds, preferredTimescale: 16000))
                    finalizeCalls += 1
                    log("finalize(through: \(String(format: "%.1f", fedSeconds))) ok em \(String(format: "%.2f", seconds(since: fStart)))s")
                } catch {
                    log("finalize(through:) falhou em \(String(format: "%.1f", fedSeconds))s: \(type(of: error))")
                }
                nextFinalizeAt += options.finalizeEvery
            }
        }
        let feedDone = seconds(since: feedStart)
        continuation.finish()
        log("feed: \(yielded) buffers entregues, \(nilSlices) fatias nulas, \(finalizeCalls) finalize(through:)")

        let finalizeStart = ContinuousClock.now
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            log("finalize falhou: \(type(of: error))")
        }
        let outcome = await collector.value
        let finalizeElapsed = seconds(since: finalizeStart)
        let cpuEnd = rusageSeconds()
        let sessionWall = seconds(since: feedStart)

        // Métricas
        let events = outcome.events
        let volatileEvents = events.filter { !$0.isFinal }
        let finalEvents = events.filter { $0.isFinal }

        log("-- sessão --")
        log("alimentação: \(String(format: "%.2f", feedDone))s de parede para \(String(format: "%.2f", fedSeconds))s de áudio")
        log("sessão total (feed+fim): \(String(format: "%.3f", sessionWall))s")
        log("finalização após fim do áudio: \(String(format: "%.3f", finalizeElapsed))s")
        log("resultados: \(events.count) (voláteis \(volatileEvents.count), finais \(finalEvents.count))")

        if let firstVolatile = volatileEvents.first {
            log("primeiro parcial volátil: \(String(format: "%.3f", firstVolatile.wall))s após início do feed (cobria até \(String(format: "%.2f", firstVolatile.rangeEnd))s, \(firstVolatile.charCount) chars)")
        } else {
            log("NENHUM parcial volátil recebido")
        }
        if volatileEvents.count > 1 {
            var intervals: [Double] = []
            for i in 1..<volatileEvents.count {
                intervals.append(volatileEvents[i].wall - volatileEvents[i - 1].wall)
            }
            intervals.sort()
            log("cadência dos parciais: p50 \(String(format: "%.3f", intervals[intervals.count / 2]))s (n=\(intervals.count))")
        }
        if !finalEvents.isEmpty {
            var lags: [Double] = []
            for e in finalEvents where e.rangeEnd > 0 {
                lags.append(e.wall - e.rangeEnd)
            }
            if !lags.isEmpty {
                lags.sort()
                log("atraso final−fim-do-trecho: p50 \(String(format: "%.3f", lags[lags.count / 2]))s, máx \(String(format: "%.3f", lags.last!))s (n=\(lags.count))")
            }
            if let firstFinal = finalEvents.first {
                log("primeiro final: \(String(format: "%.3f", firstFinal.wall))s (cobre \(String(format: "%.2f", firstFinal.rangeStart))–\(String(format: "%.2f", firstFinal.rangeEnd))s)")
            }
        }

        let cpu = cpuEnd - cpuStart
        log("CPU do processo app durante a sessão: \(String(format: "%.3f", cpu))s (\(String(format: "%.1f", 100 * cpu / max(sessionWall, 0.001)))% de um núcleo)")

        if let out = options.hypothesisOut {
            let joined = outcome.finals.joined(separator: " ")
            do {
                try joined.write(toFile: out, atomically: true, encoding: .utf8)
                log("hipótese final gravada (\(joined.count) chars)")
            } catch {
                log("falha ao gravar hipótese: \(type(of: error))")
            }
        }
        // Linha do tempo dos eventos (SEM texto — regra 7): wall, isFinal, range, chars.
        if let eventsPath = options.eventsOut {
            var lines: [String] = []
            for e in events {
                lines.append(
                    "{\"wall\":\(String(format: "%.3f", e.wall)),\"final\":\(e.isFinal),\"r0\":\(String(format: "%.2f", e.rangeStart)),\"r1\":\(String(format: "%.2f", e.rangeEnd)),\"chars\":\(e.charCount)}"
                )
            }
            do {
                try lines.joined(separator: "\n").write(toFile: eventsPath, atomically: true, encoding: .utf8)
                log("timeline gravada (\(events.count) eventos)")
            } catch {
                log("falha ao gravar timeline: \(type(of: error))")
            }
        }
        log("FIM")
        return 0
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    private static func loadWAV16kMono(_ path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
        ) else { throw NSError(domain: "streamProbe", code: 1) }
        let frameCount = AVAudioFrameCount(file.length)
        guard let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            throw NSError(domain: "streamProbe", code: 2)
        }
        try file.read(into: source)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "streamProbe", code: 3)
        }
        guard let converter = AVAudioConverter(from: file.processingFormat, to: format) else {
            throw NSError(domain: "streamProbe", code: 4)
        }
        var err: NSError?
        var consumed = false
        converter.convert(to: buf, error: &err) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return source
        }
        if let err { throw err }
        let n = Int(buf.frameLength)
        guard n > 0, let ch = buf.floatChannelData?[0] else {
            throw NSError(domain: "streamProbe", code: 5)
        }
        return Array(UnsafeBufferPointer(start: ch, count: n))
    }

    /// Converte as amostras 16 kHz mono para o formato que o analyzer pediu (uma vez só).
    private static func convertToAnalyzerFormat(
        _ samples: [Float],
        target: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
        ) else { throw NSError(domain: "streamProbe", code: 10) }
        guard let source = AVAudioPCMBuffer(
            pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)
        ) else { throw NSError(domain: "streamProbe", code: 11) }
        source.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { p in
            if let base = p.baseAddress {
                source.floatChannelData?[0].update(from: base, count: samples.count)
            }
        }
        if sourceFormat == target { return source }
        guard let converter = AVAudioConverter(from: sourceFormat, to: target) else {
            throw NSError(domain: "streamProbe", code: 12)
        }
        let ratio = target.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(samples.count) * ratio).rounded(.up)) + 1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw NSError(domain: "streamProbe", code: 13)
        }
        var err: NSError?
        var consumed = false
        converter.convert(to: converted, error: &err) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return source
        }
        if let err { throw err }
        guard converted.frameLength > 0 else { throw NSError(domain: "streamProbe", code: 14) }
        return converted
    }

    /// Fatia [from, from+count) de um buffer em um buffer novo no mesmo formato.
    /// Interleaved (formato que o analyzer pediu nesta máquina) NÃO tem `floatChannelData`
    /// utilizável por canal — copia bytes via `audioBufferList`.
    private static func slice(
        _ buffer: AVAudioPCMBuffer,
        from: Int,
        count: Int,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard count > 0,
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))
        else { return nil }
        out.frameLength = AVAudioFrameCount(count)

        if format.isInterleaved {
            let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
            guard bytesPerFrame > 0 else { return nil }
            let srcList = buffer.audioBufferList.pointee
            guard srcList.mNumberBuffers > 0, let srcData = srcList.mBuffers.mData else { return nil }
            let dstList = out.audioBufferList.pointee
            guard dstList.mNumberBuffers > 0, let dstData = dstList.mBuffers.mData else { return nil }
            dstData.copyMemory(
                from: srcData.advanced(by: from * bytesPerFrame),
                byteCount: count * bytesPerFrame
            )
            return out
        }

        let channels = Int(format.channelCount)
        guard let src = buffer.floatChannelData, let dst = out.floatChannelData else { return nil }
        for c in 0..<channels {
            dst[c].update(from: src[c] + from, count: count)
        }
        return out
    }
}
#endif
