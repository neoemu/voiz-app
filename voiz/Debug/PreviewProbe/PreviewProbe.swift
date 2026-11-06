#if DEBUG
import Foundation

/// Sonda headless da PRÉVIA da reunião: roda o serviço de verdade com áudio de arquivo e grava
/// cada emissão.
///
/// Existe porque o defeito de repetição na prévia foi diagnosticado três vezes pela tela e três
/// vezes no lugar errado. Olhar só de onde o texto sai não bastou: é preciso ver a sequência
/// inteira de emissões, que é o que o view model consome.
///
/// A saída vai para ARQUIVO, nunca para o log — ela contém transcript, e a regra 7 vale para o
/// log. O arquivo fica no container e é material de diagnóstico, como as referências do corpus.
///
/// Uso:
///   voiz --voiz-preview-probe <wav> --voiz-preview-probe-out <arquivo.jsonl>
///        [--voiz-preview-probe-seconds N] [--voiz-preview-probe-exit]
nonisolated struct PreviewProbeOptions: Sendable, Equatable {
    var audioPath: String
    var outPath: String
    var seconds: Double?
    var shouldExit: Bool

    static let flag = "--voiz-preview-probe"

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(flag)
    }

    static func parse(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> PreviewProbeOptions? {
        guard arguments.contains(flag),
              let audio = value(of: flag, in: arguments),
              let out = value(of: "--voiz-preview-probe-out", in: arguments)
        else { return nil }
        return PreviewProbeOptions(
            audioPath: audio,
            outPath: out,
            seconds: value(of: "--voiz-preview-probe-seconds", in: arguments).flatMap(Double.init),
            shouldExit: arguments.contains("--voiz-preview-probe-exit")
        )
    }

    private static func value(of flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let next = arguments.index(after: index)
        guard next < arguments.endIndex else { return nil }
        return arguments[next]
    }
}

@MainActor
enum PreviewProbe {

    static func runIfRequested() async {
        guard let options = PreviewProbeOptions.parse() else { return }
        await run(options)
        if options.shouldExit { exit(0) }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data(("[preview-probe] " + message + "\n").utf8))
    }

    private static func run(_ options: PreviewProbeOptions) async {
        let audio: TranscriptionAudio
        do {
            audio = try BenchmarkAudioLoader.load(url: URL(fileURLWithPath: options.audioPath))
        } catch {
            log("falha ao carregar áudio: \(type(of: error))")
            return
        }

        var samples = audio.samples
        if let limite = options.seconds {
            samples = Array(samples.prefix(Int(limite * 16_000)))
        }
        log("áudio: \(String(format: "%.1f", Double(samples.count) / 16_000))s")

        let service = MeetingLivePreviewService()
        var eventos: [[String: Any]] = []
        let inicio = Date()

        service.onWindowText = { [weak service] texto in
            eventos.append([
                "t": Date().timeIntervalSince(inicio),
                "kind": "window",
                "chars": texto.count,
                "text": texto,
                "segments": (service?.debugBlockSegments ?? []).map {
                    ["start": $0.start, "end": $0.end, "text": $0.text]
                },
            ])
        }
        service.onWindowCommitted = { texto, reason in
            eventos.append([
                "t": Date().timeIntervalSince(inicio),
                "kind": "commit",
                "reason": String(describing: reason),
                "chars": texto.count,
                "text": texto,
            ])
        }
        service.onDeactivated = { motivo in
            eventos.append(["t": Date().timeIntervalSince(inicio), "kind": "off", "reason": motivo])
        }

        await service.start(language: .portuguese)
        log("serviço ligado (bloco inteiro: \(service.emitsWholeBlockText))")

        // Alimenta em ritmo de tempo real, como a captura faz: sem pacing a prévia não passa pelos
        // mesmos estados de janela e silêncio.
        let passo = 4_000  // 0,25s
        var offset = 0
        while offset < samples.count {
            let fim = min(offset + passo, samples.count)
            service.append(source: .systemAudio, samples: Array(samples[offset..<fim]))
            offset = fim
            try? await Task.sleep(for: .seconds(0.25))
        }
        // Deixa a última janela fechar.
        try? await Task.sleep(for: .seconds(5))
        service.stop()

        let linhas = eventos.compactMap { evento -> String? in
            guard let data = try? JSONSerialization.data(withJSONObject: evento) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        do {
            try linhas.joined(separator: "\n").write(
                toFile: options.outPath, atomically: true, encoding: .utf8
            )
            log("eventos: \(eventos.count) -> \(options.outPath)")
        } catch {
            log("falha ao gravar: \(type(of: error))")
        }
    }
}
#endif
