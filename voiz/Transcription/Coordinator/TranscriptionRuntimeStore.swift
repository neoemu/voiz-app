import Foundation
import Combine

// O espelho da carga dos motores para a UI (T2.3).
//
// Este arquivo depende só de Foundation + Combine (framework do sistema), como os contratos da
// T1.2: é o que permite compilá-lo no alvo `voizTests` e exercitar a regra de ordenação sem
// instanciar motor nenhum.
//
// Ninguém no app observa este store ainda. Quem o liga aos motores é a fábrica do coordenador
// (`TranscriptionCoordinator.make(...)`), e quem o mostra na tela é a Onda 6.

/// Em que pé está a carga de UM motor, na forma que a tela consome.
///
/// É o denominador comum dos dois tipos de evento que os motores emitem hoje
/// (`WhisperKitLoadEvent` e `ParakeetTranscriptionEngine.LoadEvent`). Eles divergem na forma — o
/// Whisper tem fração de download, o Parakeet não, porque o serviço dele baixa e carrega numa
/// chamada só — mas a semântica de geração é idêntica, e é por ela que este tipo se orienta
/// (DECISOES, adendo item 15).
nonisolated enum TranscriptionRuntimeStage: Sendable, Equatable {
    /// Nenhum modelo residente: ou nunca houve carga, ou houve `unload`.
    case idle
    /// Baixando os pesos. `fraction` vai de 0 a 1.
    case downloading(model: TranscriptionModelID, fraction: Double)
    /// Já no disco, carregando na Neural Engine.
    case loading(model: TranscriptionModelID)
    case ready(model: TranscriptionModelID)
    case failed(model: TranscriptionModelID, failure: TranscriptionEngineFailure)

    /// O modelo a que este estágio se refere; `nil` só em `.idle`.
    var model: TranscriptionModelID? {
        switch self {
        case .idle: return nil
        case .downloading(let model, _), .loading(let model), .ready(let model), .failed(let model, _):
            return model
        }
    }

    /// Há trabalho de carga acontecendo? É o que acende o spinner.
    var isWorking: Bool {
        switch self {
        case .downloading, .loading: return true
        case .idle, .ready, .failed: return false
        }
    }

    /// A ordem dos estágios **dentro de uma mesma geração**.
    ///
    /// Existe por causa do MENOR que a Quilha registrou como item da T2.3: o `.downloading` do
    /// Whisper é emitido do callback de progresso do `HubApi`, **fora do ator**, enquanto
    /// `.loading`/`.ready` saem de dentro dele. Um `.downloading(0.99)` atrasado pode chegar
    /// depois do `.ready` da MESMA geração — e aí a regra "descarte geração menor" não o
    /// descarta, porque a geração é igual. Sem esta ordem, a UI voltava para "baixando" com o
    /// modelo pronto e ficava lá até a próxima operação de ciclo de vida.
    ///
    /// `ready` e `failed` empatam de propósito: uma geração emite um **ou** outro, nunca os dois.
    /// `idle` (o `.unloaded` dos motores) é o mais alto porque descreve a mutação mais recente
    /// possível — mas na prática ele sempre chega com geração própria, já que toda mutação tira a
    /// sua com a vaga na mão.
    var rank: Int {
        switch self {
        case .downloading: return 0
        case .loading: return 1
        case .ready, .failed: return 2
        case .idle: return 3
        }
    }
}

/// O estágio de um motor mais a geração que o produziu.
///
/// A geração é chaveada **por motor**: cada motor tem o contador dele, e comparar a geração do
/// Whisper com a do Parakeet não significa nada (DECISOES, adendo item 15).
nonisolated struct TranscriptionRuntimeState: Sendable, Equatable {
    var stage: TranscriptionRuntimeStage
    /// Maior geração já aceita deste motor. `0` = nenhum evento ainda.
    var generation: Int

    init(stage: TranscriptionRuntimeStage = .idle, generation: Int = 0) {
        self.stage = stage
        self.generation = generation
    }

    static let initial = TranscriptionRuntimeState()
}

/// O que a UI observa para saber o que os motores estão fazendo.
///
/// `@MainActor` porque é isso que a tela consome — e é justamente por isso que ele precisa das
/// gerações: os observadores dos motores são chamados de dentro dos atores deles e das threads de
/// download, então todo evento **hopa** para a main actor antes de chegar aqui. Hop não preserva
/// ordem. Duas regras, e só elas, resolvem isso:
///
/// 1. **Geração menor perde.** Um evento de uma carga já morta (cancelada por `unload` ou por
///    troca de modelo) nunca sobrescreve a viva.
/// 2. **Dentro da mesma geração, o estágio não regride** (`TranscriptionRuntimeStage.rank`): de
///    `.ready`/`.failed` não se volta para `.downloading`/`.loading`, e a fração de download nunca
///    anda para trás.
///
/// O store **não** é a verdade sobre residência — ele é o que foi *observado*. Quem decide o que
/// está residente é o `TranscriptionCoordinator`, e a prova dele é um `prepare`, não um evento
/// (`unload()` devolve `Void`).
@MainActor
final class TranscriptionRuntimeStore: ObservableObject {

