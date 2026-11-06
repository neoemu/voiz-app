import AVFoundation
import Foundation
import Testing

@Suite("Apple SpeechAnalyzer — reunião ao vivo")
struct AppleSpeechMeetingTranscriberTests {
    @Test("Mantém sessões e janelas independentes por canal")
    func channelsStayIndependent() async throws {
        let microphone = FakeMeetingLiveChannelSession(
            eventOnFeed: AppleSpeechMeetingRawEvent(
                text: "mic hipótese",
                isFinal: false,
                audioStart: 0,
                audioEnd: 0.5
            )
        )
        let system = FakeMeetingLiveChannelSession(
            eventOnFeed: AppleSpeechMeetingRawEvent(
                text: "system hipótese",
                isFinal: false,
                audioStart: 0,
                audioEnd: 1
            )
        )
        let transcriber = AppleSpeechMeetingTranscriber(
            factory: FakeMeetingLiveSessionFactory(
                sessions: [.microphone: microphone, .systemAudio: system]
            )
        )
        let stream = try await transcriber.start(
            config: MeetingLiveTranscriberConfiguration(
                channels: [.microphone, .systemAudio]
            )
        )
        var iterator = stream.makeAsyncIterator()

        await transcriber.feed(
            MeetingLiveAudioChunk(
                samples: [Float](repeating: 0, count: 1_000),
                sampleRate: 1_000,
                startTime: 42,
                channel: .microphone
            )
        )
        await transcriber.feed(
            MeetingLiveAudioChunk(
                samples: [Float](repeating: 0, count: 2_000),
                sampleRate: 1_000,
                startTime: 100,
                channel: .systemAudio
            )
        )

        let first = await iterator.next()
        let second = await iterator.next()
        let events = [first, second].compactMap { $0 }
        let channels = Set(events.compactMap { event -> MeetingLiveAudioChannel? in
            guard case let .volatile(_, channel, _) = event else { return nil }
            return channel
        })

        #expect(channels == [.microphone, .systemAudio])
        #expect(events.contains {
            guard case let .volatile(text, .microphone, window) = $0 else { return false }
            return text == "mic hipótese"
                && window == MeetingLiveCaptureWindow(startTime: 42, endTime: 42.5)
        })
        #expect(events.contains {
            guard case let .volatile(text, .systemAudio, window) = $0 else { return false }
            return text == "system hipótese"
                && window == MeetingLiveCaptureWindow(startTime: 100, endTime: 101)
        })

        _ = await transcriber.stop()
    }

    @Test("stop devolve os finais do fechamento sem repeti-los no stream")
    func stopReturnsRemainingFinals() async throws {
        let session = FakeMeetingLiveChannelSession(
            finalOnFinish: AppleSpeechMeetingRawEvent(
                text: "final restante",
                isFinal: true,
                audioStart: 0,
                audioEnd: 1
            )
        )
        let transcriber = AppleSpeechMeetingTranscriber(
            factory: FakeMeetingLiveSessionFactory(sessions: [.microphone: session])
        )
        let stream = try await transcriber.start(
            config: MeetingLiveTranscriberConfiguration(channels: [.microphone])
        )
        var iterator = stream.makeAsyncIterator()

        await transcriber.feed(
            MeetingLiveAudioChunk(
                samples: [Float](repeating: 0, count: 1_000),
                sampleRate: 1_000,
                startTime: 8,
                channel: .microphone
            )
        )
        let finals = await transcriber.stop()

        #expect(finals == [
            .final(
                text: "final restante",
                channel: .microphone,
                window: MeetingLiveCaptureWindow(startTime: 8, endTime: 9)
            )
        ])
        #expect(await iterator.next() == nil)
    }

    @Test("Falha de um canal vira evento e não derruba o outro")
    func oneChannelFailureLeavesOtherRunning() async throws {
        let microphone = FakeMeetingLiveChannelSession(
            eventOnFeed: AppleSpeechMeetingRawEvent(
                text: "mic continua",
                isFinal: false,
                audioStart: 0,
                audioEnd: 1
            )
        )
        let transcriber = AppleSpeechMeetingTranscriber(
            factory: FakeMeetingLiveSessionFactory(
                sessions: [.microphone: microphone],
                failures: [.systemAudio: .runtimeUnavailable]
            )
        )
        let stream = try await transcriber.start(
            config: MeetingLiveTranscriberConfiguration(
                channels: [.microphone, .systemAudio]
            )
        )
        var iterator = stream.makeAsyncIterator()

        let failure = await iterator.next()
        #expect(failure == .channelFailed(.systemAudio, .runtimeUnavailable))

        await transcriber.feed(
            MeetingLiveAudioChunk(
                samples: [Float](repeating: 0, count: 1_000),
                sampleRate: 1_000,
                startTime: 2,
                channel: .microphone
            )
        )
        let liveEvent = await iterator.next()
        #expect(liveEvent == .volatile(
            text: "mic continua",
            channel: .microphone,
            window: MeetingLiveCaptureWindow(startTime: 2, endTime: 3)
        ))

        _ = await transcriber.stop()
    }

    @Test("Volátil vazio é publicado como clear — a retração chega no VM")
    func emptyVolatileIsPublishedAsClear() async throws {
        let session = FakeMeetingLiveChannelSession(
            eventOnFeed: AppleSpeechMeetingRawEvent(
                text: "   ",
                isFinal: false,
                audioStart: 0,
                audioEnd: 0.4
            )
        )
        let transcriber = AppleSpeechMeetingTranscriber(
            factory: FakeMeetingLiveSessionFactory(sessions: [.systemAudio: session])
        )
        let stream = try await transcriber.start(
            config: MeetingLiveTranscriberConfiguration(channels: [.systemAudio])
        )
        var iterator = stream.makeAsyncIterator()

        await transcriber.feed(
            MeetingLiveAudioChunk(
                samples: [Float](repeating: 0, count: 1_000),
                sampleRate: 1_000,
                startTime: 5,
                channel: .systemAudio
            )
        )
        let event = await iterator.next()
        #expect(event == .volatile(
            text: "",
            channel: .systemAudio,
            window: MeetingLiveCaptureWindow(startTime: 5, endTime: 5.4)
        ))
        _ = await transcriber.stop()
    }

    @Test("Todos os locales oferecidos pelo app são aceitos no modo Ao vivo")
    func appLocalesAreAccepted() async throws {
        for appleLocale in AppleSpeechLocale.allCases {
            let session = FakeMeetingLiveChannelSession()
            let factory = FakeMeetingLiveSessionFactory(sessions: [.microphone: session])
            let transcriber = AppleSpeechMeetingTranscriber(factory: factory)

            _ = try await transcriber.start(
                config: MeetingLiveTranscriberConfiguration(
                    locale: Locale(identifier: appleLocale.identifier),
                    channels: [.microphone]
                )
            )

            #expect(await factory.makeCount == 1)
            _ = await transcriber.stop()
        }
    }

    @Test("Locale que o app não oferece é recusado antes de criar sessões")
    func unsupportedLocaleIsRejected() async {
        let factory = FakeMeetingLiveSessionFactory(sessions: [:])
        let transcriber = AppleSpeechMeetingTranscriber(factory: factory)

        do {
            _ = try await transcriber.start(
                config: MeetingLiveTranscriberConfiguration(
                    locale: Locale(identifier: "it-IT"),
                    channels: [.microphone]
                )
            )
            Issue.record("start deveria recusar locale que não faz parte do app")
        } catch let error as AppleSpeechMeetingTranscriberError {
            #expect(error == .unsupportedLocale)
        } catch {
            Issue.record("erro inesperado: \(error)")
        }
        #expect(await factory.makeCount == 0)
    }

    @Test("Collector real propaga falha tipada e fecha o stream de results")
    func realCollectorFailureEmitsAndFinishes() async throws {
        let (results, resultsContinuation) = AsyncThrowingStream<
            AppleSpeechMeetingRawEvent,
            Error
        >.makeStream()
        let (events, outputContinuation) = AsyncStream<AppleSpeechMeetingSessionEvent>.makeStream()
        let collector = AppleSpeechMeetingSpeechAnalyzerSession.makeCollectorTask(
            from: results,
            map: { $0 },
            outputContinuation: outputContinuation
        )
        let probe = SessionEventProbe(events)

        resultsContinuation.finish(throwing: CollectorFailure.resultsFailed)

        #expect(await probe.next(timeout: 1) == .event(.failed(.runtimeFailure)))
        #expect(await probe.next(timeout: 1) == .ended)
        await collector.value
    }

    @Test("Collector real falha e mantém o canal irmão vivo")
    func realCollectorFailureLeavesOtherChannelRunning() async throws {
        let (results, resultsContinuation) = AsyncThrowingStream<
            AppleSpeechMeetingRawEvent,
            Error
        >.makeStream()
        let microphone = CollectorBackedMeetingLiveChannelSession(results: results)
        let system = FakeMeetingLiveChannelSession(
            eventOnFeed: AppleSpeechMeetingRawEvent(
                text: "system continua",
                isFinal: false,
                audioStart: 0,
                audioEnd: 1
            )
        )
        let transcriber = AppleSpeechMeetingTranscriber(
            factory: FakeMeetingLiveSessionFactory(
                sessions: [.microphone: microphone, .systemAudio: system]
            )
        )
        let stream = try await transcriber.start(
            config: MeetingLiveTranscriberConfiguration(
                channels: [.microphone, .systemAudio]
            )
        )
        let probe = MeetingEventProbe(stream)

        resultsContinuation.finish(throwing: CollectorFailure.resultsFailed)
        #expect(await probe.next(timeout: 1) == .channelFailed(
            .microphone,
            .runtimeFailure
        ))

        await transcriber.feed(
            MeetingLiveAudioChunk(
                samples: [Float](repeating: 0, count: 1_000),
                sampleRate: 1_000,
                startTime: 12,
                channel: .systemAudio
            )
        )
        #expect(await probe.next(timeout: 1) == .volatile(
            text: "system continua",
            channel: .systemAudio,
            window: MeetingLiveCaptureWindow(startTime: 12, endTime: 13)
        ))

        _ = await transcriber.stop()
    }

    @Test("stop durante criação parcial cancela a sessão que chega tarde")
    func stopDuringPartialCreationCancelsLateSession() async throws {
        let microphone = FakeMeetingLiveChannelSession()
        let system = FakeMeetingLiveChannelSession()
        let factory = PartialCreationMeetingLiveSessionFactory(
            microphone: microphone,
            system: system
        )
        let transcriber = AppleSpeechMeetingTranscriber(factory: factory)

        let startTask = Task {
            try await transcriber.start(
                config: MeetingLiveTranscriberConfiguration(
                    channels: [.microphone, .systemAudio]
                )
            )
        }

        // A fábrica já devolveu mic e está suspensa na criação de systemAudio.
        await factory.systemRequested.wait()
        _ = await transcriber.stop()

        // A sessão systemAudio só nasce depois de o stop ter desocupado o ciclo.
        await factory.releaseSystem.open()
        do {
            _ = try await startTask.value
            Issue.record("start não deveria devolver um stream após stop reentrante")
        } catch is CancellationError {
            // Esperado: a época do start foi invalidada pelo stop.
        } catch {
            Issue.record("erro inesperado após stop reentrante: \(error)")
        }

        #expect(await microphone.wasFinished)
        #expect(await system.wasCancelled)
        #expect(await factory.makeCount == 2)
    }

    @Test("stop antes da primeira sessão cancela a sessão tardia")
    func stopBeforeFirstCreationCancelsLateSession() async throws {
        let system = FakeMeetingLiveChannelSession()
        let factory = PartialCreationMeetingLiveSessionFactory(
            microphone: FakeMeetingLiveChannelSession(),
            system: system
        )
        let transcriber = AppleSpeechMeetingTranscriber(factory: factory)

        let startTask = Task {
            try await transcriber.start(
                config: MeetingLiveTranscriberConfiguration(channels: [.systemAudio])
            )
        }
        await factory.systemRequested.wait()
        _ = await transcriber.stop()
        await factory.releaseSystem.open()

        do {
            _ = try await startTask.value
            Issue.record("start não deveria devolver um stream após stop inicial")
        } catch is CancellationError {
            // Esperado: nenhuma sessão foi instalada antes do stop.
        } catch {
            Issue.record("erro inesperado após stop inicial: \(error)")
        }

        #expect(await system.wasCancelled)
        #expect(await factory.makeCount == 1)
    }

    @Test("Conversão com taxa divergente preserva o formato exato do analyzer")
    func divergentSampleRateConvertsToExactTargetFormat() throws {
        let target = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ))
        let chunk = MeetingLiveAudioChunk(
            samples: [Float](repeating: 0, count: 800),
            sampleRate: 8_000,
            startTime: 0,
            channel: .microphone
        )

        let buffer = try AppleSpeechMeetingSpeechAnalyzerSession.makeBuffer(
            from: chunk,
            target: target
        )

        #expect(buffer.format.sampleRate == target.sampleRate)
        #expect(buffer.format.channelCount == target.channelCount)
        #expect(buffer.format.commonFormat == target.commonFormat)
        #expect(buffer.format.isInterleaved == target.isInterleaved)
        #expect(buffer.frameLength == 1_600)
    }
}

