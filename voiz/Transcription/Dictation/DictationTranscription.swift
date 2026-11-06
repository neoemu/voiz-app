import Foundation

// A lógica pura do ditado sobre o coordenador (T2.4a).
//
// O `TranscriptionViewModel` é `@MainActor`, fala com `NSPasteboard`, com o `AudioCaptureService` e
// com o notch: nada dele é testável sem host app, e o alvo `voizTests` não tem host app de
// propósito (DECISOES, 2026-08-07). Então tudo que é **decisão** sai de lá e vem para cá — mapear a
// seleção do usuário, decidir se o aviso de fallback aparece, traduzir o estágio de carga para a
// tela, classificar a falha. O que sobra no view model é I/O e UI.
//
// Como os contratos da T1.2, este arquivo depende **só de Foundation** e é `nonisolated` de ponta a
// ponta: ele compila nos dois alvos, e o alvo do app usa `SWIFT_DEFAULT_ACTOR_ISOLATION =
// MainActor`.

// `Language.transcriptionLanguage` — o idioma falado do pedido, no vocabulário dos contratos —
// era declarado aqui na primeira versão desta tarefa e também em `AppSettingsTranscriptionSelection`
// (T2.4b). Cada branch compilava sozinho; juntos davam redeclaração (MENOR da review Farol de
// 2026-08-10). Ficou a declaração da T2.4b, que já está na integradora: é a mesma ponte que
// `effectiveTranscriptionChoice(for:)` faz — settings/UI de um lado, roteador do outro — e o arquivo
// dela compila nos dois alvos, como este. O comportamento é idêntico ao que o ditado já usava
// (`pt`/`en` genéricos, sem região; `.auto` vira `nil` = detecção automática), que é o que o caminho
// legado fazia em `TranscriptionService.transcribe`.

/// As decisões do ditado que não dependem de tela, de áudio nem de rede.
nonisolated enum DictationTranscription {

    // MARK: - Aviso de fallback

    /// O texto não veio da primeira escolha do plano: quem transcreveu de fato.
    ///
    /// Só nomes de **produto** (marca), que não são copy traduzível — quem monta a frase
    /// localizada é o view model. O tipo existe para o teste conseguir afirmar "o aviso aparece, e
    /// nomeia o Parakeet" sem instanciar UI.
    nonisolated struct FallbackNotice: Equatable, Sendable {
        /// Nome de produto do motor que transcreveu (`Parakeet v3 (FluidAudio)`).
        var engineName: String
        /// Nome de produto do modelo que transcreveu (`Whisper small`).
        var modelName: String
    }

    /// O aviso de fallback deste resultado, ou `nil` quando não houve fallback.
    ///
    /// A regra é a proveniência, e só ela: `candidateRank > 0` significa que o candidato que
    /// rodou não era a primeira escolha do plano — foi o coordenador que trocou, e a troca não
    /// pode ser silenciosa (PLANO: "fallback local com proveniência").
    ///
    /// Modelo ou motor fora do catálogo cai no `rawValue` do id em vez de sumir: um aviso com
    /// nome técnico é melhor que nenhum aviso, e o id é estável por contrato (T1.2).
    static func fallbackNotice(
        for provenance: TranscriptionProvenance,
        catalog: TranscriptionCatalog = .shipping
    ) -> FallbackNotice? {
        guard provenance.isFallback else { return nil }
        let descriptor = catalog.descriptor(for: provenance.engine)
        return FallbackNotice(
            engineName: descriptor?.productName ?? provenance.engine.rawValue,
            modelName: descriptor?.model(provenance.model)?.productName ?? provenance.model.rawValue
        )
    }

    // MARK: - Proveniência para log

    /// A proveniência em uma linha, para o console de debug do app.
    ///
    /// **Nunca inclui texto transcrito** (PLANO, regra 7) — é a razão de existir em vez de um
    /// `String(describing:)` no view model: o que vai para o log é decidido aqui, num lugar que o
    /// teste consegue travar.
    static func logSummary(for provenance: TranscriptionProvenance) -> String {
        let origin = provenance.origin == .userSelection ? "escolha do usuário" : "automático"
        let rank = provenance.isFallback ? "fallback #\(provenance.candidateRank)" : "1ª escolha"
        return "\(provenance.engine.rawValue)/\(provenance.model.rawValue) — \(origin), \(rank)"
    }

    // MARK: - Estado do modelo para a tela

    /// Em que pé está a carga do modelo do ditado, na forma que as Configurações desenham.
    ///
    /// Os cinco casos são os mesmos do `TranscriptionService.ModelLoadState` legado, com as mesmas
    /// formas: a faixa de status da tela de Ajustes continua idêntica. O que muda é a fonte — o
    /// espelho dos motores do coordenador (`TranscriptionRuntimeStore`) no lugar do singleton, que
    /// o ditado não usa mais.
    nonisolated enum ModelStatus: Equatable, Sendable {
        case idle
        case downloading(Double)
        case loading
        case ready
        case failed(String)
    }

    /// Traduz o estágio observado de um motor para o que a tela mostra.
    ///
    /// - Parameters:
    ///   - stage: o estágio observado no motor do rank 0 do plano do ditado.
    ///   - expectedModel: o modelo que o ditado vai usar. Estágio de **outro** modelo vira
    ///     `.idle`, e essa filtragem é o ponto: o mesmo motor serve mais de um consumidor (a
    ///     tradução compartilha o coordenador) e troca de modelo, então um `.ready` do WhisperKit
    ///     pode ser de `large-v3-turbo` enquanto o ditado espera `small`. Sem o filtro, a faixa
    ///     dizia "Modelo pronto" com os pesos do ditado ausentes — que é exatamente o contrário do
    ///     que ela existe para informar. `nil` = não há candidato (plano vazio), e aí também não há
    ///     nada a mostrar.
    ///   - describingFailure: a mensagem de uma falha, localizada por quem chama. A localização
    ///     mora no alvo do app; a decisão de qual estágio vira o quê mora aqui.
    static func modelStatus(
        for stage: TranscriptionRuntimeStage,
        expecting expectedModel: TranscriptionModelID?,
        describingFailure: (TranscriptionEngineFailure) -> String
    ) -> ModelStatus {
        guard let expectedModel else { return .idle }
        // `.idle` não nomeia modelo (é o `unloaded` do motor) e já significa "nada residente".
        guard stage.model == nil || stage.model == expectedModel else { return .idle }
        switch stage {
        case .idle:
            return .idle
        case .downloading(_, let fraction):
            return .downloading(fraction)
        case .loading:
            return .loading
        case .ready:
            return .ready
        case .failed(_, let failure):
            return .failed(describingFailure(failure))
        }
    }

    // MARK: - Falhas

    /// Por que o ditado não produziu texto, no vocabulário do ditado.
    ///
    /// O coordenador fala em `TranscriptionCoordinatorError` (com a lista de tentativas dentro) e
    /// os motores em `TranscriptionEngineFailure`; a tela precisa de uma frase. Este enum é o meio
    /// do caminho: ele preserva **o que** falhou, e a frase (localizada) é montada no view model.
    nonisolated enum Failure: Equatable, Sendable {
        /// O roteador não ofereceu candidato nenhum para este contexto.
        case noCandidate
        /// Todos os candidatos falharam. A falha é a do **último** tentado — é ela que descreve
        /// por que não sobrou saída, e as anteriores já foram registradas no log.
        case enginesFailed(TranscriptionEngineFailure)
        /// Alguém cancelou (parou a gravação, fechou a tela). Não é erro para mostrar.
        case cancelled
        /// Fora do vocabulário conhecido, com a descrição técnica.
        case unexpected(String)
    }

    /// Classifica o erro que o coordenador lançou.
    ///
    /// `allCandidatesFailed` com lista vazia não deveria acontecer (o coordenador só lança isso
    /// depois de tentar), mas cair em `.noCandidate` é a leitura honesta desse caso: nenhum
    /// candidato chegou a produzir falha.
    static func failure(for error: any Error) -> Failure {
        if let coordinatorError = error as? TranscriptionCoordinatorError {
            switch coordinatorError {
            case .noCandidate:
                return .noCandidate
            case .allCandidatesFailed(let attempts):
                guard let last = attempts.last else { return .noCandidate }
                return .enginesFailed(last.failure)
            case .planMismatch(let planUseCase, let requestUseCase):
                return .unexpected("plano de \(planUseCase.rawValue) usado em \(requestUseCase.rawValue)")
            case .streamingUnsupported(let useCase):
                return .unexpected("\(useCase.rawValue) exige streaming")
            case .cancelled:
                return .cancelled
            }
        }
        if let engineFailure = error as? TranscriptionEngineFailure {
            return engineFailure == .cancelled ? .cancelled : .enginesFailed(engineFailure)
        }
        if error is CancellationError { return .cancelled }
        return .unexpected(error.localizedDescription)
    }
}

