import Testing
import Foundation
import AVFoundation

/// Eco da caixa de som numa sala com ruído de fundo.
///
/// Medido no Voiz Dev (11/10/2026): com o mic captando o ambiente, o eco chegava com atraso estável
/// (−211 ms, 93% das janelas concordando em ±12 ms), mas a correlação caía. A passada 1 exigia 3
/// janelas com NCC ≥ 0,60 e concluía "provável fone" mesmo quando havia janelas de eco acima do
/// limiar da passada 2 (0,42). O consenso de atraso acha o eco nesses casos; cada janela continua
/// sendo decidida só pela NCC alta — evidência mais fraca que ela apagava fala do usuário nas
/// revisões do PR #71 e ficou de fora.
///
/// O áudio aqui é sintético e determinístico, como em `MeetingCleanAudioRegenerationTests`: ruído no
/// "system", e um mic com ruído de sala estacionário somado a uma cópia atrasada do system. A
/// proporção dá NCC ≈ 0,5 nas janelas de eco: acima de 0,42, abaixo das âncoras de 0,60.
@Suite("Reunião — eco em sala com ruído")
struct MeetingEchoNoisyRoomTests {

    private static let sampleRate: Double = 16_000
    private static let totalSeconds = 40
    private static let systemRange = 4.0..<30.0       // o outro lado falando
    private static let lagSamples = 3_360             // 210 ms, como na gravação medida
    private static let lagSeconds = 0.21
    private static let roomNoise: Float = 0.1         // ruído estacionário do ambiente no mic
    private static let echoGain: Float = 0.1925       // NCC ≈ 0,5 contra o ruído

    private static let remoteText = "orçamento aprovado pela diretoria revisão do protótipo até sexta demonstração "
        + "para segunda lançamento mantido no fim do mês próxima revisão marcada na quarta"

