import AVFoundation
import Foundation
import Speech

/// Falhas de configuração que impedem uma sessão inteira de começar.
nonisolated enum AppleSpeechMeetingTranscriberError: Error, Equatable, Sendable {
    case alreadyStarted
    case unsupportedLocale
    case noChannels
}

/// Falhas internas do runtime Apple sem mensagem livre.
///
/// A classificação detalhada fica no tipo, não em uma string que poderia carregar texto
/// reconhecido ou o corpo de um erro do framework.
nonisolated enum AppleSpeechMeetingRuntimeError: Error, Equatable, Sendable {
    case unsupportedLocale
    case runtimeUnavailable
    case noCompatibleAudioFormat
    case analyzerStartFailed
    case feedFailed
    case finishFailed
    case cancelled
    case runtimeFailure
}

/// Um resultado cru do `SpeechTranscriber`, com tempo relativo ao áudio alimentado no canal.
/// O adapter converte esse intervalo para o relógio da captura antes de publicar o evento.
nonisolated struct AppleSpeechMeetingRawEvent: Equatable, Sendable {
    let text: String
    let isFinal: Bool
    let audioStart: TimeInterval
    let audioEnd: TimeInterval
}

/// Resultado interno de uma sessão. Falhas do collector atravessam o mesmo stream que os
/// resultados para que o coordenador possa desocupar apenas o canal afetado.
nonisolated enum AppleSpeechMeetingSessionEvent: Equatable, Sendable {
    case result(AppleSpeechMeetingRawEvent)
    case failed(AppleSpeechMeetingRuntimeError)
}

/// Sessão de analyzer de um único canal.
///
/// O contrato mantém um stream por sessão para que mic e system jamais compartilhem um
/// reconhecedor ou um buffer. A implementação de produção usa `SpeechAnalyzer`; os testes
/// injetam uma sessão sem tocar no framework.
nonisolated protocol AppleSpeechMeetingChannelSession: Sendable {
    var events: AsyncStream<AppleSpeechMeetingSessionEvent> { get }
    func feed(_ chunk: MeetingLiveAudioChunk) async throws
    func finish() async throws
    func cancel() async
}

/// Fábrica injetável das sessões Apple.
nonisolated protocol AppleSpeechMeetingSessionFactory: Sendable {
    func makeSession(
        locale: Locale,
        channel: MeetingLiveAudioChannel
    ) async throws -> any AppleSpeechMeetingChannelSession
}

