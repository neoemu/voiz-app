import Foundation

/// A escolha de motor que o usuário fez nas Configurações, já resolvida para **um** caso de uso.
///
/// O roteador recebe a escolha deste caso de uso, e não o mapa inteiro das Configurações, para
/// não depender do formato de persistência (que é da T1.4) nem virar o lugar onde se decide
/// qual seleção vale para qual tela.
nonisolated struct TranscriptionUserSelection: Sendable, Equatable, Hashable {
    /// O que o usuário pinou; `nil` = modo automático.
    var preferred: TranscriptionEngineChoice?

    /// "Use exatamente o que eu escolhi." Com isto ligado o plano **nunca** tem fallback: ou
    /// roda o que foi pedido, ou não roda nada e o app diz por quê.
    ///
    /// Existe porque fallback silencioso é veneno em duas situações: no benchmark (mediria o
    /// motor errado) e para quem escolheu um motor de propósito e receberia texto de outro sem
    /// perceber.
    var strictEngineSelection: Bool

    init(preferred: TranscriptionEngineChoice? = nil, strictEngineSelection: Bool = false) {
        self.preferred = preferred
        self.strictEngineSelection = strictEngineSelection
    }

    /// Modo automático: o roteador escolhe e pode cair para o próximo candidato.
    static let automatic = TranscriptionUserSelection()

    /// Escolha manual do usuário.
    static func manual(
        engine: TranscriptionEngineID,
        model: TranscriptionModelID? = nil,
        strict: Bool = false
    ) -> TranscriptionUserSelection {
        TranscriptionUserSelection(
            preferred: TranscriptionEngineChoice(engine: engine, model: model),
            strictEngineSelection: strict
        )
    }
}

/// Motor (e, opcionalmente, modelo) escolhido a dedo. `model == nil` = "o padrão desse motor",
/// que é o que a UI oferece quando o usuário escolhe só o motor.
nonisolated struct TranscriptionEngineChoice: Sendable, Equatable, Hashable, Codable {
    var engine: TranscriptionEngineID
    var model: TranscriptionModelID?

    init(engine: TranscriptionEngineID, model: TranscriptionModelID? = nil) {
        self.engine = engine
        self.model = model
    }
}

/// Tudo que o roteador precisa saber para decidir: idioma × caso de uso × hardware × escolha
/// do usuário. Nada aqui é lido do disco, do sistema ou de um singleton — quem coleta é o
/// coordenador da Onda 2.
nonisolated struct TranscriptionRoutingContext: Sendable, Equatable {
    var useCase: TranscriptionUseCase
    /// Idioma falado esperado; `nil` = detecção automática.
    var language: TranscriptionLanguage?
    var hardware: TranscriptionHardwareProfile
    var selection: TranscriptionUserSelection
    var requiresVocabulary: Bool

    init(
        useCase: TranscriptionUseCase,
        language: TranscriptionLanguage?,
        hardware: TranscriptionHardwareProfile,
        selection: TranscriptionUserSelection = .automatic,
        requiresVocabulary: Bool = false
    ) {
        self.useCase = useCase
        self.language = language
        self.hardware = hardware
        self.selection = selection
        self.requiresVocabulary = requiresVocabulary
    }
}

/// Um motor+modelo que o coordenador pode tentar, e em que posição.
nonisolated struct TranscriptionRoutingCandidate: Sendable, Equatable, Hashable {
    var engine: TranscriptionEngineID
    var model: TranscriptionModelID
    /// 0 = primeira escolha. 1+ = fallback, na ordem em que devem ser tentados.
    var rank: Int
    var origin: TranscriptionSelectionOrigin

    init(engine: TranscriptionEngineID, model: TranscriptionModelID, rank: Int, origin: TranscriptionSelectionOrigin) {
        self.engine = engine
        self.model = model
        self.rank = rank
        self.origin = origin
    }

    var isFallback: Bool { rank > 0 }
}

