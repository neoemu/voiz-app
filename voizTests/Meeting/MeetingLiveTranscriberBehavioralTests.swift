import Foundation
import Testing

actor MockMeetingLiveTranscriber: MeetingLiveTranscriber {
    private(set) var fedChunks: [MeetingLiveAudioChunk] = []
    private(set) var isStarted = false
    private(set) var isStopped = false
    var remainingEventsOnStop: [MeetingLiveTranscriptionEvent] = []

    private var continuation: AsyncStream<MeetingLiveTranscriptionEvent>.Continuation?

    func start(config: MeetingLiveTranscriberConfiguration) async throws -> AsyncStream<MeetingLiveTranscriptionEvent> {
        isStarted = true
        return AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func feed(_ chunk: MeetingLiveAudioChunk) async {
        fedChunks.append(chunk)
    }

    func emit(_ event: MeetingLiveTranscriptionEvent) {
        continuation?.yield(event)
    }

    func stop() async -> [MeetingLiveTranscriptionEvent] {
        isStopped = true
        continuation?.finish()
        return remainingEventsOnStop
    }
}

@Suite("Granola Live Transcriber & Recovery Tests")
struct MeetingLiveTranscriberBehavioralTests {

    @Test("Transcritor ao vivo recebe chunks com canais corretos e drena eventos no stop")
    func liveTranscriberFeedsAndDrainsEvents() async throws {
        let mock = MockMeetingLiveTranscriber()
        await mock.setRemainingEventsOnStop([
            .final(
                text: "fala restante no stop",
                channel: .microphone,
                window: MeetingLiveCaptureWindow(startTime: 5.0, endTime: 7.0)
            )
        ])

        let stream = try await mock.start(config: MeetingLiveTranscriberConfiguration(locale: Locale(identifier: "pt-BR")))
        var receivedEvents: [MeetingLiveTranscriptionEvent] = []

        let collector = Task {
            for await event in stream {
                receivedEvents.append(event)
            }
        }

        let micChunk = MeetingLiveAudioChunk(
            samples: [0.1, 0.2],
            sampleRate: 16000,
            startTime: 0.0,
            channel: .microphone
        )
        let sysChunk = MeetingLiveAudioChunk(
            samples: [0.3, 0.4],
            sampleRate: 16000,
            startTime: 0.5,
            channel: .systemAudio
        )

        await mock.feed(micChunk)
        await mock.feed(sysChunk)

        await mock.emit(.volatile(text: "prévia ao vivo", channel: .microphone, window: MeetingLiveCaptureWindow(startTime: 0.0, endTime: 1.0)))
        await mock.emit(.final(text: "fala 1", channel: .microphone, window: MeetingLiveCaptureWindow(startTime: 0.0, endTime: 2.0)))

        let stoppedEvents = await mock.stop()
        _ = await collector.value

        let fed = await mock.fedChunks
        #expect(fed.count == 2)
        #expect(fed[0].channel == .microphone)
        #expect(fed[1].channel == .systemAudio)

        #expect(receivedEvents.count == 2)
        #expect(stoppedEvents.count == 1)
        if case .final(let text, let channel, _) = stoppedEvents.first {
            #expect(text == "fala restante no stop")
            #expect(channel == .microphone)
        } else {
            Issue.record("Esperava evento final drenado no stop")
        }
    }

    @Test("Provider que devolve o MESMO objeto: stop de A é recusado depois que B sobe a geração")
    func sameInstanceProviderDoesNotStopB() async throws {
        let shared = MockMeetingLiveTranscriber()
        let provider: @Sendable () -> any MeetingLiveTranscriber = { shared }

        let first = provider()
        let second = provider()
        #expect((first as? MockMeetingLiveTranscriber) === (second as? MockMeetingLiveTranscriber))

        _ = try await shared.start(config: MeetingLiveTranscriberConfiguration(locale: Locale(identifier: "pt-BR")))
        var generation = 1
        let stoppingGeneration = generation
        generation += 1

        #expect(
            MeetingRecordingLifecycle.shouldStopLiveTranscriber(
                stoppingGeneration: stoppingGeneration,
                currentGeneration: generation
            ) == false
        )
        #expect(await shared.isStopped == false)
    }

    @Test("Granola define falantes padrão como Você e Outros na chamada")
    func granolaSpeakersDefaultToVoceAndOthers() {
        var session = MeetingSession(
            title: "Reunião Granola",
            sessionType: .meeting,
            startedAt: Date(),
            turns: []
        )
        session.meetingMode = .granola
        session.speakers = []

        #expect(session.speakerName(for: .microphone) == "Você")
        #expect(session.speakerName(for: .systemAudio) == "Outros na chamada")
    }

    @Test("AppSettings.MeetingMode possui descrições completas e corretas")
    func meetingModeDescriptions() {
        #expect(AppSettings.MeetingMode.quality.displayName.contains("Qualidade"))
        #expect(AppSettings.MeetingMode.granola.displayName.contains("Ao vivo"))
        #expect(AppSettings.MeetingMode.quality.description.contains("ASR em lotes"))
        #expect(AppSettings.MeetingMode.granola.description.contains("Apple SpeechAnalyzer"))
    }
}

extension MockMeetingLiveTranscriber {
    func setRemainingEventsOnStop(_ events: [MeetingLiveTranscriptionEvent]) {
        self.remainingEventsOnStop = events
    }
}
