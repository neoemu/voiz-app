import Foundation

/// As duas fontes que uma reunião pode transcrever ao vivo.
///
/// Cada canal tem uma sessão do SpeechAnalyzer própria. Misturar mic e áudio do sistema
/// antes de chamar o motor cria uma fala defasada e não é permitido pelo contrato do
/// modo Ao vivo (persistido com o raw value legado `granola`).
nonisolated enum MeetingLiveAudioChannel: String, CaseIterable, Hashable, Sendable {
    case microphone
    case systemAudio
}

/// Um fragmento de áudio anotado pelo relógio da captura.
///
/// O wrapper mantém o contrato independente de `AVAudioPCMBuffer`, que não é `Sendable` e
/// tornaria os testes puros dependentes do framework de áudio. O adapter Apple converte o
/// fragmento para o `bestAvailableAudioFormat` antes de alimentar o analyzer. `startTime`
/// é tempo do relógio de captura, não tempo produzido pelo reconhecedor.
nonisolated struct MeetingLiveAudioChunk: Equatable, Sendable {
    let samples: [Float]
    let sampleRate: Double
    let startTime: TimeInterval
    let channel: MeetingLiveAudioChannel

    init(
        samples: [Float],
        sampleRate: Double,
        startTime: TimeInterval,
        channel: MeetingLiveAudioChannel
    ) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.startTime = startTime
        self.channel = channel
    }

    /// Fim do fragmento no relógio da captura, calculado sem consultar o reconhecedor.
    var endTime: TimeInterval {
        guard sampleRate > 0 else { return startTime }
        return startTime + Double(samples.count) / sampleRate
    }
}

/// Configuração de uma sessão de transcrição ao vivo.
nonisolated struct MeetingLiveTranscriberConfiguration: Sendable {
    let locale: Locale
    let channels: Set<MeetingLiveAudioChannel>

    init(
        locale: Locale = Locale(identifier: "pt-BR"),
        channels: Set<MeetingLiveAudioChannel> = Set(MeetingLiveAudioChannel.allCases)
    ) {
        self.locale = locale
        self.channels = channels
    }
}

/// Intervalo de um evento, sempre no relógio usado pela captura.
nonisolated struct MeetingLiveCaptureWindow: Equatable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval

    init(startTime: TimeInterval, endTime: TimeInterval) {
        self.startTime = startTime
        self.endTime = endTime
    }
}

/// Falhas que podem desativar apenas um canal.
///
/// Deliberadamente não há mensagem associada: este valor pode atravessar o stream e ser
/// registrado pela UI sem carregar texto reconhecido, prompt ou corpo de erro de provedor.
nonisolated enum MeetingLiveTranscriberFailure: Equatable, Sendable {
    case unsupportedLocale
    case assetUnavailable
    case audioFormatUnsupported
    case runtimeUnavailable
    case runtimeFailure
    case cancelled
}

/// Evento incremental consumido pelo modo Ao vivo.
///
/// `.volatile` é uma hipótese substituível dentro da janela atual. `.final` é texto que o
/// consumidor pode guardar. O engine emite uma janela baseada no relógio de captura do chunk,
/// nunca em offsets ou timestamps do reconhecedor. `channelFailed` encerra somente a utilidade
/// daquele canal; o outro canal pode continuar emitindo eventos.
nonisolated enum MeetingLiveTranscriptionEvent: Equatable, Sendable {
    case volatile(text: String, channel: MeetingLiveAudioChannel, window: MeetingLiveCaptureWindow)
    case final(text: String, channel: MeetingLiveAudioChannel, window: MeetingLiveCaptureWindow)
    case channelFailed(MeetingLiveAudioChannel, MeetingLiveTranscriberFailure)
}

/// Contrato do transcritor ao vivo de uma reunião.
///
/// `start` devolve o stream concreto que termina depois de `stop`. `feed` aceita somente o
/// canal anotado no próprio chunk; implementações não devem somar os canais. `stop` aguarda o
/// fechamento do analyzer e devolve apenas os eventos `.final` restantes, sem repetir eventos
/// já publicados no stream.
nonisolated protocol MeetingLiveTranscriber: Sendable {
    func start(config: MeetingLiveTranscriberConfiguration) async throws
        -> AsyncStream<MeetingLiveTranscriptionEvent>
    func feed(_ chunk: MeetingLiveAudioChunk) async
    func stop() async -> [MeetingLiveTranscriptionEvent]
}