/// Por que um motor ficou de fora do plano.
///
/// O plano guarda isto para o app conseguir explicar a ausência — na Onda 6 é o "motivo
/// resumido" da tela de Ajustes, e desde já é o que faz um teste distinguir "excluído por
/// hardware" de "excluído por idioma" em vez de só constatar uma lista menor.
nonisolated struct TranscriptionRoutingRejection: Sendable, Equatable, Hashable {
    nonisolated enum Reason: Sendable, Equatable, Hashable {
        /// O id não existe no catálogo (seleção salva de uma versão anterior do app).
        case unknownEngine
        /// O motor não atende este caso de uso.
        case useCaseUnsupported(TranscriptionUseCase)
        /// O caso de uso exige streaming e o motor só faz lote (ou o inverso).
        case modeUnsupported(TranscriptionUseCase)
        /// O motor não fala o idioma pedido — ou não detecta idioma, num pedido automático.
        case languageUnsupported(TranscriptionLanguage?)
        /// Este Mac não atende o mínimo do motor.
        case hardwareUnsupported
        /// Nenhum modelo do motor serve para este idioma/hardware.
        case noViableModel
        /// O modelo que o usuário pinou não existe nesse motor ou não serve aqui.
        case selectedModelUnavailable(TranscriptionModelID)
        /// O usuário exigiu um motor específico (`strictEngineSelection`), então os demais nem
        /// foram considerados.
        case strictSelection
        case vocabularyUnsupported
    }

    var engine: TranscriptionEngineID
    var reason: Reason

    init(engine: TranscriptionEngineID, reason: Reason) {
        self.engine = engine
        self.reason = reason
    }
}

/// O resultado do roteamento: quem tentar, em que ordem, e quem ficou de fora e por quê.
nonisolated struct TranscriptionRoutingPlan: Sendable, Equatable {
    var useCase: TranscriptionUseCase
    /// Candidatos em ordem de tentativa. Vazio = não há como transcrever neste contexto.
    var candidates: [TranscriptionRoutingCandidate]
    /// Motores descartados, na ordem do catálogo.
    var rejections: [TranscriptionRoutingRejection]
    /// O plano foi montado sob `strictEngineSelection`. Invariante: `candidates.count <= 1`.
    var isStrict: Bool

    init(
        useCase: TranscriptionUseCase,
        candidates: [TranscriptionRoutingCandidate],
        rejections: [TranscriptionRoutingRejection],
        isStrict: Bool
    ) {
        self.useCase = useCase
        self.candidates = candidates
        self.rejections = rejections
        self.isStrict = isStrict
    }

    /// A primeira escolha, quando existe.
    var primary: TranscriptionRoutingCandidate? { candidates.first }

    /// Os candidatos de fallback, na ordem de tentativa.
    var fallbacks: [TranscriptionRoutingCandidate] { Array(candidates.dropFirst()) }

    var isEmpty: Bool { candidates.isEmpty }

    func rejectionReason(for engine: TranscriptionEngineID) -> TranscriptionRoutingRejection.Reason? {
        rejections.first { $0.engine == engine }?.reason
    }
}