private actor FakeMeetingLiveChannelSession: AppleSpeechMeetingChannelSession {
    nonisolated let events: AsyncStream<AppleSpeechMeetingSessionEvent>

    private let continuation: AsyncStream<AppleSpeechMeetingSessionEvent>.Continuation
    private let eventOnFeed: AppleSpeechMeetingRawEvent?
    private let finalOnFinish: AppleSpeechMeetingRawEvent?
    private var finished = false

    init(
        eventOnFeed: AppleSpeechMeetingRawEvent? = nil,
        finalOnFinish: AppleSpeechMeetingRawEvent? = nil
    ) {
        let (events, continuation) = AsyncStream<AppleSpeechMeetingSessionEvent>.makeStream()
        self.events = events
        self.continuation = continuation
        self.eventOnFeed = eventOnFeed
        self.finalOnFinish = finalOnFinish
    }

    func feed(_ chunk: MeetingLiveAudioChunk) async throws {
        guard !finished else { throw AppleSpeechMeetingRuntimeError.feedFailed }
        if let eventOnFeed { continuation.yield(.result(eventOnFeed)) }
    }

    func finish() async throws {
        guard !finished else { return }
        finished = true
        wasFinished = true
        if let finalOnFinish { continuation.yield(.result(finalOnFinish)) }
        continuation.finish()
    }

    func cancel() async {
        finished = true
        wasCancelled = true
        continuation.finish()
    }

    private(set) var wasFinished = false
    private(set) var wasCancelled = false

}

