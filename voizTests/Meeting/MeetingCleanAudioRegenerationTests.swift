import Testing
import Foundation
import AVFoundation

/// O caminho de regeneração **só do áudio**: refazer `microphone-clean.caf` sem encostar no
/// transcript.
///
/// Existe porque duas reuniões reais tiveram a faixa limpa mutilada pelo `boxSmooth` em `Float`
/// (ver `MeetingEchoGainSmoothingTests`) e o transcript delas estava certo — inclusive com nomes de
/// falantes corrigidos à mão. Consertar o áudio pela passagem inteira do pós-call custaria
/// reprocessar o transcript, que é justamente o que não se pode perder.
///
/// O áudio aqui é sintético e determinístico (gerador linear congruente com semente fixa): ruído
/// no "system", e um mic que é **cópia atrasada** dele num trecho e voz **independente** noutro.
/// É o mínimo que o detector precisa para distinguir eco de fala junto.
@Suite("Reunião — regenerar só o áudio limpo")
struct MeetingCleanAudioRegenerationTests {

    private static let sampleRate: Double = 16_000
    private static let totalSeconds = 60
    private static let echoRange = 10.0..<20.0        // mic = cópia atrasada do system
    private static let doubleTalkRange = 30.0..<40.0  // system falando E voz própria do usuário
    private static let lagSamples = 3_200             // 200 ms, dentro da busca de ±300 ms

    /// Gerador determinístico: um teste de DSP não pode depender de sorte.
    private struct Noise {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int32(truncatingIfNeeded: state >> 33)) / Float(Int32.max)
        }
    }

    private static func buildAudio() -> (mic: [Float], system: [Float]) {
        let n = Int(sampleRate) * totalSeconds
        var system = [Float](repeating: 0, count: n)
        var mic = [Float](repeating: 0, count: n)
        var systemNoise = Noise(seed: 42)
        var micNoise = Noise(seed: 4_242)

        for i in 0..<n {
            let t = Double(i) / sampleRate
            if echoRange.contains(t) || doubleTalkRange.contains(t) {
                system[i] = systemNoise.next() * 0.3
            }
            if doubleTalkRange.contains(t) {
                mic[i] = micNoise.next() * 0.3     // voz do usuário, sem relação com o system
            }
        }
        // O eco: o mic recebe o system atrasado e mais fraco.
        for i in lagSamples..<n {
            let t = Double(i) / sampleRate
            if echoRange.contains(t) { mic[i] += system[i - lagSamples] * 0.5 }
        }
        return (mic, system)
    }

    private static func write(_ samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                   channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData!.pointee.update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
    }

    /// Em laço, pelo mesmo motivo que o `readSamples` do reconciliador: uma chamada de
    /// `read(into:)` devolve *até* a capacidade do buffer, e não o arquivo inteiro.
    private static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                      frameCapacity: AVAudioFrameCount(file.length))!
        var samples: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: buffer)
            let read = Int(buffer.frameLength)
            guard read > 0 else { break }
            samples.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: read))
        }
        return samples
    }

    private static func rms(_ samples: [Float], from: Double, to: Double) -> Float {
        let a = min(samples.count, Int(from * sampleRate))
        let b = min(samples.count, Int(to * sampleRate))
        guard b > a else { return 0 }
        let soma = samples[a..<b].reduce(Float(0)) { $0 + $1 * $1 }
        return (soma / Float(b - a)).squareRoot()
    }

    @Test("Regenera a faixa limpa: o eco sai, a voz do usuário fica, e nada mais é tocado")
    func regeneratesCleanTrackWithoutTouchingTranscript() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("voiz-regen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let audio = Self.buildAudio()
        let micURL = dir.appendingPathComponent("microphone.caf")
        let systemURL = dir.appendingPathComponent("system-audio.caf")
        try Self.write(audio.mic, to: micURL)
        try Self.write(audio.system, to: systemURL)

        let result = MeetingEchoReconciler().regenerateCleanMic(
            micURL: micURL, systemURL: systemURL,
            outputDirectory: dir, cleanMicFileName: "microphone-clean.caf"
        )

        #expect(result.cleanMicFileName == "microphone-clean.caf")
        #expect(result.gatedSeconds > 5)   // o trecho de eco tem 10 s

        let clean = try Self.read(dir.appendingPathComponent("microphone-clean.caf"))
        #expect(clean.count == audio.mic.count)

        // O eco foi silenciado…
        #expect(Self.rms(clean, from: 11, to: 19) < 1e-4)
        // …e a voz do usuário sobre o outro falando (fala junto, não eco) continua lá.
        let vozAntes = Self.rms(audio.mic, from: 31, to: 39)
        let vozDepois = Self.rms(clean, from: 31, to: 39)
        #expect(vozDepois > vozAntes * 0.9)

        // O original nunca é tocado: é dele que uma segunda regeneração tem que partir.
        let micDepois = try Self.read(micURL)
        #expect(micDepois == audio.mic)
    }

    @Test("Com fone (sem eco) nada é escrito e o arquivo anterior fica onde está")
    func keepsPreviousFileWhenThereIsNoEcho() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("voiz-regen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Fone: os dois falam ao mesmo tempo, e o mic NÃO carrega cópia do system em atraso nenhum.
        // (Trocar os dois arquivos de lugar não serviria: a correlação continua lá, só muda de
        // sinal, e a busca de atraso é simétrica.)
        let n = Int(Self.sampleRate) * Self.totalSeconds
        var mic = [Float](repeating: 0, count: n)
        var system = [Float](repeating: 0, count: n)
        var micNoise = Noise(seed: 7)
        var systemNoise = Noise(seed: 99)
        for i in 0..<n where Self.echoRange.contains(Double(i) / Self.sampleRate) {
            mic[i] = micNoise.next() * 0.3
            system[i] = systemNoise.next() * 0.3
        }
        let micURL = dir.appendingPathComponent("microphone.caf")
        let systemURL = dir.appendingPathComponent("system-audio.caf")
        try Self.write(mic, to: micURL)
        try Self.write(system, to: systemURL)

        let cleanURL = dir.appendingPathComponent("microphone-clean.caf")
        try Self.write([Float](repeating: 0.5, count: 1_000), to: cleanURL)

        let result = MeetingEchoReconciler().regenerateCleanMic(
            micURL: micURL, systemURL: systemURL,
            outputDirectory: dir, cleanMicFileName: "microphone-clean.caf"
        )

        #expect(result.cleanMicFileName == nil)
        #expect(result.gatedSeconds == 0)
        // O que já estava lá continua intacto — regeneração que não sabe o que fazer não apaga nada.
        let anterior = try Self.read(cleanURL)
        #expect(anterior.count == 1_000)
    }
}
