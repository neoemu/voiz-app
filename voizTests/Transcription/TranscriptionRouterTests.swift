import Testing
import Foundation

/// Testes do `TranscriptionRouter` — a função pura que decide qual motor transcreve o quê.
///
/// Quase tudo aqui roda sobre catálogos falsos: o roteador não pode depender de quais motores
/// o app tem hoje, e um teste que quebra quando a Onda 5 acrescenta o TAGARELA seria um teste
/// do catálogo disfarçado de teste do roteador. O catálogo de produção tem suíte própria.
@Suite("TranscriptionRouter")
struct TranscriptionRouterTests {

    // MARK: - Ordem automática

    @Test("A ordem automática segue automaticPriority crescente")
    func automaticOrderFollowsPriority() {
        let catalog = TranscriptionCatalog(engines: [
            TranscriptionFixtures.engine(.fakeCharlie, priority: 100),
            TranscriptionFixtures.engine(.fakeAlpha, priority: 0),
            TranscriptionFixtures.engine(.fakeBravo, priority: 50)
        ])
        let plan = TranscriptionRouter(catalog: catalog).plan(for: TranscriptionFixtures.context())

        #expect(plan.candidates.map(\.engine) == [.fakeAlpha, .fakeBravo, .fakeCharlie])
        #expect(plan.candidates.map(\.rank) == [0, 1, 2])
        #expect(plan.candidates.allSatisfy { $0.origin == .automatic })
        #expect(plan.primary?.engine == .fakeAlpha)
        #expect(plan.primary?.isFallback == false)
        #expect(plan.fallbacks.allSatisfy { $0.isFallback })
        #expect(plan.isStrict == false)
    }

    @Test("A prioridade é lida por caso de uso: override vale só onde foi declarado")
    func automaticOrderIsPerUseCase() {
        // O eixo que a Q2 abriu, exercitado sem o catálogo de produção: um motor com ordem base
        // ruim e override bom em UM caso de uso.
        let catalog = TranscriptionCatalog(engines: [
            TranscriptionFixtures.engine(.fakeAlpha, priority: 0),
            TranscriptionFixtures.engine(
                .fakeBravo,
                priority: 50,
                priorityOverrides: [.meetingFinal: -1]
            ),
            TranscriptionFixtures.engine(.fakeCharlie, priority: 100)
        ])
        let router = TranscriptionRouter(catalog: catalog)

        let meeting = router.plan(for: TranscriptionFixtures.context(useCase: .meetingFinal))
        #expect(meeting.candidates.map(\.engine) == [.fakeBravo, .fakeAlpha, .fakeCharlie])
        #expect(meeting.candidates.map(\.rank) == [0, 1, 2])

        // Nos outros casos de uso o override não existe e a base responde — é esta linha que
        // impede uma promoção de vazar para as outras telas.
        for useCase in [TranscriptionUseCase.dictation, .translationChunk, .meetingPreview] {
            let plan = router.plan(for: TranscriptionFixtures.context(useCase: useCase))
            #expect(plan.candidates.map(\.engine) == [.fakeAlpha, .fakeBravo, .fakeCharlie])
        }
    }