    /// Estado por motor. Motor ausente do mapa = nunca emitiu evento.
    @Published private(set) var states: [TranscriptionEngineID: TranscriptionRuntimeState] = [:]

    /// Eventos que chegaram atrasados e foram descartados, por motor. Não muda comportamento —
    /// serve para um teste provar que o descarte aconteceu (e não que o evento nunca chegou) e
    /// para diagnóstico local.
    ///
    /// **Fora do `@Published` de propósito:** é contador de diagnóstico, e publicá-lo invalidaria a
    /// view a cada progresso de download atrasado — ruído de UI por um número que a tela não mostra.
    private(set) var discardedEvents: [TranscriptionEngineID: Int] = [:]

    init() {}

    func state(of engine: TranscriptionEngineID) -> TranscriptionRuntimeState {
        states[engine] ?? .initial
    }

    func stage(of engine: TranscriptionEngineID) -> TranscriptionRuntimeStage {
        state(of: engine).stage
    }

    /// Algum motor está baixando ou carregando?
    var isAnyEngineWorking: Bool {
        states.values.contains { $0.stage.isWorking }
    }

    // MARK: - Entrada dos eventos

    /// Aplica um evento do motor WhisperKit.
    ///
    /// O motor entra por parâmetro (com o default do catálogo) porque nada impede o coordenador de
    /// montar duas instâncias do mesmo tipo de motor no futuro — o que chaveia o estado é o id que
    /// o plano usa, não o tipo do evento.
    func apply(_ event: WhisperKitLoadEvent, from engine: TranscriptionEngineID = .whisperKit) {
        apply(generation: event.generation, stage: Self.stage(of: event.stage), to: engine)
    }

    /// Aplica um evento do motor Parakeet. O tipo é outro, a semântica de geração é a mesma.
    func apply(_ event: ParakeetTranscriptionEngine.LoadEvent, from engine: TranscriptionEngineID = .parakeet) {
        switch event {
        case .loading(let model, let generation):
            apply(generation: generation, stage: .loading(model: model), to: engine)
        case .ready(let model, let generation):
            apply(generation: generation, stage: .ready(model: model), to: engine)
        case .failed(let model, let failure, let generation):
            apply(generation: generation, stage: .failed(model: model, failure: failure), to: engine)
        case .unloaded(let generation):
            apply(generation: generation, stage: .idle, to: engine)
        }
    }

    private func apply(generation: Int, stage: TranscriptionRuntimeStage, to engine: TranscriptionEngineID) {
        let current = state(of: engine)
        guard let next = Self.reduce(current, generation: generation, stage: stage) else {
            discardedEvents[engine, default: 0] += 1
            return
        }
        states[engine] = next
    }

    // MARK: - Observadores prontos para as fábricas dos motores

    /// O observador que se passa a `WhisperKitTranscriptionEngine.make(observer:)`.
    ///
    /// `nonisolated` e com hop explícito: o motor chama o observador de dentro do ator dele e, no
    /// caso do progresso de download, de uma thread da biblioteca. Um `assumeIsolated` aqui seria
    /// crash garantido.
    nonisolated func whisperObserver(
        for engine: TranscriptionEngineID = .whisperKit
    ) -> @Sendable (WhisperKitLoadEvent) -> Void {
        { [weak self] event in
            Task { @MainActor in self?.apply(event, from: engine) }
        }
    }

    /// O observador que se passa a `ParakeetTranscriptionEngine.make(service:observer:)`.
    nonisolated func parakeetObserver(
        for engine: TranscriptionEngineID = .parakeet
    ) -> @Sendable (ParakeetTranscriptionEngine.LoadEvent) -> Void {
        { [weak self] event in
            Task { @MainActor in self?.apply(event, from: engine) }
        }
    }

    // MARK: - A regra, isolada e pura

    /// O novo estado, ou `nil` quando o evento deve ser **descartado**.
    ///
    /// Pura e `static` para o teste poder exercitar a regra sem montar store, sem hop e sem motor
    /// — é ela, e não a plumbing em volta, que impede a UI de mentir.
    nonisolated static func reduce(
        _ current: TranscriptionRuntimeState,
        generation: Int,
        stage: TranscriptionRuntimeStage
    ) -> TranscriptionRuntimeState? {
        // Regra 1: geração menor é de uma carga que já morreu.
        if generation < current.generation { return nil }

        if generation == current.generation {
            // Regra 2: dentro da mesma geração o estágio não regride.
            if stage.rank < current.stage.rank { return nil }
            // …e a barra de progresso não anda para trás.
            if case .downloading(_, let incoming) = stage,
               case .downloading(_, let existing) = current.stage,
               incoming < existing {
                return nil
            }
        }

        return TranscriptionRuntimeState(stage: stage, generation: generation)
    }

    private nonisolated static func stage(of stage: WhisperKitLoadEvent.Stage) -> TranscriptionRuntimeStage {
        switch stage {
        case .downloading(let model, let fraction): return .downloading(model: model, fraction: fraction)
        case .loading(let model): return .loading(model: model)
        case .ready(let model): return .ready(model: model)
        case .failed(let model, let failure): return .failed(model: model, failure: failure)
        case .unloaded: return .idle
        }
    }
}
