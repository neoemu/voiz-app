import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Sessão ao vivo do `SpeechAnalyzer` para a prévia da reunião.
///
/// É o segundo motor da prévia: o Whisper cobre o arranque e este assume o corpo. A divisão entre
/// os dois é feita pelo `MeetingPreviewComposer`, por tempo de áudio.
///
/// Números que justificam a existência dela, medidos em 27/08/2026 com áudio real de reunião:
/// parciais a cada 3ms depois que engata, resultados finais chegando 0,66s após o fim do trecho, e
/// ~2% de um núcleo somando este processo e o daemon de fala — contra a janela deslizante do
/// Whisper, que roda a inferência dentro do processo do app.
///
/// Regra 7: nada de transcript nos logs daqui. O texto sai pelos callbacks, para a tela.
final class AppleSpeechPreviewSession {

    /// O resultado do analisador viaja no tipo da lógica pura (`MeetingPreviewAppleBuffer.Update`).
    typealias Update = MeetingPreviewAppleBuffer.Update

    /// Chamado a cada resultado — volátil ou final.
    var onUpdate: ((Update) -> Void)?
    /// Chamado quando a sessão morre sozinha. A prévia continua no Whisper; a gravação nunca é
    /// afetada, porque este caminho não toca no áudio que vai para o transcript oficial.
    var onFailure: ((any Error) -> Void)?

    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var collector: Task<Void, Never>?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private let inputFormat: AVAudioFormat

    /// - Parameter sampleRate: taxa do áudio que a captura entrega (16 kHz no app).
    init(sampleRate: Double = 16_000) {
        inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        )!
    }

    /// Sobe o analisador. Lança quando o idioma não tem modelo ou o formato não bate.
    ///
    /// `.progressiveTranscription` e não o preset manual: medido nos dois, o manual atrasou os
    /// resultados finais de 0,66s para 4,05s (máximo de 11,3s), que numa prévia é o texto certo
    /// chegando tarde demais para servir.
    func start(locale: Locale) async throws {
        let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw Failure.noCompatibleFormat
        }
        self.format = format
        // O analisador exige o áudio NO FORMATO DELE. Alimentar 16 kHz cru dá trap dentro do
        // Speech (`SpeechRecognizerWorker.preRunRecognition`) — achado da sonda de 18/08.
        converter = AVAudioConverter(from: inputFormat, to: format)

        let analyzer = SpeechAnalyzer(
            modules: [module],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
        )
        try await analyzer.prepareToAnalyze(in: format)

        let (inputs, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        self.analyzer = analyzer

        collector = Task { [weak self] in
            do {
                for try await result in module.results {
                    let inicio = result.range.start.seconds
                    let fim = (result.range.start + result.range.duration).seconds
                    let update = Update(
                        segment: .init(
                            start: inicio.isFinite ? inicio : 0,
                            end: fim.isFinite ? fim : 0,
                            text: String(result.text.characters)
                        ),
                        isFinal: result.isFinal
                    )
                    self?.onUpdate?(update)
                }
            } catch {
                self?.onFailure?(error)
            }
        }

        try await analyzer.start(inputSequence: inputs)
    }

    /// Entrega áudio da captura. Silencioso quando a sessão não subiu: quem manda áudio não
    /// precisa saber se o segundo motor está de pé.
    func append(samples: [Float]) {
        guard let continuation, let format, let converter, !samples.isEmpty else { return }
        guard let entrada = AVAudioPCMBuffer(
            pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return }
        entrada.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { origem in
            entrada.floatChannelData![0].update(from: origem.baseAddress!, count: samples.count)
        }

        let capacidade = AVAudioFrameCount(
            Double(samples.count) * format.sampleRate / inputFormat.sampleRate + 1024
        )
        guard let saida = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacidade) else { return }
        var entregue = false
        var erro: NSError?
        converter.convert(to: saida, error: &erro) { _, status in
            if entregue { status.pointee = .noDataNow; return nil }
            entregue = true
            status.pointee = .haveData
            return entrada
        }
        guard erro == nil, saida.frameLength > 0 else { return }
        continuation.yield(AnalyzerInput(buffer: saida))
    }

    /// Encerra a sessão. Idempotente: o serviço de prévia chama no stop e no fallback.
    func stop() async {
        continuation?.finish()
        continuation = nil
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        analyzer = nil
        collector?.cancel()
        collector = nil
        converter = nil
        format = nil
    }

    enum Failure: Error {
        case noCompatibleFormat
    }
}