private actor CollectorBackedMeetingLiveChannelSession: AppleSpeechMeetingChannelSession {
    nonisolated let events: AsyncStream<AppleSpeechMeetingSessionEvent>

    private let collectorTask: Task<Void, Never>

    init(
        results: AsyncThrowingStream<AppleSpeechMeetingRawEvent, Error>
    ) {
        let (events, continuation) = AsyncStream<AppleSpeechMeetingSessionEvent>.makeStream()
        self.events = events
        self.collectorTask = AppleSpeechMeetingSpeechAnalyzerSession.makeCollectorTask(
            from: results,
            map: { $0 },
            outputContinuation: continuation
        )
    }

    func feed(_ chunk: MeetingLiveAudioChunk) async throws {}

    func finish() async throws {
        await collectorTask.value
    }

    func cancel() async {
        collectorTask.cancel()
    }
}

private enum CollectorFailure: Error, Sendable {
    case resultsFailed
}

private actor SessionEventProbe {
    private var iterator: AsyncStream<AppleSpeechMeetingSessionEvent>.Iterator

    init(_ stream: AsyncStream<AppleSpeechMeetingSessionEvent>) {
        iterator = stream.makeAsyncIterator()
    }

    private func nextEvent() async -> AppleSpeechMeetingSessionEvent? {
        var iterator = iterator
        let event = await iterator.next()
        self.iterator = iterator
        return event
    }

    func next(timeout seconds: UInt64) async -> CollectorRead {
        await withTaskGroup(of: CollectorRead.self) { group in
            group.addTask {
                guard let event = await self.nextEvent() else { return .ended }
                return .event(event)
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                } catch {
                    return .timedOut
                }
                return .timedOut
            }
            let result = await group.next() ?? .timedOut
            group.cancelAll()
            return result
        }
    }
}

