#if DEBUG
import Foundation

/// Progresso sem transcript (só ids, contagens e tempos).
nonisolated struct BenchmarkProgress: Sendable, Equatable {
    var message: String
    var fraction: Double?
}

/// Runner STRICT: motores reais via `make()`, 2 warm-ups descartados, itens em série.
///
/// Helpers de I/O/parse são `nonisolated` — este actor não cruza MainActor para eles.
actor BenchmarkRunner {
    /// Alias estável para o contrato (mesma constante testada em voizTests).
    nonisolated static var warmUpCount: Int { BenchmarkContract.warmUpCount }

    private var cancelled = false

    func cancel() {
        cancelled = true
    }

    func run(
        corpusRoot: URL,
        outputDirectory: URL,
        targets: [BenchmarkEngineTarget],
        commitOverride: String? = nil,
        onProgress: @Sendable (BenchmarkProgress) -> Void
    ) async throws -> [URL] {
        cancelled = false
        guard !targets.isEmpty else { throw BenchmarkRunnerError.noTargets }

        let (manifestURL, items) = try BenchmarkManifestLoader.loadCorpus(root: corpusRoot)
        guard !items.isEmpty else { throw BenchmarkRunnerError.noItems }

        let hardware = BenchmarkHardwareInfo.capture(commitOverride: commitOverride)
        onProgress(BenchmarkProgress(
            message: "Corpus: \(items.count) itens; manifesto \(manifestURL.lastPathComponent); commit=\(hardware.appCommit)",
            fraction: 0
        ))

        var audioByID: [String: TranscriptionAudio] = [:]
        for (idx, item) in items.enumerated() {
            try checkCancelled()
            let url = item.resolvedAudioURL(corpusRoot: corpusRoot)
            onProgress(BenchmarkProgress(
                message: "Carregando áudio \(idx + 1)/\(items.count) id=\(item.id)",
                fraction: Double(idx) / Double(items.count + targets.count * items.count)
            ))
            audioByID[item.id] = try BenchmarkAudioLoader.load(url: url)
        }

        var written: [URL] = []
        // Parakeet.make(service:) e o serviço são @MainActor (default isolation do app).
        let engines = await MainActor.run { BenchmarkLiveEngines() }

        for (tIndex, target) in targets.enumerated() {
            try checkCancelled()
            onProgress(BenchmarkProgress(
                message: "Motor \(target.slug): prepare…",
                fraction: Double(tIndex) / Double(targets.count)
            ))

            let engine: any BatchTranscriptionEngine
            do {
                engine = try await MainActor.run { try engines.engine(for: target) }
            } catch {
                throw BenchmarkRunnerError.enginePrepare(
                    "\(target.slug): \(String(describing: type(of: error)))"
                )
            }
            do {
                try await engine.prepare(model: target.model)
            } catch {
                throw BenchmarkRunnerError.enginePrepare(
                    "\(target.slug): \(String(describing: type(of: error)))"
                )
            }

            if let first = items.first, let audio = audioByID[first.id] {
                for w in 1...Self.warmUpCount {
                    try checkCancelled()
                    onProgress(BenchmarkProgress(
                        message: "Warm-up \(w)/\(Self.warmUpCount) id=\(first.id) (descartado)",
                        fraction: nil
                    ))
                    _ = try? await transcribe(
                        engine: engine,
                        target: target,
                        item: first,
                        audio: audio
                    )
                }
            }

            var metrics: [BenchmarkItemMetrics] = []
            var hypotheses: [String: String] = [:]

            for (idx, item) in items.enumerated() {
                try checkCancelled()
                guard let audio = audioByID[item.id] else { continue }
                onProgress(BenchmarkProgress(
                    message: "[\(target.slug)] \(idx + 1)/\(items.count) id=\(item.id)",
                    fraction: (Double(tIndex) + Double(idx) / Double(items.count))
                        / Double(targets.count)
                ))

                let wallStart = ContinuousClock.now
                do {
                    let result = try await transcribe(
                        engine: engine,
                        target: target,
                        item: item,
                        audio: audio
                    )
                    let wall = wallStart.duration(to: .now)
                    let latency = max(seconds(wall), 0.000_001)
                    let duration = audio.duration > 0 ? audio.duration : item.durationS
                    let rtfx = duration / latency
                    let text = result.text
                    metrics.append(BenchmarkItemMetrics(
                        id: item.id,
                        audioDurationS: duration,
                        latencyS: latency,
                        rtfx: rtfx,
                        charCount: text.count,
                        error: nil
                    ))
                    hypotheses[item.id] = text
                    onProgress(BenchmarkProgress(
                        message: "  ok id=\(item.id) latency_s=\(String(format: "%.3f", latency)) rtfx=\(String(format: "%.2f", rtfx)) chars=\(text.count)",
                        fraction: nil
                    ))
                } catch {
                    let wall = wallStart.duration(to: .now)
                    let latency = seconds(wall)
                    let duration = audio.duration > 0 ? audio.duration : item.durationS
                    let errName = shortErrorName(error)
                    metrics.append(BenchmarkItemMetrics(
                        id: item.id,
                        audioDurationS: duration,
                        latencyS: latency,
                        rtfx: .nan,
                        charCount: 0,
                        error: errName
                    ))
                    hypotheses[item.id] = ""
                    onProgress(BenchmarkProgress(
                        message: "  ERROR id=\(item.id) \(errName)",
                        fraction: nil
                    ))
                }
            }

            // Fingerprint do artefato efetivo (pós-prepare — pesos no disco/sistema).
            let revision = BenchmarkModelIdentity.revision(for: target)
            onProgress(BenchmarkProgress(
                message: "  model_revision=\(revision)",
                fraction: nil
            ))

            let (metricsURL, hypURL) = try BenchmarkOutputWriter.writeRound(
                outputDirectory: outputDirectory,
                target: target,
                hardware: hardware,
                modelRevision: revision,
                timestamp: Date(),
                items: metrics,
                hypotheses: hypotheses,
                manifestURL: manifestURL,
                warmUpCount: Self.warmUpCount
            )
            hypotheses.removeAll(keepingCapacity: false)

            written.append(metricsURL)
            written.append(hypURL)
            onProgress(BenchmarkProgress(
                message: "Escrito \(metricsURL.lastPathComponent) + \(hypURL.lastPathComponent)",
                fraction: Double(tIndex + 1) / Double(targets.count)
            ))

            await engine.unload()
        }

        await engines.shutdown()
        onProgress(BenchmarkProgress(message: "Concluído.", fraction: 1))
        return written
    }

    private func checkCancelled() throws {
        if cancelled { throw BenchmarkRunnerError.cancelled }
    }

    private func transcribe(
        engine: any BatchTranscriptionEngine,
        target: BenchmarkEngineTarget,
        item: BenchmarkManifestItem,
        audio: TranscriptionAudio
    ) async throws -> TranscriptionEngineResult {
        let request = TranscriptionRequest(
            useCase: .meetingFinal,
            language: item.transcriptionLanguage,
            audio: audio
        )
        let candidate = TranscriptionRoutingCandidate(
            engine: target.engine,
            model: target.model,
            rank: 0,
            origin: .userSelection
        )
        return try await engine.transcribe(request, candidate: candidate)
    }

    private func seconds(_ duration: Duration) -> Double {
        let comps = duration.components
        return Double(comps.seconds) + Double(comps.attoseconds) / 1e18
    }

    private func shortErrorName(_ error: Error) -> String {
        if let e = error as? TranscriptionEngineFailure {
            switch e {
            case .modelUnavailable: return "modelUnavailable"
            case .languageUnsupported: return "languageUnsupported"
            case .hardwareUnsupported: return "hardwareUnsupported"
            case .invalidAudio: return "invalidAudio"
            case .cancelled: return "cancelled"
            case .engineInternal: return "engineInternal"
            }
        }
        return String(describing: type(of: error))
    }
}

