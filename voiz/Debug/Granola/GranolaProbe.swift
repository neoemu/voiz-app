#if DEBUG
import Darwin
import Foundation

/// Sonda headless do motor Granola.
///
/// A saída mede o comportamento do streaming sem ecoar transcript: cada evento informa apenas
/// canal, tipo, contagem de caracteres e janela no relógio da captura. O arquivo de entrada é
/// carregado por `BenchmarkAudioLoader`, portanto WAV e CAF passam pela mesma normalização mono
/// Float32/16 kHz usada pelas sondas existentes.
///
/// Uso:
///   --voiz-granola-probe --voiz-granola-probe-audio <wav-ou-caf> [--voiz-granola-probe-exit]
///   --voiz-granola-probe --voiz-granola-probe-mic <segundos> [--voiz-granola-probe-exit]
///   --voiz-granola-probe-channels <microphone|systemAudio|both> (padrão: both)
///
/// O modo arquivo alimenta o mesmo áudio nas sessões selecionadas, sem misturar os canais. O
/// modo microfone abre somente a entrada do microfone (sem persistir áudio) e duplica cada
/// fragmento nos canais selecionados, para exercitar o contrato antes da UI existir.
nonisolated struct GranolaProbeOptions: Sendable, Equatable {
    var audioPath: String?
    var microphoneSeconds: Double?
    var channels: Set<MeetingLiveAudioChannel>
    var chunkSeconds: Double
    var realtime: Bool
    var shouldExit: Bool

    static func parse(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> GranolaProbeOptions? {
        guard arguments.contains("--voiz-granola-probe") else { return nil }
        return GranolaProbeOptions(
            audioPath: value(of: "--voiz-granola-probe-audio", in: arguments),
            microphoneSeconds: positiveDouble(
                value(of: "--voiz-granola-probe-mic", in: arguments)
            ),
            channels: parseChannels(
                value(of: "--voiz-granola-probe-channels", in: arguments)
            ),
            chunkSeconds: positiveDouble(
                value(of: "--voiz-granola-probe-chunk", in: arguments)
            ) ?? 0.25,
            realtime: !arguments.contains("--voiz-granola-probe-burst"),
            shouldExit: arguments.contains("--voiz-granola-probe-exit")
        )
    }

    private static func value(of flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let next = arguments.index(after: index)
        guard next < arguments.endIndex else { return nil }
        return arguments[next]
    }

    private static func positiveDouble(_ value: String?) -> Double? {
        guard let value, let number = Double(value), number.isFinite, number > 0 else {
            return nil
        }
        return number
    }

    private static func parseChannels(_ value: String?) -> Set<MeetingLiveAudioChannel> {
        switch value?.lowercased() ?? "both" {
        case "microphone":
            return [.microphone]
        case "systemaudio":
            return [.systemAudio]
        case "both":
            return Set(MeetingLiveAudioChannel.allCases)
        default:
            return []
        }
    }
}

private struct GranolaProbeMicPacket: Sendable {
    let samples: [Float]
    let capturedAt: Date
}

private struct GranolaProbeMetricsSnapshot: Sendable {
    let firstVolatileAt: [MeetingLiveAudioChannel: Double]
    let volatileCount: [MeetingLiveAudioChannel: Int]
    let finalCount: [MeetingLiveAudioChannel: Int]
    let volatileCharacters: [MeetingLiveAudioChannel: Int]
    let finalCharacters: [MeetingLiveAudioChannel: Int]
    let volatileIntervals: [MeetingLiveAudioChannel: [Double]]
    let failures: [MeetingLiveAudioChannel: Int]
}

/// Serializa o relatório dos eventos sem deixar texto reconhecido atravessar o log.
private actor GranolaProbeEventRecorder {
    private let startedAt: Date
    private var firstVolatileAt: [MeetingLiveAudioChannel: Double] = [:]
    private var volatileCount: [MeetingLiveAudioChannel: Int] = [:]
    private var finalCount: [MeetingLiveAudioChannel: Int] = [:]
    private var volatileCharacters: [MeetingLiveAudioChannel: Int] = [:]
    private var finalCharacters: [MeetingLiveAudioChannel: Int] = [:]
    private var volatileIntervals: [MeetingLiveAudioChannel: [Double]] = [:]
    private var lastVolatileAt: [MeetingLiveAudioChannel: Double] = [:]
    private var failures: [MeetingLiveAudioChannel: Int] = [:]

    init(startedAt: Date) {
        self.startedAt = startedAt
    }

    func record(
        _ event: MeetingLiveTranscriptionEvent,
        source: String
    ) {
        let wallTime = Date().timeIntervalSince(startedAt)
        switch event {
        case let .volatile(text, channel, window):
            if let previous = lastVolatileAt[channel] {
                volatileIntervals[channel, default: []].append(wallTime - previous)
            } else {
                firstVolatileAt[channel] = wallTime
            }
            lastVolatileAt[channel] = wallTime
            volatileCount[channel, default: 0] += 1
            volatileCharacters[channel, default: 0] += text.count
            print(
                "🧪 [sonda-granola] t+\(format(wallTime))s channel=\(channel.rawValue)"
                    + " kind=volatile chars=\(text.count)"
                    + " window=\(format(window.startTime))s..\(format(window.endTime))s"
                    + " source=\(source)"
            )

        case let .final(text, channel, window):
            finalCount[channel, default: 0] += 1
            finalCharacters[channel, default: 0] += text.count
            print(
                "🧪 [sonda-granola] t+\(format(wallTime))s channel=\(channel.rawValue)"
                    + " kind=final chars=\(text.count)"
                    + " window=\(format(window.startTime))s..\(format(window.endTime))s"
                    + " source=\(source)"
            )

        case let .channelFailed(channel, failure):
            failures[channel, default: 0] += 1
            print(
                "🧪 [sonda-granola] t+\(format(wallTime))s channel=\(channel.rawValue)"
                    + " kind=channelFailed reason=\(String(describing: failure))"
                    + " source=\(source)"
            )
        }
    }

    func snapshot() -> GranolaProbeMetricsSnapshot {
        GranolaProbeMetricsSnapshot(
            firstVolatileAt: firstVolatileAt,
            volatileCount: volatileCount,
            finalCount: finalCount,
            volatileCharacters: volatileCharacters,
            finalCharacters: finalCharacters,
            volatileIntervals: volatileIntervals,
            failures: failures
        )
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

@MainActor
enum GranolaProbe {
    static func runIfRequested() {
        guard let options = GranolaProbeOptions.parse() else { return }
        Task { await run(options) }
    }

    static func run(_ options: GranolaProbeOptions) async {
        print("🧪 [sonda-granola] início — eventos sem transcript")

        guard (options.audioPath == nil) != (options.microphoneSeconds == nil) else {
            print(
                "🧪 [sonda-granola] informe exatamente um de "
                    + "--voiz-granola-probe-audio ou --voiz-granola-probe-mic"
            )
            finish(options)
            return
        }
        guard !options.channels.isEmpty else {
            print(
                "🧪 [sonda-granola] canais inválidos; use microphone, systemAudio ou both"
            )
            finish(options)
            return
        }

        let transcriber = AppleSpeechMeetingTranscriber.make()
        let setupStartedAt = Date()
        let stream: AsyncStream<MeetingLiveTranscriptionEvent>
        do {
            stream = try await transcriber.start(
                config: MeetingLiveTranscriberConfiguration(
                    locale: Locale(identifier: "pt-BR"),
                    channels: options.channels
                )
            )
        } catch {
            print("🧪 [sonda-granola] start falhou: \(String(describing: type(of: error)))")
            finish(options)
            return
        }

        print(
            "🧪 [sonda-granola] setup=\(format(Date().timeIntervalSince(setupStartedAt)))s"
                + " | sessões=\(options.channels.count)"
                + " | canais=\(describe(options.channels))"
        )

        let feedStartedAt = Date()
        let recorder = GranolaProbeEventRecorder(startedAt: feedStartedAt)
        let eventTask = Task {
            for await event in stream {
                await recorder.record(event, source: "stream")
            }
        }
        let cpuStartedAt = processCPUSeconds()

        if let audioPath = options.audioPath {
            await runFile(
                path: audioPath,
                options: options,
                transcriber: transcriber,
                feedStartedAt: feedStartedAt,
                channels: options.channels
            )
        } else if let microphoneSeconds = options.microphoneSeconds {
            await runMicrophone(
                seconds: microphoneSeconds,
                transcriber: transcriber,
                feedStartedAt: feedStartedAt,
                channels: options.channels
            )
        }

        let stopStartedAt = Date()
        let remainingFinals = await transcriber.stop()
        let stopSeconds = Date().timeIntervalSince(stopStartedAt)
        for event in remainingFinals {
            await recorder.record(event, source: "stop")
        }
        await eventTask.value

        let wallSeconds = Date().timeIntervalSince(feedStartedAt)
        let cpuSeconds = max(0, processCPUSeconds() - cpuStartedAt)
        let snapshot = await recorder.snapshot()
        report(
            snapshot: snapshot,
            wallSeconds: wallSeconds,
            cpuSeconds: cpuSeconds,
            stopSeconds: stopSeconds,
            channels: options.channels
        )
        finish(options)
    }

    private static func runFile(
        path: String,
        options: GranolaProbeOptions,
        transcriber: AppleSpeechMeetingTranscriber,
        feedStartedAt: Date,
        channels: Set<MeetingLiveAudioChannel>
    ) async {
        let audio: TranscriptionAudio
        do {
            audio = try BenchmarkAudioLoader.load(url: URL(fileURLWithPath: path))
        } catch {
            print("🧪 [sonda-granola] áudio não abriu: \(String(describing: type(of: error)))")
            return
        }
        guard audio.sampleRate.isFinite, audio.sampleRate > 0, !audio.samples.isEmpty else {
            print("🧪 [sonda-granola] áudio vazio ou sem taxa válida")
            return
        }

        print(
            "🧪 [sonda-granola] fonte=arquivo | duração=\(format(audio.duration))s"
                + " | amostras=\(audio.samples.count)"
                + " | ritmo=\(options.realtime ? "real-time" : "burst")"
        )
        await feedSamples(
            audio.samples,
            sampleRate: audio.sampleRate,
            realtime: options.realtime,
            chunkSeconds: options.chunkSeconds,
            transcriber: transcriber,
            feedStartedAt: feedStartedAt,
            channels: channels
        )
    }

    private static func runMicrophone(
        seconds: Double,
        transcriber: AppleSpeechMeetingTranscriber,
        feedStartedAt: Date,
        channels: Set<MeetingLiveAudioChannel>
    ) async {
        let (packets, continuation) = AsyncStream<GranolaProbeMicPacket>.makeStream()
        let capture = AudioCaptureService()
        capture.onAudioData = { samples in
            guard !samples.isEmpty else { return }
            continuation.yield(
                GranolaProbeMicPacket(samples: samples, capturedAt: Date())
            )
        }

        let feeder = Task {
            for await packet in packets {
                let startTime = max(0, packet.capturedAt.timeIntervalSince(feedStartedAt))
                await feedBothChannels(
                    samples: packet.samples,
                    sampleRate: TranscriptionAudio.defaultSampleRate,
                    startTime: startTime,
                    transcriber: transcriber,
                    channels: channels
                )
            }
        }

        do {
            try capture.startRecording()
        } catch {
            continuation.finish()
            await feeder.value
            print("🧪 [sonda-granola] microfone indisponível: \(String(describing: type(of: error)))")
            return
        }

        print(
            "🧪 [sonda-granola] fonte=microfone | duração alvo=\(format(seconds))s"
                + " | canais=\(describe(channels))"
        )
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        capture.stopRecording()

        // O AudioCaptureService despacha o callback em uma fila global. Esta pequena folga
        // deixa esses callbacks em voo chegarem ao stream antes do feeder ser fechado.
        try? await Task.sleep(nanoseconds: 200_000_000)
        continuation.finish()
        await feeder.value
    }

    private static func feedSamples(
        _ samples: [Float],
        sampleRate: Double,
        realtime: Bool,
        chunkSeconds: Double,
        transcriber: AppleSpeechMeetingTranscriber,
        feedStartedAt: Date,
        channels: Set<MeetingLiveAudioChannel>
    ) async {
        let chunkSize = max(1, Int(sampleRate * chunkSeconds))
        var offset = 0
        while offset < samples.count {
            let end = min(samples.count, offset + chunkSize)
            let chunk = Array(samples[offset..<end])
            await feedBothChannels(
                samples: chunk,
                sampleRate: sampleRate,
                startTime: Double(offset) / sampleRate,
                transcriber: transcriber,
                channels: channels
            )
            offset = end

            guard realtime else { continue }
            let target = Double(offset) / sampleRate
            let elapsed = Date().timeIntervalSince(feedStartedAt)
            let remaining = target - elapsed
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
        }
    }

    private static func feedBothChannels(
        samples: [Float],
        sampleRate: Double,
        startTime: TimeInterval,
        transcriber: AppleSpeechMeetingTranscriber,
        channels: Set<MeetingLiveAudioChannel>
    ) async {
        await withTaskGroup(of: Void.self) { group in
            if channels.contains(.microphone) {
                let microphone = MeetingLiveAudioChunk(
                    samples: samples,
                    sampleRate: sampleRate,
                    startTime: startTime,
                    channel: .microphone
                )
                group.addTask { await transcriber.feed(microphone) }
            }
            if channels.contains(.systemAudio) {
                let systemAudio = MeetingLiveAudioChunk(
                    samples: samples,
                    sampleRate: sampleRate,
                    startTime: startTime,
                    channel: .systemAudio
                )
                group.addTask { await transcriber.feed(systemAudio) }
            }
            await group.waitForAll()
        }
    }

    private static func report(
        snapshot: GranolaProbeMetricsSnapshot,
        wallSeconds: Double,
        cpuSeconds: Double,
        stopSeconds: Double,
        channels: Set<MeetingLiveAudioChannel>
    ) {
        let cpuPercent = wallSeconds > 0 ? (cpuSeconds / wallSeconds) * 100 : 0
        print("🧪 [sonda-granola] === resumo ===")
        print(
            "🧪 [sonda-granola] wall(feed+stop)=\(format(wallSeconds))s"
                + " | cpu(processo)=\(format(cpuSeconds))s"
                + " | cpu/1 núcleo=\(format(cpuPercent))%"
                + " | stop=\(format(stopSeconds))s"
        )

        for channel in channels.sorted(by: { $0.rawValue < $1.rawValue }) {
            let first = snapshot.firstVolatileAt[channel].map { format($0) + "s" } ?? "nenhum"
            let intervals = snapshot.volatileIntervals[channel] ?? []
            let cadence = intervals.isEmpty
                ? "nenhuma"
                : format(intervals.reduce(0, +) / Double(intervals.count)) + "s"
            print(
                "🧪 [sonda-granola] channel=\(channel.rawValue)"
                    + " primeiro-parcial=\(first)"
                    + " | cadência-volátil=\(cadence)"
                    + " | voláteis=\(snapshot.volatileCount[channel, default: 0])"
                    + " chars=\(snapshot.volatileCharacters[channel, default: 0])"
                    + " | finais=\(snapshot.finalCount[channel, default: 0])"
                    + " chars=\(snapshot.finalCharacters[channel, default: 0])"
                    + " | falhas=\(snapshot.failures[channel, default: 0])"
            )
        }
    }

    private static func describe(_ channels: Set<MeetingLiveAudioChannel>) -> String {
        channels
            .sorted(by: { $0.rawValue < $1.rawValue })
            .map(\.rawValue)
            .joined(separator: ",")
    }

    private static func processCPUSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Double(usage.ru_utime.tv_sec)
            + Double(usage.ru_utime.tv_usec) / 1_000_000
            + Double(usage.ru_stime.tv_sec)
            + Double(usage.ru_stime.tv_usec) / 1_000_000
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private static func finish(_ options: GranolaProbeOptions) {
        guard options.shouldExit else { return }
        exit(0)
    }
}
#endif
