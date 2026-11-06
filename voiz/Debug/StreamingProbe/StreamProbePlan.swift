#if DEBUG
import Foundation

/// Núcleo PURO da sonda `--voiz-stream-probe`: parse de argv e plano de alimentação.
///
/// Extraído para um arquivo Foundation-only (sem `Speech`/`AVFAudio`) pelo mesmo motivo
/// do `AppleSpeechAnalyzerEngine`: compila no alvo `voizTests` via symlink em
/// `Transcription/StreamProbeSeam/`, então os defaults e as combinações de flags são
/// provados por teste unitário em vez de só existirem no app. A sonda executável usa
/// estas mesmas funções — não há espelho.
///
/// Regra 7: aqui não passa texto transcrito em nenhuma hipótese (só flags e contagens).
nonisolated struct StreamProbeOptions: Sendable, Equatable {
    static let flag = "--voiz-stream-probe"

    var wavPath: String?
    var realTime = false
    var hypothesisOut: String?
    var eventsOut: String?
    /// "custom" (volatileResults explícito) ou "progressive" (preset da Apple).
    var preset = "custom"
    /// Locale do módulo (default pt-BR).
    var locale = "pt-BR"
    /// true = o áudio inteiro num único buffer (o padrão do motor em lote da T3.3).
    var singleBuffer = false
    /// Se > 0, chama `finalize(through:)` a cada N segundos de áudio alimentado.
    /// MEDIDO como TRAVA em sessão viva — existe como repro do achado (ver a sonda).
    var finalizeEvery = 0.0

    nonisolated static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(flag)
    }
}

nonisolated enum StreamProbeOptionsError: Error, Sendable, Equatable {
    case missingWavPath
    /// Combinação que mentiria na telemetria: `--rt` promete pacing em tempo real,
    /// mas `--single-buffer` entrega o áudio inteiro de uma vez (review do Vigia, r2).
    case realTimeWithSingleBuffer
}

nonisolated enum StreamProbeOptionsParse {
    /// `nil` = a flag da sonda não está presente. Erro tipado para as combinações inválidas.
    static func parse(_ arguments: [String]) -> Result<StreamProbeOptions, StreamProbeOptionsError>? {
        guard let flagIndex = arguments.firstIndex(of: StreamProbeOptions.flag) else { return nil }
        var o = StreamProbeOptions()
        var i = flagIndex + 1
        if i < arguments.count, !arguments[i].hasPrefix("--") {
            o.wavPath = arguments[i]
            i += 1
        }
        while i < arguments.count {
            switch arguments[i] {
            case "--rt": o.realTime = true
            case "--hypothesis-out":
                if i + 1 < arguments.count { o.hypothesisOut = arguments[i + 1]; i += 1 }
            case "--events-out":
                if i + 1 < arguments.count { o.eventsOut = arguments[i + 1]; i += 1 }
            case "--preset":
                if i + 1 < arguments.count { o.preset = arguments[i + 1]; i += 1 }
            case "--locale":
                if i + 1 < arguments.count { o.locale = arguments[i + 1]; i += 1 }
            case "--single-buffer": o.singleBuffer = true
            case "--finalize-every":
                if i + 1 < arguments.count { o.finalizeEvery = Double(arguments[i + 1]) ?? 0; i += 1 }
            default: break
            }
            i += 1
        }
        guard o.wavPath != nil else { return .failure(.missingWavPath) }
        guard !(o.realTime && o.singleBuffer) else { return .failure(.realTimeWithSingleBuffer) }
        return .success(o)
    }
}

/// Um trecho `[offset, offset+count)` de frames do buffer completo.
nonisolated struct StreamProbeFeedRange: Sendable, Equatable {
    var offset: Int
    var count: Int
}

nonisolated enum StreamProbeFeedPlan {
    static let defaultChunkSeconds = 0.25

    /// O plano de alimentação da sessão: em `--single-buffer`, exatamente UM range
    /// integral `[0, totalFrames)`; senão, fatias contíguas de `chunkSeconds`.
    static func ranges(
        totalFrames: Int,
        sampleRate: Double,
        chunkSeconds: Double = defaultChunkSeconds,
        singleBuffer: Bool
    ) -> [StreamProbeFeedRange] {
        guard totalFrames > 0 else { return [] }
        if singleBuffer {
            return [StreamProbeFeedRange(offset: 0, count: totalFrames)]
        }
        let framesPerChunk = max(1, Int(chunkSeconds * sampleRate))
        var out: [StreamProbeFeedRange] = []
        var offset = 0
        while offset < totalFrames {
            let end = min(offset + framesPerChunk, totalFrames)
            out.append(StreamProbeFeedRange(offset: offset, count: end - offset))
            offset = end
        }
        return out
    }
}
#endif