private enum CollectorRead: Equatable, Sendable {
    case event(AppleSpeechMeetingSessionEvent)
    case ended
    case timedOut
}

private actor MeetingEventProbe {
    private var iterator: AsyncStream<MeetingLiveTranscriptionEvent>.Iterator

    init(_ stream: AsyncStream<MeetingLiveTranscriptionEvent>) {
        iterator = stream.makeAsyncIterator()
    }

    private func nextEvent() async -> MeetingLiveTranscriptionEvent? {
        var iterator = iterator
        let event = await iterator.next()
        self.iterator = iterator
        return event
    }

    func next(timeout seconds: UInt64) async -> MeetingLiveTranscriptionEvent? {
        await withTaskGroup(of: MeetingLiveTranscriptionEvent?.self) { group in
            group.addTask {
                await self.nextEvent()
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                } catch {}
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}

private struct FakeMeetingLiveSessionFactory: AppleSpeechMeetingSessionFactory {
    let sessions: [MeetingLiveAudioChannel: any AppleSpeechMeetingChannelSession]
    let failures: [MeetingLiveAudioChannel: AppleSpeechMeetingRuntimeError]
    private let countBox: CountBox

    init(
        sessions: [MeetingLiveAudioChannel: any AppleSpeechMeetingChannelSession],
        failures: [MeetingLiveAudioChannel: AppleSpeechMeetingRuntimeError] = [:],
        countBox: CountBox = CountBox()
    ) {
        self.sessions = sessions
        self.failures = failures
        self.countBox = countBox
    }

    var makeCount: Int {
        get async { await countBox.value }
    }

    func makeSession(
        locale: Locale,
        channel: MeetingLiveAudioChannel
    ) async throws -> any AppleSpeechMeetingChannelSession {
        await countBox.increment()
        if let failure = failures[channel] { throw failure }
        guard let session = sessions[channel] else {
            throw AppleSpeechMeetingRuntimeError.runtimeUnavailable
        }
        return session
    }
}

private struct PartialCreationMeetingLiveSessionFactory: AppleSpeechMeetingSessionFactory {
    let microphone: FakeMeetingLiveChannelSession
    let system: FakeMeetingLiveChannelSession
    let systemRequested = AsyncGate()
    let releaseSystem = AsyncGate()
    private let countBox = CountBox()

    var makeCount: Int {
        get async { await countBox.value }
    }

    func makeSession(
        locale: Locale,
        channel: MeetingLiveAudioChannel
    ) async throws -> any AppleSpeechMeetingChannelSession {
        await countBox.increment()
        if channel == .systemAudio {
            await systemRequested.open()
            await releaseSystem.wait()
            return system
        }
        return microphone
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

private actor CountBox {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
