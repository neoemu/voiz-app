import Foundation

// A montagem do coordenador com os motores de produção.
//
// É o único arquivo da T2.3 que o alvo `voizTests` **não** compila: `ParakeetTranscriptionEngine
// .make(service:)` e `WhisperKitTranscriptionEngine.make(observer:)` puxam, por tabela, o serviço
// do Parakeet (FluidAudio) e o WhisperKit. Como em `LiveWhisperKitRuntime`, aqui não há decisão —
// só a ligação entre as fábricas dos motores, o store da UI e o coordenador.
//
// **Ninguém chama isto ainda.** Quem vai chamar são a T2.4a/T2.4b (ditado e tradução) e a T2.5
// (reunião), e só a T2.5 encerra as instâncias legadas que hoje seguram pesos fora do coordenador.

nonisolated extension TranscriptionCoordinator {

    /// O coordenador com os dois motores de verdade, já ligados ao store da UI.
    ///
    /// Os motores nascem pelas fábricas `make(...)` de cada um — e não por construtor direto —
    /// porque é ela que cria o runtime de produção correspondente. É aqui, e só aqui, que os
    /// observadores de carga são amarrados ao `TranscriptionRuntimeStore`: o coordenador não
    /// conhece o store (ele é `@MainActor` e a decisão de residência não pode depender da UI), e o
    /// store não conhece os motores.
    ///
    /// - Parameters:
    ///   - parakeetService: o serviço do Parakeet que este coordenador passa a governar. Entra por
    ///     parâmetro **obrigatório** pelo mesmo motivo da fábrica do motor: um default criaria um
    ///     segundo runtime de 600 MB fora dos livros de residência.
    ///   - runtimeStore: o espelho da carga para a tela. `nil` = ninguém está olhando (é o caso do
    ///     runner de benchmark da Onda 3).
    ///   - foreignOwners: donos de pesos que **não** são motores deste coordenador — as instâncias
    ///     legadas da janela T2.4a→T2.5. O parâmetro faltava aqui: a T2.3 criou
    ///     `TranscriptionForeignWeightOwner` exatamente para esta janela, mas esta fábrica não
    ///     deixava ninguém injetar um (achado MAIOR da Quilha na T2.4b).
    ///
    ///     **Continua vazio depois da T2.5**, e agora porque não há mais dono externo que valha a
    ///     pena: a reunião saiu do `TranscriptionService.shared`, que era o último consumidor dele,
    ///     e o singleton legado deixou de ser construído. Injetar um dono que nunca segura nada
    ///     custaria o pré-aquecimento de **todo** modelo pesado, porque
    ///     `wouldEvictForeignWeights` é conservador com a lista não vazia. O raciocínio inteiro
    ///     está em `LegacyWhisperWeightOwner`.
    @MainActor
    static func make(
        parakeetService: ParakeetTranscriptionService,
        runtimeStore: TranscriptionRuntimeStore? = nil,
        router: TranscriptionRouter = TranscriptionRouter(),
        hardware: TranscriptionHardwareProfile = .detected(),
        retryPolicy: TranscriptionRetryPolicy = .default,
        foreignOwners: [any TranscriptionForeignWeightOwner] = []
    ) -> TranscriptionCoordinator {
        let whisper = WhisperKitTranscriptionEngine.make(
            observer: runtimeStore?.whisperObserver()
        )
        let parakeet = ParakeetTranscriptionEngine.make(
            service: parakeetService,
            observer: runtimeStore?.parakeetObserver()
        )
        let apple = AppleSpeechAnalyzerEngine.make()
        return TranscriptionCoordinator(
            engines: [
                .whisperKit: whisper,
                .parakeet: parakeet,
                .appleSpeechAnalyzer: apple
            ],
            router: router,
            hardware: hardware,
            retryPolicy: retryPolicy,
            foreignOwners: foreignOwners
        )
    }
}

nonisolated extension TranscriptionModelStore {
    /// O depósito de pesos no lugar padrão: `~/Library/Application Support/Voiz/Models`.
    ///
    /// Application Support, e não Caches: um modelo apagado pelo sistema no meio de uma reunião
    /// seria uma reunião sem transcript. Application Support não é limpo por pressão de disco.
    static func make(
        directoryName: String = "Models",
        storage: any TranscriptionModelStorage = LiveTranscriptionModelStorage(),
        downloader: any TranscriptionModelDownloading = LiveTranscriptionModelDownloader()
    ) -> TranscriptionModelStore {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let root = base
            .appendingPathComponent("Voiz", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
        // `shared(root:)` e não o construtor: as garantias do store são por instância, mas a raiz é
        // do processo — dois stores sobre a mesma pasta colidiriam no staging, e a poda de abertura
        // de um apagaria o download em voo do outro.
        return TranscriptionModelStore.shared(root: root, storage: storage, downloader: downloader)
    }
}
