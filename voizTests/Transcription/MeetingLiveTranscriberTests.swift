import Foundation
import Testing

@Suite("Contrato de transcrição ao vivo")
struct MeetingLiveTranscriberTests {
    @Test("A configuração padrão usa pt-BR e os dois canais")
    func defaultConfiguration() {
        let config = MeetingLiveTranscriberConfiguration()

        #expect(config.locale.identifier == "pt-BR")
        #expect(config.channels == Set(MeetingLiveAudioChannel.allCases))
    }

    @Test("A janela do chunk usa o relógio da captura")
    func chunkEndTimeUsesCaptureClock() {
        let chunk = MeetingLiveAudioChunk(
            samples: [0, 0, 0, 0],
            sampleRate: 2,
            startTime: 12.5,
            channel: .microphone
        )

        #expect(chunk.endTime == 14.5)
        #expect(chunk.channel == .microphone)
    }

    @Test("O protocolo pode ser consumido por existential sem associatedtype")
    func protocolIsExistentialFriendly() async throws {
        let transcriber: any MeetingLiveTranscriber = StubTranscriber()
        let stream = try await transcriber.start(config: MeetingLiveTranscriberConfiguration())

        await transcriber.feed(
            MeetingLiveAudioChunk(
                samples: [0],
                sampleRate: 16_000,
                startTime: 3,
                channel: .systemAudio
            )
        )
        let remaining = await transcriber.stop()

        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == nil)
        #expect(remaining.isEmpty)
    }

    @Test("Eventos mantêm canal, janela e falha sem payload livre")
    func eventsCarrySafeMetadata() {
        let window = MeetingLiveCaptureWindow(startTime: 10, endTime: 11.25)
        let events: [MeetingLiveTranscriptionEvent] = [
            .volatile(text: "hipótese", channel: .microphone, window: window),
            .final(text: "final", channel: .systemAudio, window: window),
            .channelFailed(.microphone, .runtimeFailure)
        ]

        #expect(events.count == 3)
        #expect(events[0] == .volatile(text: "hipótese", channel: .microphone, window: window))
        #expect(events[1] == .final(text: "final", channel: .systemAudio, window: window))
        #expect(events[2] == .channelFailed(.microphone, .runtimeFailure))
    }
}

private struct StubTranscriber: MeetingLiveTranscriber {
    func start(config: MeetingLiveTranscriberConfiguration) async throws
        -> AsyncStream<MeetingLiveTranscriptionEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func feed(_ chunk: MeetingLiveAudioChunk) async {}

    func stop() async -> [MeetingLiveTranscriptionEvent] { [] }
}