/// Transcritor do modo Ao vivo (raw value legado: `granola`).
///
/// Há uma sessão de `SpeechAnalyzer` por canal. Os resultados voláteis e finais atravessam um
/// único `AsyncStream` concreto, mas nunca são misturados: o canal acompanha cada evento desde
/// a captura até a UI. O stream de um ciclo termina no `stop()`; um novo `start()` abre um ciclo
/// novo e recria as sessões.
actor AppleSpeechMeetingTranscriber: MeetingLiveTranscriber {
    private enum State {
        case idle
        case starting
        case running
        case stopping
        case stopped
    }

    private struct TimelineEntry: Sendable {
        let audioStart: TimeInterval
        let audioEnd: TimeInterval
        let captureStart: TimeInterval
        let captureEnd: TimeInterval
    }

    private let factory: any AppleSpeechMeetingSessionFactory
    private var state: State = .idle
    /// Identifica o ciclo que possui as sessões atuais. Um `start` suspenso na fábrica nunca
    /// pode instalar uma sessão quando esse ciclo já entrou em `stopping` ou terminou.
    private var activeGeneration: UInt64?
    private var nextGeneration: UInt64 = 0
    private var configuration = MeetingLiveTranscriberConfiguration()
    private var sessions: [MeetingLiveAudioChannel: any AppleSpeechMeetingChannelSession] = [:]
    private var eventTasks: [MeetingLiveAudioChannel: Task<Void, Never>] = [:]
    private var timelines: [MeetingLiveAudioChannel: [TimelineEntry]] = [:]
    private var audioCursors: [MeetingLiveAudioChannel: TimeInterval] = [:]
    private var pendingFinals: [MeetingLiveTranscriptionEvent] = []
    private var streamContinuation: AsyncStream<MeetingLiveTranscriptionEvent>.Continuation?

    init(
        factory: any AppleSpeechMeetingSessionFactory = AppleSpeechMeetingSpeechAnalyzerFactory()
    ) {
        self.factory = factory
    }

    /// Fábrica explícita para produção, mantendo a dependência do framework fora do contrato.
    nonisolated static func make() -> AppleSpeechMeetingTranscriber {
        AppleSpeechMeetingTranscriber(factory: AppleSpeechMeetingSpeechAnalyzerFactory())
    }

    func start(
        config: MeetingLiveTranscriberConfiguration
    ) async throws -> AsyncStream<MeetingLiveTranscriptionEvent> {
        guard state != .starting, state != .running, state != .stopping else {
            throw AppleSpeechMeetingTranscriberError.alreadyStarted
        }
        guard Self.isSupportedLocale(config.locale) else {
            throw AppleSpeechMeetingTranscriberError.unsupportedLocale
        }
        guard !config.channels.isEmpty else {
            throw AppleSpeechMeetingTranscriberError.noChannels
        }

        let (stream, continuation) = AsyncStream<MeetingLiveTranscriptionEvent>.makeStream()
        nextGeneration &+= 1
        let generation = nextGeneration
        activeGeneration = generation
        configuration = config
        state = .starting
        streamContinuation = continuation
        sessions = [:]
        eventTasks = [:]
        timelines = [:]
        audioCursors = [:]
        pendingFinals = []

        for channel in config.channels.sorted(by: Self.channelOrder) {
            do {
                let session = try await factory.makeSession(
                    locale: config.locale,
                    channel: channel
                )

                // `stop()` pode ter invalidado o ciclo enquanto a fábrica estava suspensa.
                // A sessão tardia não entra no dicionário nem ganha task de eventos; ela é
                // cancelada aqui antes que o `start` devolva o controle ao chamador.
                guard Self.isActive(
                    generation: generation,
                    state: state,
                    activeGeneration: activeGeneration,
                    expectedState: .starting
                ) else {
                    await session.cancel()
                    throw CancellationError()
                }

                sessions[channel] = session
                timelines[channel] = []
                audioCursors[channel] = 0
                eventTasks[channel] = Task { [weak self] in
                    for await event in session.events {
                        switch event {
                        case let .result(rawEvent):
                            await self?.receive(
                                rawEvent,
                                from: channel,
                                generation: generation
                            )
                        case let .failed(error):
                            await self?.fail(
                                channel: channel,
                                error: error,
                                generation: generation
                            )
                        }
                    }
                }
            } catch {
                guard Self.isActive(
                    generation: generation,
                    state: state,
                    activeGeneration: activeGeneration,
                    expectedState: .starting
                ) else {
                    throw CancellationError()
                }
                continuation.yield(
                    .channelFailed(channel, Self.failure(from: error))
                )
            }
        }

        guard Self.isActive(
            generation: generation,
            state: state,
            activeGeneration: activeGeneration,
            expectedState: .starting
        ) else {
            throw CancellationError()
        }
        state = .running

        return stream
    }

    /// Alimenta somente a sessão correspondente ao canal do chunk.
    func feed(_ chunk: MeetingLiveAudioChunk) async {
        guard state == .running,
              configuration.channels.contains(chunk.channel),
              let session = sessions[chunk.channel],
              let generation = activeGeneration
        else { return }

        guard !chunk.samples.isEmpty,
              chunk.sampleRate.isFinite,
              chunk.sampleRate > 0
        else {
            await fail(
                channel: chunk.channel,
                error: AppleSpeechMeetingRuntimeError.feedFailed,
                generation: generation
            )
            return
        }

        let audioStart = audioCursors[chunk.channel, default: 0]
        let audioEnd = audioStart + Double(chunk.samples.count) / chunk.sampleRate
        timelines[chunk.channel, default: []].append(
            TimelineEntry(
                audioStart: audioStart,
                audioEnd: audioEnd,
                captureStart: chunk.startTime,
                captureEnd: chunk.endTime
            )
        )
        audioCursors[chunk.channel] = audioEnd

        do {
            try await session.feed(chunk)
        } catch {
            await fail(channel: chunk.channel, error: error, generation: generation)
        }
    }

    /// Fecha as duas sessões, espera resultados que ainda estejam em voo e devolve somente os
    /// finais produzidos durante esse fechamento. Finais já publicados no stream não são repetidos.
    func stop() async -> [MeetingLiveTranscriptionEvent] {
        guard state == .starting || state == .running else { return [] }
        state = .stopping

        let currentSessions = sessions
        for (channel, session) in currentSessions {
            do {
                // A única chamada de finalização do ciclo. Nunca há finalize(through:) durante
                // feed: a sonda reproduziu o travamento desse caminho em 2/2 execuções.
                try await session.finish()
            } catch {
                streamContinuation?.yield(
                    .channelFailed(channel, Self.failure(from: error))
                )
                await session.cancel()
            }
        }

        for task in eventTasks.values {
            await task.value
        }

        streamContinuation?.finish()
        streamContinuation = nil
        sessions = [:]
        eventTasks = [:]
        activeGeneration = nil
        state = .stopped

        let result = pendingFinals
        pendingFinals = []
        return result
    }

    // MARK: - Eventos e relógio da captura

    private func receive(
        _ rawEvent: AppleSpeechMeetingRawEvent,
        from channel: MeetingLiveAudioChannel,
        generation: UInt64
    ) {
        guard (state == .running || state == .stopping),
              activeGeneration == generation,
              let continuation = streamContinuation
        else { return }

        let text = rawEvent.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            guard !rawEvent.isFinal else { return }
            continuation.yield(
                .volatile(
                    text: "",
                    channel: channel,
                    window: captureWindow(for: rawEvent, channel: channel)
                )
            )
            return
        }

        let event: MeetingLiveTranscriptionEvent = rawEvent.isFinal
            ? .final(
                text: text,
                channel: channel,
                window: captureWindow(for: rawEvent, channel: channel)
            )
            : .volatile(
                text: text,
                channel: channel,
                window: captureWindow(for: rawEvent, channel: channel)
            )

        if state == .stopping, rawEvent.isFinal {
            // O fechamento entrega estes finais pelo retorno de stop. Não os duplica no stream.
            pendingFinals.append(event)
        } else {
            continuation.yield(event)
        }
    }

    private func fail(
        channel: MeetingLiveAudioChannel,
        error: any Error,
        generation: UInt64
    ) async {
        guard (state == .starting || state == .running || state == .stopping),
              activeGeneration == generation
        else { return }
        let failure = Self.failure(from: error)
        streamContinuation?.yield(.channelFailed(channel, failure))
        if let session = sessions.removeValue(forKey: channel) {
            await session.cancel()
        }
        eventTasks[channel]?.cancel()
        eventTasks[channel] = nil
    }

    private static func isActive(
        generation: UInt64,
        state: State,
        activeGeneration: UInt64?,
        expectedState: State
    ) -> Bool {
        activeGeneration == generation && state == expectedState
    }

    private func captureWindow(
        for rawEvent: AppleSpeechMeetingRawEvent,
        channel: MeetingLiveAudioChannel
    ) -> MeetingLiveCaptureWindow {
        guard let entries = timelines[channel], let last = entries.last else {
            return MeetingLiveCaptureWindow(startTime: 0, endTime: 0)
        }

        let hasRange = rawEvent.audioStart.isFinite
            && rawEvent.audioEnd.isFinite
            && rawEvent.audioEnd > rawEvent.audioStart
        let startAudio = hasRange ? max(0, rawEvent.audioStart) : last.audioStart
        let endAudio = hasRange ? max(startAudio, rawEvent.audioEnd) : last.audioEnd

        let start = captureTime(forAudioTime: startAudio, entries: entries)
        let end = max(start, captureTime(forAudioTime: endAudio, entries: entries))
        return MeetingLiveCaptureWindow(startTime: start, endTime: end)
    }

    private func captureTime(
        forAudioTime audioTime: TimeInterval,
        entries: [TimelineEntry]
    ) -> TimeInterval {
        guard let first = entries.first, let last = entries.last else { return 0 }
        if audioTime <= first.audioStart { return first.captureStart }
        if audioTime >= last.audioEnd { return last.captureEnd }

        for entry in entries {
            guard audioTime <= entry.audioEnd else { continue }
            let duration = entry.audioEnd - entry.audioStart
            guard duration > 0 else { return entry.captureStart }
            let fraction = min(1, max(0, (audioTime - entry.audioStart) / duration))
            return entry.captureStart
                + fraction * (entry.captureEnd - entry.captureStart)
        }
        return last.captureEnd
    }

    private static func isSupportedLocale(_ locale: Locale) -> Bool {
        AppleSpeechLocale.supports(locale)
    }

    private static func channelOrder(
        _ lhs: MeetingLiveAudioChannel,
        _ rhs: MeetingLiveAudioChannel
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    private static func failure(from error: any Error) -> MeetingLiveTranscriberFailure {
        if Task.isCancelled || error is CancellationError {
            return .cancelled
        }
        if let error = error as? AppleSpeechMeetingRuntimeError {
            switch error {
            case .unsupportedLocale: return .unsupportedLocale
            case .runtimeUnavailable: return .runtimeUnavailable
            case .noCompatibleAudioFormat: return .audioFormatUnsupported
            case .cancelled: return .cancelled
            case .analyzerStartFailed, .feedFailed, .finishFailed, .runtimeFailure:
                return .runtimeFailure
            }
        }
        return .runtimeFailure
    }
}