extension AppSettings {
    /// A seleção de motor/modelo que vale para este caso de uso, pronta para o roteador.
    ///
    /// É a ponte entre o que está gravado (T1.4) e o que o coordenador pede — e é ela que garante
    /// o "mesmo modelo efetivo que hoje" da T2.4a, em duas situações diferentes:
    ///
    /// - **Settings já migrados** (`transcriptionSettingsVersion` em dia): vale o que está lá.
    ///   Automático devolve `.automatic` (o roteador escolhe); avançado devolve a escolha pinada
    ///   do caso de uso, e `nil` no mapa também é automático — é o que acontece com um caso de uso
    ///   que a UI da Onda 6 ainda não deixou o usuário pinar.
    /// - **Settings ainda não migrados** (o caso de **todo mundo** hoje: a migração só é ligada no
    ///   `SettingsStore` na Onda 6): a migração da T1.4 é determinística e idempotente, então
    ///   aplicá-la **em memória** dá exatamente a escolha que o consumidor legado usa hoje, sem
    ///   escrever nada no disco. Sem isto, quem escolheu `large-v3-turbo` ou Parakeet passaria a
    ///   ditar com Whisper small na primeira execução depois da migração — troca silenciosa de
    ///   modelo, que é o que a regra 6 do PLANO proíbe.
    ///
    /// Nunca `strictEngineSelection`: hoje não existe "não caia para outro motor" no ditado, e
    /// ligar isso aqui transformaria uma falha recuperável em ditado sem texto. O fallback é
    /// permitido e **avisado** (`DictationTranscription.fallbackNotice`).
    func transcriptionSelection(for useCase: TranscriptionUseCase) -> TranscriptionUserSelection {
        guard transcriptionSettingsVersion >= Self.currentTranscriptionSettingsVersion else {
            // O guarda de versão de `migratingTranscriptionSettings()` corta a recursão: o valor
            // devolvido já vem com a versão atual.
            return migratingTranscriptionSettings().transcriptionSelection(for: useCase)
        }
        guard let choice = transcriptionChoice(for: useCase) else { return .automatic }
        return TranscriptionUserSelection(preferred: choice, strictEngineSelection: false)
    }
}