/// Decide qual motor transcreve o quê.
///
/// É uma função pura de `(catálogo, contexto) -> plano`: sem I/O, sem singleton, sem estado.
/// Todo o resto da missão depende dessa pureza — é o que permite testar "num Intel só sobra o
/// WhisperKit" sem um Intel, e é o que garante que dois pedidos iguais produzam o mesmo plano
/// (a reunião persiste o plano no início e reusa nos lotes seguintes).
///
/// ## As regras, na ordem
/// 1. **Strict** (`strictEngineSelection`): o plano tem no máximo um candidato. Com escolha do
///    usuário, é ela ou nada — escolha inviável devolve plano **vazio**, nunca outro motor.
///    Sem escolha, sobra só a primeira posição da ordem automática.
/// 2. **Escolha do usuário viável**: vai em `rank 0` com `origin == .userSelection`; os demais
///    motores viáveis viram fallback atrás dela (a menos que strict).
/// 3. **Escolha do usuário inviável** e não-strict: cai inteiro para a ordem automática, e o
///    motivo fica em `rejections`. Quando o que falhou foi só o **modelo pinado**, o motor
///    continua no plano — na posição automática dele, com o `defaultModel` — em vez de sumir:
///    deixar o usuário sem transcrição é pior que usar outro modelo, e a troca não é silenciosa
///    (a proveniência marca `origin == .automatic` e a rejeição diz qual modelo foi pedido).
///    Nesse caso, e só nesse, um motor aparece ao mesmo tempo em `candidates` e em `rejections`
///    — é o par que a UI da Onda 6 usa para dizer "usando X porque o modelo Y não cabe aqui".
/// 4. **Ordem automática**: motores viáveis por `automaticPriority(for: useCase)` crescente,
///    desempate pelo id do motor. Determinística. A prioridade é lida **por caso de uso**: o
///    descritor tem uma ordem base e pode declarar uma diferente para um caso de uso específico
///    (`automaticPriorityOverrides`), que é como a Q2 põe o Apple na frente só no transcript
///    oficial da reunião sem tocar em ditado, tradução e prévia. O roteador não conhece caso de
///    uso nenhum por nome — ele só pergunta ao descritor, que é dado.
///
/// Um motor é viável quando atende, todos ao mesmo tempo: o caso de uso, o modo (streaming ×
/// lote), o idioma, o hardware da máquina — e tem pelo menos um modelo que também atende
/// idioma e hardware.
nonisolated struct TranscriptionRouter: Sendable {
    let catalog: TranscriptionCatalog

    init(catalog: TranscriptionCatalog = .shipping) {
        self.catalog = catalog
    }

    func plan(for context: TranscriptionRoutingContext) -> TranscriptionRoutingPlan {
        var rejections: [TranscriptionRoutingRejection] = []

        // Passo 1: quem sobrevive ao contexto, na ordem automática.
        var viable: [(descriptor: TranscriptionEngineDescriptor, model: TranscriptionModelID)] = []
        for descriptor in catalog.engines {
            switch evaluate(descriptor, in: context) {
            case .viable(let model):
                viable.append((descriptor, model))
            case .rejected(let reason):
                rejections.append(TranscriptionRoutingRejection(engine: descriptor.engine, reason: reason))
            }
        }
        viable.sort { lhs, rhs in
            if context.requiresVocabulary {
                let leftIsApple = lhs.descriptor.engine == .appleSpeechAnalyzer
                let rightIsApple = rhs.descriptor.engine == .appleSpeechAnalyzer
                if leftIsApple != rightIsApple { return leftIsApple }
            }
            let left = lhs.descriptor.automaticPriority(for: context.useCase)
            let right = rhs.descriptor.automaticPriority(for: context.useCase)
            if left != right { return left < right }
            return lhs.descriptor.engine.rawValue < rhs.descriptor.engine.rawValue
        }

        // Passo 2: a escolha do usuário, se houver, tem prioridade sobre a ordem automática.
        var chosen: (engine: TranscriptionEngineID, model: TranscriptionModelID)?
        if let preferred = context.selection.preferred {
            if let descriptor = catalog.descriptor(for: preferred.engine) {
                switch resolveUserChoice(preferred, descriptor: descriptor, in: context) {
                case .viable(let model):
                    chosen = (preferred.engine, model)
                case .rejected(let reason):
                    // O motor pode ter passado no passo 1 (viável com o modelo automático) e
                    // ainda assim falhar aqui, se o usuário pinou um modelo que não serve.
                    // Nesse caso a rejeição específica substitui a ausência de rejeição — mas
                    // o motor **continua** na lista viável, e volta como candidato automático
                    // com o modelo padrão dele (ver regra 3). É por isso que um mesmo motor
                    // pode aparecer em `candidates` e em `rejections` ao mesmo tempo.
                    rejections.removeAll { $0.engine == preferred.engine }
                    rejections.append(TranscriptionRoutingRejection(engine: preferred.engine, reason: reason))
                }
            } else {
                rejections.append(TranscriptionRoutingRejection(engine: preferred.engine, reason: .unknownEngine))
            }
        }

        // Passo 3: a ordem de tentativa — a escolha do usuário na frente, o resto atrás.
        var ordered: [(engine: TranscriptionEngineID, model: TranscriptionModelID)] = []
        if let chosen { ordered.append(chosen) }
        for entry in viable where entry.descriptor.engine != chosen?.engine {
            ordered.append((entry.descriptor.engine, entry.model))
        }

        // Passo 4: strict nunca cai para outro motor.
        //
        // Com escolha: ou roda o que foi pedido, ou nada — se a escolha não é viável, o plano
        // fica **vazio**, e não com o segundo colocado (era exatamente o fallback silencioso
        // que o strict existe para impedir). Sem escolha: sobra só o primeiro da ordem
        // automática, porque a promessa "não caia para outro motor" não depende de ter havido
        // escolha manual.
        if context.selection.strictEngineSelection {
            let kept: [(engine: TranscriptionEngineID, model: TranscriptionModelID)]
            if context.selection.preferred == nil {
                kept = Array(ordered.prefix(1))
            } else if let chosen {
                kept = [chosen]
            } else {
                kept = []
            }
            for entry in ordered where !kept.contains(where: { $0.engine == entry.engine }) {
                // Não sobrescreve um motivo mais específico: o motor com modelo pinado
                // indisponível já carrega o `.selectedModelUnavailable` dele, que explica
                // melhor a ausência do que "ficou de fora porque strict".
                guard !rejections.contains(where: { $0.engine == entry.engine }) else { continue }
                rejections.append(
                    TranscriptionRoutingRejection(engine: entry.engine, reason: .strictSelection)
                )
            }
            ordered = kept
        }

        let candidates = ordered.enumerated().map { index, entry in
            TranscriptionRoutingCandidate(
                engine: entry.engine,
                model: entry.model,
                rank: index,
                // Só a primeira posição pode ter vindo do usuário; o resto é a ordem automática.
                origin: index == 0 && entry.engine == chosen?.engine ? .userSelection : .automatic
            )
        }

        return TranscriptionRoutingPlan(
            useCase: context.useCase,
            candidates: candidates,
            rejections: rejections,
            isStrict: context.selection.strictEngineSelection
        )
    }

    /// Motor viável (com o modelo que ele usaria) ou recusado, com o motivo.
    private enum EngineEvaluation {
        case viable(TranscriptionModelID)
        case rejected(TranscriptionRoutingRejection.Reason)
    }

    /// O motor serve neste contexto? Devolve o modelo automático dele, ou o motivo da recusa.
    private func evaluate(
        _ descriptor: TranscriptionEngineDescriptor,
        in context: TranscriptionRoutingContext
    ) -> EngineEvaluation {
        guard !context.requiresVocabulary || descriptor.supportsVocabulary else {
            return .rejected(.vocabularyUnsupported)
        }
        guard descriptor.supportedUseCases.contains(context.useCase) else {
            return .rejected(.useCaseUnsupported(context.useCase))
        }
        guard descriptor.supports(useCase: context.useCase) else {
            return .rejected(.modeUnsupported(context.useCase))
        }
        guard descriptor.supports(language: context.language) else {
            return .rejected(.languageUnsupported(context.language))
        }
        guard descriptor.hardware.isSatisfied(by: context.hardware) else {
            return .rejected(.hardwareUnsupported)
        }
        guard let model = automaticModel(of: descriptor, in: context) else {
            return .rejected(.noViableModel)
        }
        return .viable(model.id)
    }

    /// O modelo que o motor usa quando o usuário não pinou nenhum: o `defaultModel` declarado,
    /// se ele servir aqui; senão o primeiro da lista que sirva.
    private func automaticModel(
        of descriptor: TranscriptionEngineDescriptor,
        in context: TranscriptionRoutingContext
    ) -> TranscriptionModelDescriptor? {
        let usable = descriptor.models.filter { isUsable($0, in: context) }
        if let preferred = descriptor.defaultModel,
           let match = usable.first(where: { $0.id == preferred }) {
            return match
        }
        return usable.first
    }

    private func isUsable(
        _ model: TranscriptionModelDescriptor,
        in context: TranscriptionRoutingContext
    ) -> Bool {
        model.supports(language: context.language) && model.hardware.isSatisfied(by: context.hardware)
    }

    /// A escolha do usuário serve? Diferente de `evaluate`, aqui o modelo pinado é obrigatório:
    /// pedir "Whisper large" e receber "Whisper small" caladamente seria o fallback silencioso
    /// que a seleção manual existe para evitar.
    private func resolveUserChoice(
        _ choice: TranscriptionEngineChoice,
        descriptor: TranscriptionEngineDescriptor,
        in context: TranscriptionRoutingContext
    ) -> EngineEvaluation {
        switch evaluate(descriptor, in: context) {
        case .rejected(let reason):
            return .rejected(reason)
        case .viable(let automaticModel):
            guard let wanted = choice.model else { return .viable(automaticModel) }
            guard let model = descriptor.model(wanted), isUsable(model, in: context) else {
                return .rejected(.selectedModelUnavailable(wanted))
            }
            return .viable(model.id)
        }
    }
}