// MARK: - Runtime Apple SpeechAnalyzer

/// Fábrica da implementação real. Cada chamada constrói um analyzer próprio do canal.
nonisolated struct AppleSpeechMeetingSpeechAnalyzerFactory: AppleSpeechMeetingSessionFactory {
    func makeSession(
        locale: Locale,
        channel: MeetingLiveAudioChannel
    ) async throws -> any AppleSpeechMeetingChannelSession {
        let session = AppleSpeechMeetingSpeechAnalyzerSession(locale: locale, channel: channel)
        try await session.start()
        return session
    }
}

/// Uma sessão progressiva do SpeechAnalyzer para um canal.
///
/// O `.progressiveTranscription` é obrigatório: a sonda mediu o primeiro parcial em ~1 s com
/// esse preset, enquanto reportingOptions custom demorou ~11,5 s. O formato de cada buffer é
/// sempre o retorno de `bestAvailableAudioFormat`; entregar outro formato pode causar SIGTRAP
/// dentro do framework.
actor AppleSpeechMeetingSpeechAnalyzerSession: AppleSpeechMeetingChannelSession {
    nonisolated let events: AsyncStream<AppleSpeechMeetingSessionEvent>

    private let locale: Locale
    private let channel: MeetingLiveAudioChannel
    private let eventContinuation: AsyncStream<AppleSpeechMeetingSessionEvent>.Continuation
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var module: SpeechTranscriber?
    private var analyzerFormat: AVAudioFormat?
    private var collectorTask: Task<Void, Never>?
    private var started = false
    private var finished = false

    init(locale: Locale, channel: MeetingLiveAudioChannel) {
        let (events, continuation) = AsyncStream<AppleSpeechMeetingSessionEvent>.makeStream()
        self.events = events
        self.eventContinuation = continuation
        self.locale = locale
        self.channel = channel
    }

    func start() async throws {
        guard !started else { return }
        guard AppleSpeechLocale.supports(locale) else {
            throw AppleSpeechMeetingRuntimeError.unsupportedLocale
        }
        guard SpeechTranscriber.isAvailable else {
            throw AppleSpeechMeetingRuntimeError.runtimeUnavailable
        }

        let module = SpeechTranscriber(
            locale: locale,
            preset: .progressiveTranscription
        )
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [module]
        ) else {
            throw AppleSpeechMeetingRuntimeError.noCompatibleAudioFormat
        }

        let analyzer = SpeechAnalyzer(
            modules: [module],
            options: SpeechAnalyzer.Options(
                priority: .userInitiated,
                modelRetention: .processLifetime
            )
        )
        do {
            try await analyzer.prepareToAnalyze(in: format)
            let (inputs, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            let outputContinuation = eventContinuation
            let collector = Self.makeCollectorTask(
                from: module.results,
                map: { Self.rawEvent(from: $0) },
                outputContinuation: outputContinuation
            )

            self.module = module
            self.analyzer = analyzer
            self.analyzerFormat = format
            self.inputContinuation = continuation
            self.collectorTask = collector
            self.started = true

            do {
                try await analyzer.start(inputSequence: inputs)
            } catch {
                await cancelAnalyzer(analyzer)
                collector.cancel()
                eventContinuation.finish()
                throw Self.runtimeError(from: error)
            }
        } catch {
            throw Self.runtimeError(from: error)
        }
    }

    func feed(_ chunk: MeetingLiveAudioChunk) async throws {
        guard started, !finished,
              let inputContinuation,
              let analyzerFormat
        else {
            throw AppleSpeechMeetingRuntimeError.feedFailed
        }

        do {
            let buffer = try Self.makeBuffer(from: chunk, target: analyzerFormat)
            inputContinuation.yield(AnalyzerInput(buffer: buffer))
        } catch {
            throw Self.runtimeError(from: error)
        }
    }

    func finish() async throws {
        guard started, !finished else { return }
        finished = true
        inputContinuation?.finish()

        guard let analyzer else {
            eventContinuation.finish()
            return
        }

        do {
            // Nunca chamar finalize(through:) aqui entre yields. O finish completo só acontece
            // quando o consumidor pede stop, exatamente como a sonda exigiu.
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            await collectorTask?.value
        } catch {
            await cancelAnalyzer(analyzer)
            collectorTask?.cancel()
            eventContinuation.finish()
            throw Self.runtimeError(from: error)
        }
    }

    func cancel() async {
        guard !finished else { return }
        finished = true
        inputContinuation?.finish()
        collectorTask?.cancel()
        await collectorTask?.value
        if let analyzer {
            await cancelAnalyzer(analyzer)
        }
        eventContinuation.finish()
    }

    private func cancelAnalyzer(_ analyzer: SpeechAnalyzer) async {
        await analyzer.cancelAndFinishNow()
    }

    private static func rawEvent(from result: SpeechTranscriber.Result) -> AppleSpeechMeetingRawEvent {
        let start = result.range.start.seconds
        let end = (result.range.start + result.range.duration).seconds
        return AppleSpeechMeetingRawEvent(
            text: String(result.text.characters),
            isFinal: result.isFinal,
            audioStart: start.isFinite ? start : 0,
            audioEnd: end.isFinite ? end : 0
        )
    }

    private static func runtimeError(from error: any Error) -> AppleSpeechMeetingRuntimeError {
        if error is CancellationError || Task.isCancelled {
            return .cancelled
        }
        if let error = error as? AppleSpeechMeetingRuntimeError {
            return error
        }
        return .runtimeFailure
    }

    /// Coletor real do módulo, separado apenas na fronteira da fonte `results` para permitir
    /// um stream de falha determinístico nos testes. O caminho de produção passa diretamente
    /// `module.results`; não há fake de sessão entre o erro do módulo e esta supervisão.
    nonisolated static func makeCollectorTask<Results: AsyncSequence>(
        from results: Results,
        map: @escaping @Sendable (Results.Element) -> AppleSpeechMeetingRawEvent,
        outputContinuation: AsyncStream<AppleSpeechMeetingSessionEvent>.Continuation
    ) -> Task<Void, Never>
    where Results: Sendable, Results.Element: Sendable {
        Task {
            do {
                for try await result in results {
                    outputContinuation.yield(.result(map(result)))
                }
            } catch {
                // O erro não pode ficar preso no Task: o transcritor precisa receber um
                // evento tipado, desocupar este canal e manter o outro funcionando. A
                // falha não carrega a mensagem do provedor nem qualquer transcript.
                let failure = Self.runtimeError(from: error)
                if failure != .cancelled {
                    outputContinuation.yield(.failed(failure))
                }
            }
            outputContinuation.finish()
        }
    }

    /// Converte o chunk para o formato EXATO escolhido por `bestAvailableAudioFormat`.
    ///
    /// Converte cada chunk para o formato EXATO retornado pelo runtime. Não há formato
    /// constante nem guarda de layout: o `AVAudioConverter` preserva a escolha do
    /// `bestAvailableAudioFormat`, inclusive interleaving e número de canais.
    nonisolated static func makeBuffer(
        from chunk: MeetingLiveAudioChunk,
        target: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        guard !chunk.samples.isEmpty,
              chunk.sampleRate.isFinite,
              chunk.sampleRate > 0,
              target.sampleRate.isFinite,
              target.sampleRate > 0,
              target.channelCount > 0
        else {
            throw AppleSpeechMeetingRuntimeError.noCompatibleAudioFormat
        }

        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: chunk.sampleRate,
            channels: 1,
            interleaved: false
        ),
        let source = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(chunk.samples.count)
        ) else {
            throw AppleSpeechMeetingRuntimeError.noCompatibleAudioFormat
        }
        source.frameLength = AVAudioFrameCount(chunk.samples.count)
        guard let sourceChannel = source.floatChannelData?[0] else {
            throw AppleSpeechMeetingRuntimeError.noCompatibleAudioFormat
        }
        chunk.samples.withUnsafeBufferPointer { samples in
            sourceChannel.update(from: samples.baseAddress!, count: chunk.samples.count)
        }

        if sourceFormat == target { return source }

        guard let converter = AVAudioConverter(from: sourceFormat, to: target) else {
            throw AppleSpeechMeetingRuntimeError.noCompatibleAudioFormat
        }
        let ratio = target.sampleRate / chunk.sampleRate
        let capacity = AVAudioFrameCount(
            (Double(chunk.samples.count) * ratio).rounded(.up)
        ) + 1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw AppleSpeechMeetingRuntimeError.noCompatibleAudioFormat
        }

        let boxed = AppleSpeechMeetingUncheckedSendableBox(value: source)
        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return boxed.value
        }
        guard conversionError == nil,
              status != .error,
              converted.frameLength > 0
        else {
            throw AppleSpeechMeetingRuntimeError.noCompatibleAudioFormat
        }
        return converted
    }
}

private struct AppleSpeechMeetingUncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
}