    /// Uniforme em [−1, 1]: simétrico como áudio de verdade. (Com `>> 33` o valor sai só positivo,
    /// e o nível constante distorce as proporções de energia que estes testes calibram.)
    private struct Noise {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int32(truncatingIfNeeded: state >> 32)) / Float(Int32.max)
        }
    }

    // MARK: - Áudio

    /// `userSpeech`: trecho em que o usuário fala junto. `echoUntil`: a partir daí não há mais eco,
    /// como quem põe o fone no meio da reunião.
    private static func noisyRoom(echo: Bool, userSpeech: Range<Double>? = nil,
                                  echoUntil: Double = .infinity) -> (mic: [Float], system: [Float]) {
        let n = Int(sampleRate) * totalSeconds
        var system = [Float](repeating: 0, count: n)
        var mic = [Float](repeating: 0, count: n)
        var systemNoise = Noise(seed: 7)
        var room = Noise(seed: 77)
        var user = Noise(seed: 777)

        for i in 0..<n {
            let t = Double(i) / sampleRate
            if systemRange.contains(t) { system[i] = systemNoise.next() * 0.3 }
            mic[i] = room.next() * roomNoise
            if let userSpeech, userSpeech.contains(t) { mic[i] += user.next() * 0.3 }
        }
        if echo {
            let end = echoUntil.isFinite ? min(n, Int(echoUntil * sampleRate)) : n
            for i in lagSamples..<end { mic[i] += system[i - lagSamples] * echoGain }
        }
        return (mic, system)
    }

    private static let remoteSegments: [Range<Double>] = [4..<8, 12..<16, 20..<24, 28..<32]
    private static let localRanges: [Range<Double>] = [0..<4, 8..<12, 16..<20, 24..<28, 32..<40]
    private static let doubleTalk = 20.0..<24.0

    /// Conversa alternada numa sala silenciosa, com caixa de som: o usuário fala em toda pausa do
    /// outro lado e uma vez junto com ele, no mesmo volume. A fala é ruído recortado em sílabas
    /// (180 ms com som, 70 ms de pausa).
    private static func alternatingConversation() -> (mic: [Float], system: [Float]) {
        let n = Int(sampleRate) * totalSeconds
        var system = [Float](repeating: 0, count: n)
        var mic = [Float](repeating: 0, count: n)
        var systemNoise = Noise(seed: 11)
        var room = Noise(seed: 111)
        var user = Noise(seed: 1_111)
        let local = localRanges + [doubleTalk]
        for i in 0..<n {
            let t = Double(i) / sampleRate
            if remoteSegments.contains(where: { $0.contains(t) }) { system[i] = systemNoise.next() * 0.3 }
            mic[i] = room.next() * 0.003
            let syllable = t.truncatingRemainder(dividingBy: 0.25) < 0.18
            if syllable, local.contains(where: { $0.contains(t) }) { mic[i] += user.next() * 0.1 }
        }
        // Eco audível, mas uns 10 dB abaixo da voz do usuário.
        for i in lagSamples..<n { mic[i] += system[i - lagSamples] * 0.089 }
        return (mic, system)
    }

    // MARK: - Turns

    private static func systemTurn(_ text: String, _ range: Range<Double>) -> MeetingTurn {
        MeetingTurn(source: .systemAudio, speakerName: "Participante 1", text: text,
                    startTime: range.lowerBound, endTime: range.upperBound)
    }

    private static func micTurn(_ text: String, _ range: Range<Double>) -> MeetingTurn {
        MeetingTurn(source: .microphone, speakerName: "Você", text: text,
                    startTime: range.lowerBound, endTime: range.upperBound)
    }

    /// A cópia ecoada chega no mic com o atraso do eco.
    private static func echoed(_ range: Range<Double>) -> Range<Double> {
        (range.lowerBound + lagSeconds)..<(range.upperBound + lagSeconds)
    }

    // MARK: - Execução

    private static func write(_ samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                   channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData!.pointee.update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
    }

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

    private static func rms(_ x: ArraySlice<Float>) -> Float {
        (x.reduce(0) { $0 + $1 * $1 } / Float(max(1, x.count))).squareRoot()
    }

    private struct Run {
        var result: MeetingEchoReconciler.Result
        var mic: [Float]
        var clean: [Float]?

        var micTexts: [String] { result.turns.filter { $0.source == .microphone }.map(\.text) }

        /// Quanto do mic a faixa limpa silenciou, em segundos (janelas de 0,5 s com energia ≈ 0).
        var gatedSeconds: Double {
            guard let clean else { return 0 }
            let window = Int(MeetingEchoNoisyRoomTests.sampleRate / 2)
            let silenced = stride(from: 0, to: clean.count - window, by: window).filter { start in
                MeetingEchoNoisyRoomTests.rms(clean[start..<start + window])
                    < MeetingEchoNoisyRoomTests.rms(mic[start..<start + window]) * 0.1
            }
            return Double(silenced.count) / 2
        }
    }

    private static func run(_ audio: (mic: [Float], system: [Float]), turns: [MeetingTurn]) throws -> Run {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("echo-noisy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let micURL = dir.appendingPathComponent("microphone.caf")
        let sysURL = dir.appendingPathComponent("system-audio.caf")
        try write(audio.mic, to: micURL)
        try write(audio.system, to: sysURL)
        let result = MeetingEchoReconciler().reconcile(
            turns: turns, micURL: micURL, systemURL: sysURL, outputDirectory: dir, cleanMicFileName: "microphone-clean.caf"
        )
        let clean = try result.cleanMicFileName.map { try read(dir.appendingPathComponent($0)) }
        return Run(result: result, mic: audio.mic, clean: clean)
    }

    private static func samples(_ range: Range<Double>) -> Range<Int> {
        Int(range.lowerBound * sampleRate)..<Int(range.upperBound * sampleRate)
    }

    /// O áudio do usuário no trecho pedido não foi silenciado (com meio segundo de folga nas bordas).
    private static func audioKept(_ run: Run, in range: Range<Double>) -> Bool {
        guard let clean = run.clean else { return true }   // sem faixa limpa, o player usa o mic inteiro
        let inner = samples((range.lowerBound + 0.5)..<(range.upperBound - 0.5))
        return rms(clean[inner]) > rms(run.mic[inner]) * 0.8
    }

    private static var duplicateTurns: [MeetingTurn] {
        [systemTurn(remoteText, systemRange), micTurn(remoteText, echoed(systemRange))]
    }

    // MARK: - Testes

    @Test("Eco entre 0,42 e 0,60 numa sala ruidosa é reconhecido pelo consenso de atraso")
    func noisyEchoIsDetectedByConsensus() throws {
        let run = try Self.run(Self.noisyRoom(echo: true), turns: Self.duplicateTurns)
        #expect(run.result.note.contains("por consenso"), "\(run.result.note)")
        // O outro lado fala 26 s; quase todo esse trecho é eco no mic.
        #expect(run.gatedSeconds >= 20, "\(run.gatedSeconds) — \(run.result.note)")
        // E o "Você" que só repetia o outro lado sai do transcript.
        #expect(run.micTexts.isEmpty, "\(run.result.note)")
    }

    /// Achado da revisão do PR #71: com o eco em minoria, a mediana de todos os atrasos cai entre
    /// os picos sem relação, e o consenso, que existia, deixava de ser visto. Aqui o eco ocupa
    /// 10 dos 26 s em que o outro lado fala (38% das janelas), acima dos dois limiares do consenso.
    @Test("Eco só em parte da reunião (caixa de som, depois fone) ainda é reconhecido")
    func echoInMinorityOfWindowsIsDetected() throws {
        let run = try Self.run(Self.noisyRoom(echo: true, echoUntil: 14), turns: Self.duplicateTurns)
        #expect(run.result.note.contains("por consenso"), "\(run.result.note)")
        #expect(run.gatedSeconds >= 7 && run.gatedSeconds <= 11, "\(run.gatedSeconds) — \(run.result.note)")
    }

    @Test("Com fone (sem eco) a mesma sala ruidosa não vira eco")
    func headphonesInNoisyRoomStayUntouched() throws {
        let own = "deixa eu conferir minha agenda e depois confirmo o horário"
        let run = try Self.run(Self.noisyRoom(echo: false), turns: [
            Self.systemTurn(Self.remoteText, Self.systemRange),
            Self.micTurn(own, 12..<20),
        ])
        #expect(run.result.note.contains("sem eco detectado"), "\(run.result.note)")
        #expect(run.micTexts == [own])
        #expect(run.clean == nil)
    }

    @Test("Fala do usuário junto com o eco, na sala ruidosa, fica no transcript e no áudio")
    func userSpeechOverNoisyEchoIsKept() throws {
        let speech = 12.0..<20.0
        let own = "deixa eu conferir minha agenda e depois confirmo o horário"
        let run = try Self.run(Self.noisyRoom(echo: true, userSpeech: speech), turns: [
            Self.systemTurn(Self.remoteText, Self.systemRange),
            Self.micTurn(own, speech),
        ])
        #expect(run.micTexts == [own], "\(run.result.note)")
        #expect(Self.audioKept(run, in: speech), "\(run.result.note)")
    }

    /// Guarda contra regressão das revisões do PR #71: numa conversa alternada, a resposta do
    /// usuário pode ser subsequência do outro lado e dizer o contrário. Só a NCC alta decide uma
    /// janela, e a fala junto (NCC ≈ 0,3) não passa dela.
    @Test("Conversa alternada: a resposta oposta junto com o eco fica (\"não podemos\" × \"podemos\")")
    func alternatingConversationKeepsOppositeReply() throws {
        var turns = Self.remoteSegments.enumerated().map { index, range in
            range == Self.doubleTalk
                ? Self.systemTurn("não podemos aprovar essa proposta hoje", range)
                : Self.systemTurn("assunto \(index) do outro lado com palavras próprias deste trecho", range)
        }
        let localTexts = ["sim eu vou ver", "tá bom", "uhum certo", "ok pode ser", "beleza então"]
        turns += zip(localTexts, Self.localRanges).map { Self.micTurn($0.0, $0.1) }
        turns.append(Self.micTurn("podemos aprovar essa proposta hoje", Self.doubleTalk))
        let run = try Self.run(Self.alternatingConversation(), turns: turns)
        #expect(run.micTexts.contains("podemos aprovar essa proposta hoje"), "\(run.result.note)")
        #expect(run.micTexts.count == localTexts.count + 1, "\(run.micTexts)")
        #expect(Self.audioKept(run, in: Self.doubleTalk), "\(run.result.note)")
    }
}