    @Test("Empate de prioridade por caso de uso também desempata pelo id do motor")
    func perUseCasePriorityTieBreaksByEngineID() {
        // Base diferente, override que empata: o desempate tem que ser o mesmo do outro caminho,
        // senão o plano deixaria de ser determinístico exatamente onde a política nova manda.
        let catalog = TranscriptionCatalog(engines: [
            TranscriptionFixtures.engine(.fakeCharlie, priority: 1, priorityOverrides: [.meetingFinal: 7]),
            TranscriptionFixtures.engine(.fakeBravo, priority: 2, priorityOverrides: [.meetingFinal: 7]),
            TranscriptionFixtures.engine(.fakeAlpha, priority: 3, priorityOverrides: [.meetingFinal: 7])
        ])
        let router = TranscriptionRouter(catalog: catalog)

        #expect(
            router.plan(for: TranscriptionFixtures.context(useCase: .meetingFinal))
                .candidates.map(\.engine) == [.fakeAlpha, .fakeBravo, .fakeCharlie]
        )
        #expect(
            router.plan(for: TranscriptionFixtures.context(useCase: .dictation))
                .candidates.map(\.engine) == [.fakeCharlie, .fakeBravo, .fakeAlpha]
        )
    }

    @Test("Empate de prioridade desempata pelo id do motor, não pela ordem do catálogo")
    func priorityTieBreaksByEngineID() {
        let declarationOrder = TranscriptionCatalog(engines: [
            TranscriptionFixtures.engine(.fakeCharlie, priority: 7),
            TranscriptionFixtures.engine(.fakeAlpha, priority: 7),
            TranscriptionFixtures.engine(.fakeBravo, priority: 7)
        ])
        let reversed = TranscriptionCatalog(engines: declarationOrder.engines.reversed())

        let first = TranscriptionRouter(catalog: declarationOrder).plan(for: TranscriptionFixtures.context())
        let second = TranscriptionRouter(catalog: reversed).plan(for: TranscriptionFixtures.context())

        #expect(first.candidates.map(\.engine) == [.fakeAlpha, .fakeBravo, .fakeCharlie])
        #expect(first.candidates == second.candidates)
    }

    @Test("O mesmo contexto produz sempre o mesmo plano")
    func planningIsDeterministic() {
        let router = TranscriptionRouter(catalog: .shipping)
        let context = TranscriptionFixtures.context(useCase: .meetingFinal, language: .portugueseBrazil)

        #expect(router.plan(for: context) == router.plan(for: context))
    }

    @Test("Plano vazio quando nenhum motor serve")
    func emptyPlanWhenNothingFits() {
        let catalog = TranscriptionCatalog(engines: [
            TranscriptionFixtures.engine(.fakeAlpha, languages: [.english], detectsLanguage: false)
        ])
        let plan = TranscriptionRouter(catalog: catalog)
            .plan(for: TranscriptionFixtures.context(language: .portugueseBrazil))

        #expect(plan.isEmpty)
        #expect(plan.primary == nil)
        #expect(plan.rejectionReason(for: .fakeAlpha) == .languageUnsupported(.portugueseBrazil))
    }

    // MARK: - Idioma

    @Test("Motor que não fala o idioma pedido fica de fora")
    func unsupportedLanguageIsRejected() {
        let catalog = TranscriptionCatalog(engines: [
            TranscriptionFixtures.engine(.fakeAlpha, languages: [.english], detectsLanguage: false, priority: 0),
            TranscriptionFixtures.engine(.fakeBravo, languages: [.portuguese], detectsLanguage: false, priority: 1)
        ])
        let plan = TranscriptionRouter(catalog: catalog)
            .plan(for: TranscriptionFixtures.context(language: .portugueseBrazil))

        #expect(plan.candidates.map(\.engine) == [.fakeBravo])
        #expect(plan.rejectionReason(for: .fakeAlpha) == .languageUnsupported(.portugueseBrazil))
    }

    @Test("Pedido com idioma automático só vai para motores que detectam idioma")
    func automaticLanguageNeedsDetection() {
        let catalog = TranscriptionCatalog(engines: [
            TranscriptionFixtures.engine(.fakeAlpha, detectsLanguage: false, priority: 0),
            TranscriptionFixtures.engine(.fakeBravo, detectsLanguage: true, priority: 1)
        ])
        let plan = TranscriptionRouter(catalog: catalog)
            .plan(for: TranscriptionFixtures.context(language: nil))

        #expect(plan.candidates.map(\.engine) == [.fakeBravo])
        #expect(plan.rejectionReason(for: .fakeAlpha) == .languageUnsupported(nil))
    }

    @Test("Um motor que declara 'pt' atende um pedido 'pt-BR'")
    func genericLanguageCoversRegionalRequest() {
        let catalog = TranscriptionCatalog(engines: [
            TranscriptionFixtures.engine(.fakeAlpha, languages: [.portuguese], detectsLanguage: false)
        ])
        let plan = TranscriptionRouter(catalog: catalog)
            .plan(for: TranscriptionFixtures.context(language: .portugueseBrazil))

        #expect(plan.primary?.engine == .fakeAlpha)
    }

    @Test("pt-BR não atende um pedido pt-PT")
    func differentRegionsDoNotMatch() {
        let catalog = TranscriptionCatalog(engines: [
            TranscriptionFixtures.engine(.fakeAlpha, languages: [.portugueseBrazil], detectsLanguage: false)
        ])
        let plan = TranscriptionRouter(catalog: catalog)
            .plan(for: TranscriptionFixtures.context(language: TranscriptionLanguage("pt-PT")))

        #expect(plan.isEmpty)
    }

    // MARK: - Hardware (Intel simulado)

    @Test("Num Intel simulado, motores que exigem Apple Silicon somem")
    func intelDropsAppleSiliconEngines() {
        let catalog = TranscriptionCatalog(engines: [
            TranscriptionFixtures.engine(.fakeAlpha, hardware: .appleSiliconNeuralEngine, priority: 0),
            TranscriptionFixtures.engine(.fakeBravo, hardware: .none, priority: 10)
        ])
        let plan = TranscriptionRouter(catalog: catalog)
            .plan(for: TranscriptionFixtures.context(hardware: .intel8GB))

        #expect(plan.candidates.map(\.engine) == [.fakeBravo])
        #expect(plan.rejectionReason(for: .fakeAlpha) == .hardwareUnsupported)
    }

    @Test("Memória insuficiente derruba o modelo pesado e o motor cai para o leve")
    func lowMemoryFallsBackToLightModel() {
        let engine = TranscriptionFixtures.engine(
            .fakeAlpha,
            models: [
                TranscriptionFixtures.model(
                    .fakeHeavy,
                    engine: .fakeAlpha,
                    weight: .heavy,
                    hardware: .appleSiliconNeuralEngine
                ),
                TranscriptionFixtures.model(.fakeLight, engine: .fakeAlpha)
            ],
            defaultModel: .fakeHeavy
        )
        let router = TranscriptionRouter(catalog: TranscriptionCatalog(engines: [engine]))

        let roomy = router.plan(for: TranscriptionFixtures.context(hardware: .appleSilicon16GB))
        let tight = router.plan(for: TranscriptionFixtures.context(hardware: .appleSilicon4GB))

        #expect(roomy.primary?.model == .fakeHeavy)
        #expect(tight.primary?.model == .fakeLight)
    }

    @Test("Motor sem nenhum modelo viável é recusado por noViableModel, não por hardware")
    func engineWithoutUsableModelIsRejected() {
        let engine = TranscriptionFixtures.engine(
            .fakeAlpha,
            hardware: .none,
            models: [
                TranscriptionFixtures.model(
                    .fakeHeavy,
                    engine: .fakeAlpha,
                    weight: .heavy,
                    hardware: .appleSiliconNeuralEngine
                )
            ]
        )
        let plan = TranscriptionRouter(catalog: TranscriptionCatalog(engines: [engine]))
            .plan(for: TranscriptionFixtures.context(hardware: .intel8GB))

        #expect(plan.isEmpty)
        #expect(plan.rejectionReason(for: .fakeAlpha) == .noViableModel)
    }

    @Test("Modelo restrito a pt-BR não serve para um pedido em inglês")
    func modelLanguageRestrictionIsRespected() {
        let engine = TranscriptionFixtures.engine(
            .fakeAlpha,
            languages: [.portuguese, .english],
            detectsLanguage: false,
            models: [TranscriptionFixtures.model(.fakePtOnly, engine: .fakeAlpha, languages: [.portugueseBrazil])]
        )
        let router = TranscriptionRouter(catalog: TranscriptionCatalog(engines: [engine]))

        #expect(router.plan(for: TranscriptionFixtures.context(language: .portugueseBrazil)).primary?.model == .fakePtOnly)
        #expect(router.plan(for: TranscriptionFixtures.context(language: .englishUS)).isEmpty)
    }

    // MARK: - Caso de uso e modo

    @Test("Caso de uso fora da lista do motor é recusado")
    func unsupportedUseCaseIsRejected() {
        let catalog = TranscriptionCatalog(engines: [
            TranscriptionFixtures.engine(.fakeAlpha, useCases: [.dictation])
        ])
        let plan = TranscriptionRouter(catalog: catalog)
            .plan(for: TranscriptionFixtures.context(useCase: .meetingFinal))

        #expect(plan.isEmpty)
        #expect(plan.rejectionReason(for: .fakeAlpha) == .useCaseUnsupported(.meetingFinal))
    }

    @Test("Preview exige streaming: motor só de lote fica de fora")
    func previewRequiresStreamingEngine() {
        let catalog = TranscriptionCatalog(engines: [
            TranscriptionFixtures.engine(.fakeAlpha, batch: true, streaming: false, priority: 0),
            TranscriptionFixtures.engine(.fakeBravo, batch: false, streaming: true, priority: 1)
        ])
        let plan = TranscriptionRouter(catalog: catalog)
            .plan(for: TranscriptionFixtures.context(useCase: .meetingPreview))

        #expect(plan.candidates.map(\.engine) == [.fakeBravo])
        #expect(plan.rejectionReason(for: .fakeAlpha) == .modeUnsupported(.meetingPreview))
    }

    @Test("Casos em lote exigem batch: motor só de streaming fica de fora")
    func batchUseCasesRequireBatchEngine() {
        let catalog = TranscriptionCatalog(engines: [
            TranscriptionFixtures.engine(.fakeAlpha, batch: false, streaming: true)
        ])
        let plan = TranscriptionRouter(catalog: catalog)
            .plan(for: TranscriptionFixtures.context(useCase: .dictation))

        #expect(plan.isEmpty)
        #expect(plan.rejectionReason(for: .fakeAlpha) == .modeUnsupported(.dictation))
    }

    // MARK: - Seleção do usuário (sem strict)

    @Test("A escolha do usuário vai para o topo, com os demais como fallback")
    func userChoiceLeadsAndOthersFallBack() {
        let catalog = TranscriptionCatalog(engines: [
            TranscriptionFixtures.engine(.fakeAlpha, priority: 0),
            TranscriptionFixtures.engine(.fakeBravo, priority: 10),
            TranscriptionFixtures.engine(.fakeCharlie, priority: 20)
        ])
        let plan = TranscriptionRouter(catalog: catalog).plan(
            for: TranscriptionFixtures.context(selection: .manual(engine: .fakeCharlie))
        )

        #expect(plan.candidates.map(\.engine) == [.fakeCharlie, .fakeAlpha, .fakeBravo])
        #expect(plan.primary?.origin == .userSelection)
        #expect(plan.fallbacks.allSatisfy { $0.origin == .automatic })
        #expect(plan.candidates.map(\.rank) == [0, 1, 2])
    }

    @Test("Escolha inviável cai para a ordem automática inteira, com o motivo registrado")
    func unviableChoiceFallsBackToAutomatic() {
        let catalog = TranscriptionCatalog(engines: [
            TranscriptionFixtures.engine(.fakeAlpha, hardware: .appleSiliconNeuralEngine, priority: 0),
            TranscriptionFixtures.engine(.fakeBravo, priority: 10)
        ])
        let plan = TranscriptionRouter(catalog: catalog).plan(
            for: TranscriptionFixtures.context(
                hardware: .intel8GB,
                selection: .manual(engine: .fakeAlpha)
            )
        )

        #expect(plan.candidates.map(\.engine) == [.fakeBravo])
        #expect(plan.primary?.origin == .automatic)
        #expect(plan.rejectionReason(for: .fakeAlpha) == .hardwareUnsupported)
    }

    @Test("Motor desconhecido na seleção (versão antiga do app) não quebra o plano")
    func unknownEngineSelectionIsIgnored() {
        let catalog = TranscriptionCatalog(engines: [TranscriptionFixtures.engine(.fakeAlpha)])
        let plan = TranscriptionRouter(catalog: catalog).plan(
            for: TranscriptionFixtures.context(
                selection: .manual(engine: TranscriptionEngineID("motor-que-nao-existe"))
            )
        )

        #expect(plan.candidates.map(\.engine) == [.fakeAlpha])
        #expect(plan.rejectionReason(for: TranscriptionEngineID("motor-que-nao-existe")) == .unknownEngine)
    }

    @Test("Modelo pinado pelo usuário é respeitado")
    func pinnedModelIsHonored() {
        let engine = TranscriptionFixtures.engine(
            .fakeAlpha,
            models: [
                TranscriptionFixtures.model(.fakeLight, engine: .fakeAlpha),
                TranscriptionFixtures.model(.fakeHeavy, engine: .fakeAlpha, weight: .heavy)
            ],
            defaultModel: .fakeLight
        )
        let plan = TranscriptionRouter(catalog: TranscriptionCatalog(engines: [engine])).plan(
            for: TranscriptionFixtures.context(
                selection: .manual(engine: .fakeAlpha, model: .fakeHeavy)
            )
        )

        #expect(plan.primary?.model == .fakeHeavy)
        #expect(plan.primary?.origin == .userSelection)
    }

    @Test("Modelo pinado que não serve rebaixa o motor ao padrão dele, sem tirá-lo do plano")
    func pinnedModelUnavailableKeepsEngineWithDefaultModel() {
        let alpha = TranscriptionFixtures.engine(
            .fakeAlpha,
            models: [
                TranscriptionFixtures.model(.fakeLight, engine: .fakeAlpha),
                TranscriptionFixtures.model(
                    .fakeHeavy,
                    engine: .fakeAlpha,
                    weight: .heavy,
                    hardware: .appleSiliconNeuralEngine
                )
            ],
            defaultModel: .fakeLight,
            priority: 0
        )
        let bravo = TranscriptionFixtures.engine(.fakeBravo, priority: 10)
        let plan = TranscriptionRouter(catalog: TranscriptionCatalog(engines: [alpha, bravo])).plan(
            for: TranscriptionFixtures.context(
                hardware: .intel8GB,
                selection: .manual(engine: .fakeAlpha, model: .fakeHeavy)
            )
        )

        // O usuário pediu o pesado, que não cabe neste Mac. O motor não some do plano: volta
        // na posição automática dele, com o modelo padrão — deixar o usuário sem transcrição
        // seria pior, e a troca fica explícita (origem automática + rejeição registrada).
        #expect(plan.candidates.map(\.engine) == [.fakeAlpha, .fakeBravo])
        #expect(plan.primary?.model == .fakeLight)
        #expect(plan.primary?.origin == .automatic)
        #expect(plan.rejectionReason(for: .fakeAlpha) == .selectedModelUnavailable(.fakeHeavy))
        // É o único caso em que um motor aparece nas duas listas — e é proposital: é o par
        // que a UI usa para dizer "usando o padrão porque o modelo escolhido não cabe aqui".
        #expect(plan.candidates.map(\.engine).contains(.fakeAlpha))
    }

    @Test("Modelo pinado inexistente no motor é registrado, e o motor segue com o padrão")
    func pinnedModelFromAnotherEngineIsRejected() {
        let catalog = TranscriptionCatalog(engines: [
            TranscriptionFixtures.engine(.fakeAlpha, priority: 0),
            TranscriptionFixtures.engine(.fakeBravo, priority: 10)
        ])
        let plan = TranscriptionRouter(catalog: catalog).plan(
            for: TranscriptionFixtures.context(
                selection: .manual(engine: .fakeAlpha, model: .fakeHeavy)
            )
        )

        #expect(plan.rejectionReason(for: .fakeAlpha) == .selectedModelUnavailable(.fakeHeavy))
        #expect(plan.candidates.map(\.engine) == [.fakeAlpha, .fakeBravo])
        #expect(plan.primary?.model == .fakeLight)
        #expect(plan.primary?.origin == .automatic)
    }

    @Test("Catálogo de um motor só: modelo pinado inviável não deixa o plano vazio")
    func singleEngineCatalogNeverStarvesOnPinnedModel() {
        let engine = TranscriptionFixtures.engine(
            .fakeAlpha,
            models: [
                TranscriptionFixtures.model(.fakeLight, engine: .fakeAlpha),
                TranscriptionFixtures.model(
                    .fakeHeavy,
                    engine: .fakeAlpha,
                    weight: .heavy,
                    hardware: .appleSiliconNeuralEngine
                )
            ],
            defaultModel: .fakeLight
        )
        let plan = TranscriptionRouter(catalog: TranscriptionCatalog(engines: [engine])).plan(
            for: TranscriptionFixtures.context(
                hardware: .intel8GB,
                selection: .manual(engine: .fakeAlpha, model: .fakeHeavy)
            )
        )

        // Era este o caso que motivava a mudança: sem outro motor no catálogo, tirar o motor
        // escolhido do plano deixaria o app sem transcrever nada.
        #expect(plan.candidates.count == 1)
        #expect(plan.primary?.engine == .fakeAlpha)
        #expect(plan.primary?.model == .fakeLight)
        #expect(plan.primary?.origin == .automatic)
        #expect(plan.primary?.isFallback == false)
        #expect(plan.rejectionReason(for: .fakeAlpha) == .selectedModelUnavailable(.fakeHeavy))
    }

    @Test("Em strict, modelo pinado inviável continua sem candidato e mantém o motivo exato")
    func strictWithUnviablePinnedModelStaysEmpty() {
        let engine = TranscriptionFixtures.engine(
            .fakeAlpha,
            models: [
                TranscriptionFixtures.model(.fakeLight, engine: .fakeAlpha),
                TranscriptionFixtures.model(
                    .fakeHeavy,
                    engine: .fakeAlpha,
                    weight: .heavy,
                    hardware: .appleSiliconNeuralEngine
                )
            ],
            defaultModel: .fakeLight
        )
        let plan = TranscriptionRouter(catalog: TranscriptionCatalog(engines: [engine])).plan(
            for: TranscriptionFixtures.context(
                hardware: .intel8GB,
                selection: .manual(engine: .fakeAlpha, model: .fakeHeavy, strict: true)
            )
        )

        // O rebaixamento para o modelo padrão vale só fora do strict.
        #expect(plan.isEmpty)
        #expect(plan.isStrict)
        // E o motivo continua sendo o específico, não um genérico "ficou de fora por strict".
        #expect(plan.rejectionReason(for: .fakeAlpha) == .selectedModelUnavailable(.fakeHeavy))
    }

    // MARK: - strictEngineSelection

    @Test("Strict com escolha viável: um candidato só, e ele é o escolhido")
    func strictKeepsOnlyTheChosenEngine() {
        let catalog = TranscriptionCatalog(engines: [
            TranscriptionFixtures.engine(.fakeAlpha, priority: 0),
            TranscriptionFixtures.engine(.fakeBravo, priority: 10)
        ])
        let plan = TranscriptionRouter(catalog: catalog).plan(
            for: TranscriptionFixtures.context(
                selection: .manual(engine: .fakeBravo, strict: true)
            )
        )

        #expect(plan.isStrict)
        #expect(plan.candidates.map(\.engine) == [.fakeBravo])
        #expect(plan.fallbacks.isEmpty)
        #expect(plan.primary?.origin == .userSelection)
        #expect(plan.rejectionReason(for: .fakeAlpha) == .strictSelection)
    }

    @Test("Strict com escolha inviável devolve plano vazio — nunca outro motor")
    func strictWithUnviableChoiceYieldsEmptyPlan() {
        let catalog = TranscriptionCatalog(engines: [
            TranscriptionFixtures.engine(.fakeAlpha, hardware: .appleSiliconNeuralEngine, priority: 0),
            TranscriptionFixtures.engine(.fakeBravo, priority: 10)
        ])
        let plan = TranscriptionRouter(catalog: catalog).plan(
            for: TranscriptionFixtures.context(
                hardware: .intel8GB,
                selection: .manual(engine: .fakeAlpha, strict: true)
            )
        )

        #expect(plan.isEmpty)
        #expect(plan.isStrict)
        #expect(plan.rejectionReason(for: .fakeAlpha) == .hardwareUnsupported)
        // O bravo até serviria — e é justamente por isso que este teste existe: em strict ele
        // não pode ser oferecido no lugar do que o usuário pediu.
        #expect(plan.rejectionReason(for: .fakeBravo) == .strictSelection)
    }

    @Test("Strict com motor desconhecido não escorrega para outro motor")
    func strictWithUnknownEngineYieldsEmptyPlan() {
        let catalog = TranscriptionCatalog(engines: [TranscriptionFixtures.engine(.fakeAlpha)])
        let ghost = TranscriptionEngineID("motor-de-uma-versao-antiga")
        let plan = TranscriptionRouter(catalog: catalog).plan(
            for: TranscriptionFixtures.context(selection: .manual(engine: ghost, strict: true))
        )

        // Seleção salva por uma versão anterior do app + strict: o app fica sem transcrever e
        // diz por quê, em vez de usar um motor que o usuário não escolheu.
        #expect(plan.isEmpty)
        #expect(plan.rejectionReason(for: ghost) == .unknownEngine)
        #expect(plan.rejectionReason(for: .fakeAlpha) == .strictSelection)
    }

    @Test("Strict no modo automático também não tem fallback")
    func strictWithoutChoiceStillHasNoFallback() {
        let catalog = TranscriptionCatalog(engines: [
            TranscriptionFixtures.engine(.fakeAlpha, priority: 0),
            TranscriptionFixtures.engine(.fakeBravo, priority: 10),
            TranscriptionFixtures.engine(.fakeCharlie, priority: 20)
        ])
        let plan = TranscriptionRouter(catalog: catalog).plan(
            for: TranscriptionFixtures.context(
                selection: TranscriptionUserSelection(preferred: nil, strictEngineSelection: true)
            )
        )

        #expect(plan.candidates.map(\.engine) == [.fakeAlpha])
        #expect(plan.rejectionReason(for: .fakeBravo) == .strictSelection)
        #expect(plan.rejectionReason(for: .fakeCharlie) == .strictSelection)
    }

    @Test("Strict nunca produz mais de um candidato, em nenhum caso de uso ou hardware")
    func strictNeverProducesFallbacks() {
        let router = TranscriptionRouter(catalog: .shipping)
        let hardwares: [TranscriptionHardwareProfile] = [.appleSilicon16GB, .intel8GB, .appleSilicon4GB]
        let languages: [TranscriptionLanguage?] = [nil, .portugueseBrazil, .englishUS]

        for useCase in TranscriptionUseCase.allCases {
            for hardware in hardwares {
                for language in languages {
                    for engine in TranscriptionCatalog.shipping.engines.map(\.engine) {
                        let plan = router.plan(
                            for: TranscriptionRoutingContext(
                                useCase: useCase,
                                language: language,
                                hardware: hardware,
                                selection: .manual(engine: engine, strict: true)
                            )
                        )
                        #expect(plan.candidates.count <= 1)
                        #expect(plan.candidates.allSatisfy { !$0.isFallback })
                    }
                }
            }
        }
    }

    // MARK: - Invariantes gerais

    @Test("Ranks são sempre contíguos a partir de zero, e um motor nunca aparece duas vezes")
    func ranksAreContiguousAndEnginesUnique() {
        let router = TranscriptionRouter(catalog: .shipping)
        let selections: [TranscriptionUserSelection] = [
            .automatic,
            .manual(engine: .whisperKit),
            .manual(engine: .parakeet),
            .manual(engine: .appleSpeechAnalyzer),
            .manual(engine: .whisperKit, model: .whisperLargeV3Turbo)
        ]

        for useCase in TranscriptionUseCase.allCases {
            for hardware in [TranscriptionHardwareProfile.appleSilicon16GB, .intel8GB] {
                for selection in selections {
                    let plan = router.plan(
                        for: TranscriptionRoutingContext(
                            useCase: useCase,
                            language: .portugueseBrazil,
                            hardware: hardware,
                            selection: selection
                        )
                    )
                    #expect(plan.candidates.map(\.rank) == Array(0..<plan.candidates.count))
                    #expect(Set(plan.candidates.map(\.engine)).count == plan.candidates.count)
                }
            }
        }
    }

    @Test("Um motor está ou entre os candidatos ou entre as rejeições, nunca nos dois")
    func candidatesAndRejectionsAreDisjoint() {
        let router = TranscriptionRouter(catalog: .shipping)

        for useCase in TranscriptionUseCase.allCases {
            for hardware in [TranscriptionHardwareProfile.appleSilicon16GB, .intel8GB] {
                let plan = router.plan(
                    for: TranscriptionRoutingContext(
                        useCase: useCase,
                        language: .portugueseBrazil,
                        hardware: hardware,
                        selection: .automatic
                    )
                )
                let candidates = Set(plan.candidates.map(\.engine))
                let rejected = Set(plan.rejections.map(\.engine))
                #expect(candidates.isDisjoint(with: rejected))
                #expect(candidates.union(rejected).count == TranscriptionCatalog.shipping.engines.count)
            }
        }
    }
}
