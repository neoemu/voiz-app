import AVFoundation
import Accelerate
import Combine

class AudioCaptureService: NSObject, ObservableObject {
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private let recordingBuffer: RecordingSampleBuffer
    private let processingLock = NSLock()
    
    @Published var isRecording = false
    @Published var audioLevel: Float = 0.0

    /// Instâncias (ditado/tradução) com o mic aberto agora. O detector de reuniões usa isso
    /// pra não confundir a captura do próprio Voiz com uma chamada de Teams/Meet/Zoom.
    private(set) static var activeInstances = 0
    
    var onAudioData: (([Float]) -> Void)?
    var onRecordingFinished: (([Float]) -> Void)?
    
    init(retention: RecordingSampleBuffer.Retention = .latestSamples(16000 * 30)) {
        recordingBuffer = RecordingSampleBuffer(retention: retention)
        print("🎤 AudioCaptureService init started")
        super.init()
        setupAudioSession()
        print("✅ AudioCaptureService init completed")
    }
    
    private func setupAudioSession() {
        audioEngine = AVAudioEngine()
        inputNode = audioEngine?.inputNode
    }
    
    func startRecording() throws {
        guard let audioEngine = audioEngine,
              let inputNode = inputNode else {
            throw AudioCaptureError.engineNotInitialized
        }
        
        guard !isRecording else { return }
        
        // Get the input node's current format
        let inputFormat = inputNode.outputFormat(forBus: 0)
        print("🎤 Input format: \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) channels")
        
        // Check if we need to set a specific format
        guard let recordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: AVAudioChannelCount(1),
            interleaved: false
        ) else {
            throw AudioCaptureError.formatNotSupported
        }
        
        print("🎤 Recording format: \(recordingFormat.sampleRate) Hz, \(recordingFormat.channelCount) channels")
        
        // Create 16kHz target format for conversion
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioCaptureError.formatNotSupported
        }
        
        let generation = recordingBuffer.begin()
        // Install tap with recording format
        inputNode.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: recordingFormat
        ) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer, targetFormat: targetFormat, generation: generation)
        }
        
        // Start the audio engine
        do {
            try audioEngine.start()
            isRecording = true
            Self.activeInstances += 1
            print("✅ Recording started, engine running: \(audioEngine.isRunning)")
        } catch {
            inputNode.removeTap(onBus: 0)
            _ = recordingBuffer.finish()
            print("❌ Failed to start audio engine: \(error)")
            throw error
        }
    }
    
    func stopRecording() {
        guard isRecording else { return }
        audioEngine?.stop()
        inputNode?.removeTap(onBus: 0)
        if isRecording { Self.activeInstances -= 1 }
        isRecording = false
        audioLevel = 0.0
        
        // Drain an in-flight tap before finishing: its last word belongs to this recording.
        let buffer = processingLock.withLock { recordingBuffer.finish() }
        
        let handler = onRecordingFinished
        DispatchQueue.global(qos: .userInitiated).async {
            handler?(buffer)
        }
    }
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat, generation: UUID) {
        processingLock.lock()
        defer { processingLock.unlock() }
        guard let channelData = buffer.floatChannelData?[0] else { 
            print("❌ No channel data in buffer")
            return 
        }
        let frameLength = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))
        
        // Convert to 16kHz if needed
        let convertedSamples: [Float]
        if buffer.format.sampleRate != targetFormat.sampleRate {
            convertedSamples = resample(samples, from: buffer.format.sampleRate, to: targetFormat.sampleRate)
        } else {
            convertedSamples = samples
        }
        
        guard recordingBuffer.append(convertedSamples, generation: generation) else { return }
        
        updateAudioLevel(samples: samples)
        
        // Send audio data in realtime for streaming processing
        if let handler = onAudioData {
            DispatchQueue.global(qos: .userInitiated).async {
                handler(convertedSamples)
            }
        }
    }
    
    private func resample(_ samples: [Float], from sourceSampleRate: Double, to targetSampleRate: Double) -> [Float] {
        let ratio = targetSampleRate / sourceSampleRate
        let outputLength = Int(Double(samples.count) * ratio)
        var output = [Float](repeating: 0, count: outputLength)
        
        for i in 0..<outputLength {
            let sourceIndex = Double(i) / ratio
            let index = Int(sourceIndex)
            let fraction = Float(sourceIndex - Double(index))
            
            if index + 1 < samples.count {
                output[i] = samples[index] * (1.0 - fraction) + samples[index + 1] * fraction
            } else if index < samples.count {
                output[i] = samples[index]
            }
        }
        
        return output
    }
    
    private func updateAudioLevel(samples: [Float]) {
        var rms: Float = 0.0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        
        DispatchQueue.main.async {
            self.audioLevel = rms
        }
    }
    
    func getAudioBuffer() -> [Float] {
        return recordingBuffer.snapshot()
    }
    
    enum AudioCaptureError: Error {
        case engineNotInitialized
        case formatNotSupported
        case permissionDenied
    }
}