/// Motores reais via `make()` — um de cada tipo. `@MainActor` porque o Parakeet e o serviço
/// nascem na isolation default do app; os atores dos motores em si continuam Sendable.
@MainActor
private final class BenchmarkLiveEngines {
    private var whisper: WhisperKitTranscriptionEngine?
    private var parakeet: ParakeetTranscriptionEngine?
    private var parakeetService: ParakeetTranscriptionService?
    private var apple: AppleSpeechAnalyzerEngine?

    func engine(for target: BenchmarkEngineTarget) throws -> any BatchTranscriptionEngine {
        switch target.engine {
        case .whisperKit:
            if let whisper { return whisper }
            let created = WhisperKitTranscriptionEngine.make()
            whisper = created
            return created
        case .parakeet:
            if let parakeet { return parakeet }
            let service = ParakeetTranscriptionService()
            parakeetService = service
            let created = ParakeetTranscriptionEngine.make(service: service)
            parakeet = created
            return created
        case .appleSpeechAnalyzer:
            if let apple { return apple }
            let created = AppleSpeechAnalyzerEngine.make()
            apple = created
            return created
        default:
            throw BenchmarkRunnerError.enginePrepare("motor desconhecido: \(target.engine.rawValue)")
        }
    }

    func shutdown() async {
        if let whisper { await whisper.unload() }
        if let parakeet { await parakeet.unload() }
        if let apple { await apple.unload() }
        whisper = nil
        parakeet = nil
        apple = nil
        parakeetService = nil
    }
}
#endif
