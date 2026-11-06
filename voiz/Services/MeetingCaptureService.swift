import AVFoundation
import Accelerate
import Combine
import CoreGraphics
import CoreMedia
import ScreenCaptureKit

final class MeetingCaptureService: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var microphoneLevel: Float = 0
    @Published private(set) var systemAudioLevel: Float = 0

    var onAudioChunk: ((MeetingAudioChunk) -> Void)?
    /// Áudio bruto POR FONTE (16kHz mono) para a prévia ao vivo — emitido na fila de
    /// captura conforme chega. Nunca misture as fontes num stream só: com alto-falante a
    /// mesma fala existe nas duas (direta no sistema + eco no mic) e a soma defasada vira
    /// áudio embolado que degrada o ASR. A prévia escolhe a fonte dominante do momento.
    var onPreviewAudio: ((MeetingCaptureSource, [Float]) -> Void)?

    private let sampleRate: Double = 16000
    // Chunk de 3s mantido para consumidores opcionais de `onAudioChunk`. O fluxo normal
    // de reuniões grava direto nos .caf e recria esses chunks no pós-call.
    private let chunkSampleCount = 16000 * 3
    private let captureQueue = DispatchQueue(label: "voiz.meeting.capture.queue", qos: .userInitiated)

    private var microphoneEngine: AVAudioEngine?
    private var microphoneInputNode: AVAudioInputNode?
    private var systemStream: SCStream?
    private var sessionStartedAt = Date()

    private var microphoneChunkBuffer: [Float] = []
    private var systemChunkBuffer: [Float] = []
    private var samplesWrittenBySource: [MeetingCaptureSource: Int] = [:]
    /// A captura de hardware continua ligada durante o pause, mas `consume` descarta os
    /// buffers. Assim retomar é instantâneo e o intervalo não entra nos arquivos.
    private var captureIsPaused = false

    private var audioFiles: [MeetingCaptureSource: AVAudioFile] = [:]
    private var audioFileNames: [MeetingCaptureSource: String] = [:]

    func startRecording(sessionDirectory: URL, store: MeetingSessionStore) async throws -> MeetingCaptureStartResult {
        stopLocalState()

        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        sessionStartedAt = Date()
        captureIsPaused = false
        samplesWrittenBySource = [:]
        microphoneChunkBuffer = []
        systemChunkBuffer = []
        audioFiles = [:]
        audioFileNames = [:]

        try prepareAudioFile(for: .microphone, in: sessionDirectory, store: store)
        try prepareAudioFile(for: .systemAudio, in: sessionDirectory, store: store)

        try startMicrophoneCapture()
        let systemWarning = await startSystemAudioCapture()

        DispatchQueue.main.async {
            self.isRecording = true
            self.isPaused = false
        }

        return MeetingCaptureStartResult(audioFiles: audioFileNames, systemAudioWarning: systemWarning)
    }

    func stopRecording() async -> [MeetingAudioChunk] {
        microphoneEngine?.stop()
        microphoneInputNode?.removeTap(onBus: 0)
        microphoneEngine = nil
        microphoneInputNode = nil

        if let systemStream {
            await stopSystemStream(systemStream)
        }
        systemStream = nil

        let remaining = captureQueue.sync {
            var chunks: [MeetingAudioChunk] = []
            if let chunk = flushChunk(for: .microphone) {
                chunks.append(chunk)
            }
            if let chunk = flushChunk(for: .systemAudio) {
                chunks.append(chunk)
            }
            captureIsPaused = false
            audioFiles = [:]
            return chunks
        }

        DispatchQueue.main.async {
            self.isRecording = false
            self.isPaused = false
            self.microphoneLevel = 0
            self.systemAudioLevel = 0
        }

        return remaining
    }

    /// Pausa/retoma sem desmontar AVAudioEngine e SCStream. Se houver um consumidor
    /// opcional de chunks, ao pausar devolve os fragmentos anteriores ao corte.
    /// Os timestamps continuam no tempo útil do áudio.
    @MainActor
    func setPaused(_ paused: Bool) -> [MeetingAudioChunk] {
        let remaining: [MeetingAudioChunk] = captureQueue.sync {
            guard captureIsPaused != paused else { return [] }
            captureIsPaused = paused
            guard paused else { return [] }

            var chunks: [MeetingAudioChunk] = []
            if let chunk = flushChunk(for: .microphone) {
                chunks.append(chunk)
            }
            if let chunk = flushChunk(for: .systemAudio) {
                chunks.append(chunk)
            }
            return chunks
        }

        isPaused = paused
        if paused {
            microphoneLevel = 0
            systemAudioLevel = 0
        }
        return remaining
    }

    private func stopLocalState() {
        microphoneEngine?.stop()
        microphoneInputNode?.removeTap(onBus: 0)
        microphoneEngine = nil
        microphoneInputNode = nil
        systemStream = nil
        captureIsPaused = false
        audioFiles = [:]
        audioFileNames = [:]
        DispatchQueue.main.async {
            self.isRecording = false
            self.isPaused = false
            self.microphoneLevel = 0
            self.systemAudioLevel = 0
        }
    }

    private func prepareAudioFile(for source: MeetingCaptureSource, in directory: URL, store: MeetingSessionStore) throws {
        let filename = store.audioFileName(for: source)
        let url = directory.appendingPathComponent(filename)
        let format = canonicalFormat()
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        audioFiles[source] = file
        audioFileNames[source] = filename
    }

    private func startMicrophoneCapture() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let recordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw MeetingCaptureError.microphoneUnavailable
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let samples = self.floatSamples(from: buffer)
            self.captureQueue.async {
                let normalized = self.normalize(samples, from: buffer.format.sampleRate)
                self.consume(samples: normalized, source: .microphone)
            }
        }

        try engine.start()
        microphoneEngine = engine
        microphoneInputNode = inputNode
    }

    private func startSystemAudioCapture() async -> String? {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            return String(localized: "Sem permissão de Gravação de Tela. A voz dos participantes não será gravada.")
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                return String(localized: "Nenhum display disponível para capturar áudio do sistema.")
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            if #available(macOS 14.2, *) {
                filter.includeMenuBar = false
            }

            let configuration = SCStreamConfiguration()
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.showsCursor = false
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = Int(sampleRate)
            configuration.channelCount = 1

            let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
            try await startSystemStream(stream)
            systemStream = stream
            return nil
        } catch {
            return String(localized: "Sem áudio do sistema. Gravando só o microfone.")
        }
    }

    private func startSystemStream(_ stream: SCStream) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.startCapture { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func stopSystemStream(_ stream: SCStream) async {
        await withCheckedContinuation { continuation in
            stream.stopCapture { _ in
                continuation.resume()
            }
        }
    }

    private func consume(samples: [Float], source: MeetingCaptureSource) {
        guard !captureIsPaused, !samples.isEmpty else { return }

        write(samples: samples, source: source)
        updateLevel(samples: samples, source: source)

        // O transcript oficial de reuniões é feito dos .caf no pós-call. Só mantemos
        // buffers de chunks se algum consumidor pedir explicitamente `onAudioChunk`;
        // no fluxo normal isso evita alocações e cópias de áudio que seriam descartadas.
        if onAudioChunk != nil {
            switch source {
            case .microphone:
                microphoneChunkBuffer.append(contentsOf: samples)
                emitReadyChunks(for: .microphone)
            case .systemAudio:
                systemChunkBuffer.append(contentsOf: samples)
                emitReadyChunks(for: .systemAudio)
            }
        }

        onPreviewAudio?(source, samples)
    }

    private func emitReadyChunks(for source: MeetingCaptureSource) {
        while buffer(for: source).count >= chunkSampleCount {
            let chunkSamples = Array(buffer(for: source).prefix(chunkSampleCount))
            removeFirstSamples(chunkSampleCount, for: source)
            emitChunk(samples: chunkSamples, source: source)
        }
    }

    private func flushChunk(for source: MeetingCaptureSource) -> MeetingAudioChunk? {
        let currentBuffer = buffer(for: source)
        guard currentBuffer.count >= 4000 else {
            setBuffer([], for: source)
            return nil
        }

        setBuffer([], for: source)
        return makeChunk(samples: currentBuffer, source: source)
    }

    private func emitChunk(samples: [Float], source: MeetingCaptureSource) {
        guard let chunk = makeChunk(samples: samples, source: source) else { return }
        DispatchQueue.main.async {
            self.onAudioChunk?(chunk)
        }
    }

    private func makeChunk(samples: [Float], source: MeetingCaptureSource) -> MeetingAudioChunk? {
        guard !samples.isEmpty else { return nil }
        let written = samplesWrittenBySource[source, default: 0]
        let end = Double(written) / sampleRate
        let start = max(0, end - Double(samples.count) / sampleRate)
        return MeetingAudioChunk(source: source, samples: samples, startTime: start, endTime: end)
    }

    private func write(samples: [Float], source: MeetingCaptureSource) {
        guard let file = audioFiles[source],
              let buffer = makePCMBuffer(samples: samples) else {
            return
        }

        do {
            try file.write(from: buffer)
            samplesWrittenBySource[source, default: 0] += samples.count
        } catch {
            print("❌ Failed to write \(source.displayName) audio: \(error)")
        }
    }

    private func updateLevel(samples: [Float], source: MeetingCaptureSource) {
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))

        DispatchQueue.main.async {
            switch source {
            case .microphone:
                self.microphoneLevel = rms
            case .systemAudio:
                self.systemAudioLevel = rms
            }
        }
    }

    private func floatSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
    }

    private func floatSamples(from sampleBuffer: CMSampleBuffer) -> [Float] {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return []
        }

        var audioBufferList = AudioBufferList()
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else { return [] }

        let asbd = streamDescription.pointee
        let bufferList = UnsafeMutableAudioBufferListPointer(&audioBufferList)
        var samples: [Float] = []

        for audioBuffer in bufferList {
            guard let data = audioBuffer.mData else { continue }
            let byteCount = Int(audioBuffer.mDataByteSize)

            if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
                let count = byteCount / MemoryLayout<Float>.size
                let values = data.bindMemory(to: Float.self, capacity: count)
                samples.append(contentsOf: UnsafeBufferPointer(start: values, count: count))
            } else if asbd.mBitsPerChannel == 16 {
                let count = byteCount / MemoryLayout<Int16>.size
                let values = data.bindMemory(to: Int16.self, capacity: count)
                samples.append(contentsOf: UnsafeBufferPointer(start: values, count: count).map { Float($0) / Float(Int16.max) })
            }
        }

        return normalize(samples, from: asbd.mSampleRate)
    }

    private func normalize(_ samples: [Float], from sourceSampleRate: Double) -> [Float] {
        guard !samples.isEmpty else { return [] }
        guard abs(sourceSampleRate - sampleRate) > 1 else { return samples }
        return resample(samples, from: sourceSampleRate, to: sampleRate)
    }

    private func resample(_ samples: [Float], from sourceSampleRate: Double, to targetSampleRate: Double) -> [Float] {
        let ratio = targetSampleRate / sourceSampleRate
        let outputLength = max(1, Int(Double(samples.count) * ratio))
        var output = [Float](repeating: 0, count: outputLength)

        for index in 0..<outputLength {
            let sourceIndex = Double(index) / ratio
            let lower = Int(sourceIndex)
            let fraction = Float(sourceIndex - Double(lower))

            if lower + 1 < samples.count {
                output[index] = samples[lower] * (1 - fraction) + samples[lower + 1] * fraction
            } else if lower < samples.count {
                output[index] = samples[lower]
            }
        }

        return output
    }

    private func canonicalFormat() -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    }

    private func makePCMBuffer(samples: [Float]) -> AVAudioPCMBuffer? {
        let format = canonicalFormat()
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        buffer.floatChannelData?[0].update(from: samples, count: samples.count)
        return buffer
    }

    private func buffer(for source: MeetingCaptureSource) -> [Float] {
        switch source {
        case .microphone:
            return microphoneChunkBuffer
        case .systemAudio:
            return systemChunkBuffer
        }
    }

    private func setBuffer(_ samples: [Float], for source: MeetingCaptureSource) {
        switch source {
        case .microphone:
            microphoneChunkBuffer = samples
        case .systemAudio:
            systemChunkBuffer = samples
        }
    }

    private func removeFirstSamples(_ count: Int, for source: MeetingCaptureSource) {
        switch source {
        case .microphone:
            microphoneChunkBuffer.removeFirst(min(count, microphoneChunkBuffer.count))
        case .systemAudio:
            systemChunkBuffer.removeFirst(min(count, systemChunkBuffer.count))
        }
    }

    enum MeetingCaptureError: Error, LocalizedError {
        case microphoneUnavailable

        var errorDescription: String? {
            switch self {
            case .microphoneUnavailable:
                return String(localized: "Microfone indisponível")
            }
        }
    }
}

extension MeetingCaptureService: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        let samples = floatSamples(from: sampleBuffer)
        consume(samples: samples, source: .systemAudio)
    }
}
