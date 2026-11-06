import AVFoundation
import Foundation
import Testing

/// A ponte REAL leitor → plano de cortes → fila de adiados → EOF.
///
/// Os testes dirigidos do `MeetingBatchCutPlan` verificam a decisão; nenhum
/// deles atravessa o `nextBatch`. Com o corte interno e o `crossesBoundary`
/// desligados DENTRO do leitor, aquelas verificações continuavam verdes — ou
/// seja, a regressão que torna o O2 inerte passava batido. Aqui roda o leitor
/// de verdade, sobre um `.caf` de verdade.
@Suite("Leitor de lotes — cortes de falante ponta a ponta")
struct MeetingBatchReaderCutsTests {

    static let sampleRate: Double = 16_000
    /// O leitor lê em blocos de 4096 e descarta a cauda com menos de 4000
    /// frames (piso de ~250 ms herdado do flush da captura). O fixture usa um
    /// múltiplo de 4096 para que NADA seja descartado por esse piso — senão o
    /// teste mediria aquela regra, não os cortes.
    static let frameBlock = 4_096

    /// Rampa audível e determinística: cada amostra é única dentro do arquivo,
    /// então a concatenação dos lotes pode ser comparada elemento a elemento.
    /// RMS bem acima do limiar de audibilidade (0,003).
    private static func makeSamples(blocks: Int) -> [Float] {
        let count = blocks * frameBlock
        return (0..<count).map { index in
            0.5 + Float(index) / Float(count) * 0.4
        }
    }

    private static func duration(ofBlocks blocks: Int) -> TimeInterval {
        Double(blocks * frameBlock) / sampleRate
    }

    private static func writeCAF(_ samples: [Float], to url: URL, sampleRate: Double = 16_000) throws {
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
        )
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        )
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData?[0].update(from: source.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
    }

    private func makeReader(
        source: MeetingCaptureSource,
        url: URL,
        boundaries: [TimeInterval]
    ) throws -> MeetingRecordedAudioBatchReader {
        try MeetingRecordedAudioBatchReader(
            source: source,
            url: url,
            chunkSeconds: 3,
            maxBatchSeconds: 28,
            gapTolerance: 0.6,
            audibleThreshold: 0.003,
            speakerBoundaries: boundaries
        )
    }

    private func drain(_ reader: MeetingRecordedAudioBatchReader) async throws -> [MeetingAudioChunk] {
        var batches: [MeetingAudioChunk] = []
        while let batch = try await reader.nextBatch() {
            batches.append(batch)
        }
        return batches
    }

    @Test("Sem cortes: um lote só, com o arquivo inteiro e na ordem")
    func withoutCutsTheWholeFileIsOneBatch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("audio.caf")
        let samples = Self.makeSamples(blocks: 46)
        try Self.writeCAF(samples, to: url)

        let batches = try await drain(makeReader(source: .microphone, url: url, boundaries: []))
        // `#require` antes de indexar: com a contagem errada, `#expect` não
        // interrompe e o `batches[0]` seguinte derruba o PROCESSO — levando
        // junto os testes concorrentes e trocando 6 issues legíveis por um
        // rc=65 sem diagnóstico.
        try #require(batches.count == 1)
        #expect(batches[0].startTime == 0)
        #expect(abs(batches[0].endTime - Self.duration(ofBlocks: 46)) < 0.001)
        #expect(batches[0].samples.count == samples.count)
        #expect(
            batches[0].samples.elementsEqual(samples),
            "sem corte o lote é o arquivo inteiro, sem perder nem reordenar"
        )
    }

    @Test("Cortes atravessam o nextBatch: fronteiras exatas, amostras exatas, nos DOIS canais")
    func cutsCrossTheReaderForBothSources() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("audio.caf")
        let samples = Self.makeSamples(blocks: 46)
        try Self.writeCAF(samples, to: url)

        // 4,5 cai dentro do 2º chunk; 7,5 e 8,25 caem DOIS no mesmo 3º chunk —
        // é o caso que a fila de adiados existe para atender.
        let boundaries: [TimeInterval] = [4.5, 7.5, 8.25]

        for source in [MeetingCaptureSource.microphone, .systemAudio] {
            let batches = try await drain(makeReader(source: source, url: url, boundaries: boundaries))

            try #require(batches.count == 4, "\(source): um lote por trecho entre cortes")
            let starts = batches.map { ($0.startTime * 100).rounded() / 100 }
            let ends = batches.map { ($0.endTime * 100).rounded() / 100 }
            #expect(starts == [0, 4.5, 7.5, 8.25], "\(source): os lotes começam nos cortes")
            let last = (Self.duration(ofBlocks: 46) * 100).rounded() / 100
            #expect(ends == [4.5, 7.5, 8.25, last], "\(source): e terminam no corte seguinte")
            #expect(
                batches.allSatisfy { $0.source == source },
                "o lote sai carimbado com o canal do leitor"
            )

            // Concatenação EXATA: nada perdido, nada duplicado, nada fora de ordem.
            let joined = batches.flatMap(\.samples)
            #expect(joined.count == samples.count, "\(source): nenhuma amostra some nem duplica")
            #expect(joined.elementsEqual(samples), "\(source): concatenação idêntica ao arquivo")
            for batch in batches {
                let from = Int((batch.startTime * Self.sampleRate).rounded())
                let to = Int((batch.endTime * Self.sampleRate).rounded())
                #expect(
                    batch.samples.elementsEqual(samples[from..<to]),
                    "\(source): cada lote é exatamente a fatia do seu intervalo"
                )
            }
        }
    }

    @Test("Corte em 0 e corte no fim do arquivo não criam lote vazio")
    func cutsAtTheEdgesAreNoOps() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("audio.caf")
        let samples = Self.makeSamples(blocks: 34)
        try Self.writeCAF(samples, to: url)

        let batches = try await drain(
            makeReader(
                source: .microphone,
                url: url,
                boundaries: [0, Self.duration(ofBlocks: 34), 12]
            )
        )
        try #require(batches.count == 1, "corte na borda não parte nada")
        #expect(batches[0].samples.elementsEqual(samples))
        #expect(batches.allSatisfy { !$0.samples.isEmpty }, "nenhum lote vazio sai do leitor")
    }

    @Test("EOF devolve o lote aberto e drena a fila de adiados")
    func endOfFileDrainsTheOpenBatch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("audio.caf")
        let samples = Self.makeSamples(blocks: 34)
        try Self.writeCAF(samples, to: url)

        // Último corte já dentro do ÚLTIMO chunk: o pedaço final só sai se o
        // EOF devolver o lote aberto depois de drenar a cauda adiada.
        let reader = try makeReader(source: .systemAudio, url: url, boundaries: [7.5])
        let batches = try await drain(reader)

        try #require(batches.count == 2)
        #expect(abs(batches[0].endTime - 7.5) < 0.001)
        #expect(abs(batches[1].startTime - 7.5) < 0.001)
        #expect(abs(batches[1].endTime - Self.duration(ofBlocks: 34)) < 0.001)
        #expect(
            batches.flatMap(\.samples).elementsEqual(samples),
            "a cauda depois do último corte não pode sumir no EOF"
        )
        #expect(try await reader.nextBatch() == nil, "depois do EOF não sobra nada na fila")
    }
}
