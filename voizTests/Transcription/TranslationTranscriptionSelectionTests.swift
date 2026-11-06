import Testing
import Foundation

/// O mapeamento `AppSettings` → pedido do coordenador para o caso `.translationChunk` (T2.4b).
///
/// Esta suíte é o que impede a migração da `TranslationViewModel` de mudar comportamento. O
/// caminho antigo era curto e explícito — `TranscriptionService.shared` (WhisperKit) com
/// `configure(modelName: modelSize.whisperModelName)` — e três coisas dele precisam sobreviver
/// intactas à troca pelo coordenador:
///
/// 1. **o modelo é o do usuário**, não `small` fixo (é literalmente o título da tarefa no PLANO);
/// 2. **o motor é sempre o Whisper**, mesmo com Parakeet escolhido nas Configurações, porque a
///    tradução nunca leu `transcriptionEngine` (T1.4, decisão do Maestro em DECISOES);
/// 3. **não há fallback**: o plano tem um candidato só. Hoje uma falha do Whisper na tradução
///    falha e loga; carregar outro motor seria comportamento novo, e isso é decisão da Onda 6.
///
/// Tudo aqui é função pura de valores — nenhum view model é instanciado (o alvo `voizTests` não
/// tem host app, e o `init` da `TranslationViewModel` dispara permissão de Acessibilidade e carga
/// de modelo).
@Suite("Tradução — seleção efetiva e plano do .translationChunk")
struct TranslationTranscriptionSelectionTests {

    private let router = TranscriptionRouter()

    /// O plano que a tradução de fato produz, com a seleção que a view model monta.
    private func translationPlan(
        _ settings: AppSettings,
        language: TranscriptionLanguage? = .portuguese,
        hardware: TranscriptionHardwareProfile = .appleSilicon16GB
    ) -> TranscriptionRoutingPlan {
        router.plan(
            for: TranscriptionRoutingContext(
                useCase: .translationChunk,
                language: language,
                hardware: hardware,
                selection: settings.transcriptionSelection(for: .translationChunk, strict: true)
            )
        )
    }

    // MARK: - O modelo é o do usuário

    @Test("Instalação nova: Whisper small — o mesmo que o serviço legado carregava")
    func defaultsKeepWhisperSmall() {
        let choice = AppSettings().effectiveTranscriptionChoice(for: .translationChunk)

        #expect(choice.engine == .whisperKit)
        #expect(choice.model == .whisperSmall)
    }

    @Test("O modelo configurado pelo usuário é preservado — nada de fixar small")
    func theConfiguredModelSizeIsPreserved() {
        // O ponto da tarefa: `modelSize` é o que o `configure(modelName:)` legado aplicava, e o
        // modo automático do roteador devolveria `small` para todo mundo.
        let expected: [AppSettings.ModelSize: TranscriptionModelID] = [
            .base: .whisperBase,
            .small: .whisperSmall,
            .medium: .whisperMedium,
            .largeTurbo: .whisperLargeV3Turbo
        ]

        for (size, model) in expected {
            var settings = AppSettings()
            settings.modelSize = size

            let choice = settings.effectiveTranscriptionChoice(for: .translationChunk)
            #expect(choice.engine == .whisperKit, "\(size.rawValue)")
            #expect(choice.model == model, "\(size.rawValue)")
            #expect(choice.model?.rawValue == size.whisperModelName, "\(size.rawValue)")
        }
    }

    @Test("Todo modelo alcançável pelas Configurações existe no catálogo de produção")
    func everyReachableModelExistsInTheShippingCatalog() {
        // Guarda contra o modo mais silencioso de quebrar a tradução: sob `strict`, um modelo que
        // o catálogo não conhece não vira fallback — vira plano VAZIO, e a tradução para de
        // funcionar sem erro de compilação em lugar nenhum.
        for size in AppSettings.ModelSize.allCases {
            var settings = AppSettings()
            settings.modelSize = size

            let plan = translationPlan(settings)
            #expect(plan.candidates.count == 1, "\(size.rawValue)")
            #expect(plan.primary?.model.rawValue == size.whisperModelName, "\(size.rawValue)")
        }
    }

    // MARK: - O motor é sempre o Whisper

    @Test("Com Parakeet configurado globalmente, a tradução continua no Whisper")
    func parakeetSelectedGloballyDoesNotChangeTranslation() {
        // A tradução nunca leu `transcriptionEngine`: ela fala direto com o `TranscriptionService`.
        // Migrá-la para Parakeet trocaria o motor dela em silêncio (DECISOES, T1.4).
        var settings = AppSettings()
        settings.transcriptionEngine = .parakeet
        settings.modelSize = .medium

        let choice = settings.effectiveTranscriptionChoice(for: .translationChunk)
        #expect(choice.engine == .whisperKit)
        #expect(choice.model == .whisperMedium)

        // E o plano inteiro: nem como fallback o Parakeet entra.
        let plan = translationPlan(settings)
        #expect(plan.candidates.map(\.engine) == [.whisperKit])
        #expect(plan.primary?.model == .whisperMedium)
    }

    @Test("O ditado com Parakeet vai para o Parakeet — a exceção é da tradução, não do mapa")
    func dictationStillHonoursTheChosenEngine() {
        // Contraprova: se `effectiveTranscriptionChoice` devolvesse Whisper para todo mundo, o
        // teste acima passaria por acidente e o ditado da T2.4a herdaria o bug.
        var settings = AppSettings()
        settings.transcriptionEngine = .parakeet

        #expect(settings.effectiveTranscriptionChoice(for: .dictation).engine == .parakeet)
        #expect(settings.effectiveTranscriptionChoice(for: .translationChunk).engine == .whisperKit)
    }

    // MARK: - Modo avançado

    @Test("A escolha pinada no avançado vence a leitura legada")
    func anAdvancedPinWinsOverTheLegacyReading() {
        var settings = AppSettings()
        settings.modelSize = .small
        settings.transcriptionSelectionMode = .advanced
        settings.transcriptionSelections[.translationChunk] = TranscriptionEngineChoice(
            engine: .whisperKit,
            model: .whisperLargeV3Turbo
        )

        let choice = settings.effectiveTranscriptionChoice(for: .translationChunk)
        #expect(choice.model == .whisperLargeV3Turbo)
    }

    @Test("Avançado sem pino para a tradução cai na leitura legada, não no automático")
    func advancedWithoutAPinFallsBackToTheLegacyReading() {
        // O usuário pode pinar o ditado e deixar a tradução em paz. Cair no automático aqui
        // devolveria `small` e perderia o `modelSize` dele.
        var settings = AppSettings()
        settings.modelSize = .medium
        settings.transcriptionSelectionMode = .advanced
        settings.transcriptionSelections[.dictation] = TranscriptionEngineChoice(engine: .parakeet)

        let choice = settings.effectiveTranscriptionChoice(for: .translationChunk)
        #expect(choice.engine == .whisperKit)
        #expect(choice.model == .whisperMedium)
    }

    @Test("Seleção guardada de uma passagem pelo avançado não vale no automático")
    func aStoredSelectionDoesNotApplyInAutomaticMode() {
        var settings = AppSettings()
        settings.modelSize = .base
        settings.transcriptionSelections[.translationChunk] = TranscriptionEngineChoice(
            engine: .parakeet,
            model: .parakeetTDT06BV3
        )
        settings.transcriptionSelectionMode = .automatic

        let choice = settings.effectiveTranscriptionChoice(for: .translationChunk)
        #expect(choice.engine == .whisperKit)
        #expect(choice.model == .whisperBase)
    }

    // MARK: - Strict: um candidato, nunca fallback

    @Test("O plano da tradução tem um candidato só, marcado como escolha do usuário")
    func theTranslationPlanIsStrictAndSingle() {
        let plan = translationPlan(AppSettings())

        #expect(plan.isStrict)
        #expect(plan.candidates.count == 1)
        #expect(plan.fallbacks.isEmpty)
        #expect(plan.primary?.engine == .whisperKit)
        #expect(plan.primary?.model == .whisperSmall)
        #expect(plan.primary?.rank == 0)
        // `userSelection` e não `automatic`: o que roda é o que está nas Configurações, e a
        // proveniência precisa dizer isso.
        #expect(plan.primary?.origin == .userSelection)
    }

    @Test("Nem num Intel, nem em detecção automática, a tradução ganha um segundo candidato")
    func noContextAddsAFallbackToTranslation() {
        // Num Intel o Parakeet e o motor Apple já sairiam por hardware; o que este teste trava é o
        // outro lado — que em nenhum contexto o plano da tradução cresça.
        let contexts: [(String, TranscriptionLanguage?, TranscriptionHardwareProfile)] = [
            ("pt em Apple Silicon", .portuguese, .appleSilicon16GB),
            ("en em Apple Silicon", .english, .appleSilicon16GB),
            ("auto em Apple Silicon", nil, .appleSilicon16GB),
            ("pt em Intel", .portuguese, .intel8GB)
        ]

        for (name, language, hardware) in contexts {
            let plan = translationPlan(AppSettings(), language: language, hardware: hardware)
            #expect(plan.candidates.map(\.engine) == [.whisperKit], "\(name)")
            #expect(plan.isStrict, "\(name)")
        }
    }

    // MARK: - Peso do modelo legado (ponte TranscriptionForeignWeightOwner)

    @Test("O catálogo é a única fonte de 'isto é pesado?' — e desconhecido conta como pesado")
    func theCatalogAnswersWhatIsHeavy() {
        // O dono de pesos legado (`LegacyWhisperWeightOwner`, no holder) só libera o
        // `TranscriptionService.shared` quando o que ele segura é pesado — senão o ditado
        // recarregaria 480 MB toda vez que a tradução aquecesse um modelo grande. Quem responde é
        // este catálogo, o mesmo que o coordenador consulta: duas leituras de "pesado" no mesmo
        // processo seria o jeito mais silencioso de a regra de um-pesado-residente falhar.
        //
        // O dono está **desligado** na T2.4b (DECISOES, 2026-08-10: liberar pesos do serviço legado
        // no meio de uma reunião é pior que a duplicação; a T2.5 liga). O que estes dois testes
        // travam é o `weight(of:in:)` que o coordenador JÁ usa hoje na regra de um pesado residente
        // — e, de quebra, deixam pronta a resposta que a T2.5 vai precisar.
        let catalog = TranscriptionCatalog.shipping

        // O default do app não é pesado — é a consequência aceita da T2.3, e o filtro a preserva.
        #expect(catalog.weight(of: .whisperSmall, in: .whisperKit) == .light)
        #expect(catalog.weight(of: .whisperBase, in: .whisperKit) == .light)
        // Os que motivam a liberação: com estes configurados, tradução e ditado duplicariam 1,5 GB.
        #expect(catalog.weight(of: .whisperMedium, in: .whisperKit) == .heavy)
        #expect(catalog.weight(of: .whisperLargeV3Turbo, in: .whisperKit) == .heavy)
        // Desconhecido: o erro seguro é manter um só.
        #expect(catalog.weight(of: TranscriptionModelID("nao-existe"), in: .whisperKit) == .heavy)
        #expect(catalog.weight(of: .whisperSmall, in: TranscriptionEngineID("motor-nao-existe")) == .heavy)
    }

    @Test("Cada tamanho das Configurações decide sozinho se o serviço legado precisaria liberar")
    func eachConfiguredSizeDecidesTheLegacyRelease() {
        // Espelha o que o dono legado faz quando a T2.5 o ligar: pega o modelo configurado e
        // pergunta o peso ao catálogo.
        let expected: [AppSettings.ModelSize: TranscriptionModelWeight] = [
            .base: .light,
            .small: .light,
            .medium: .heavy,
            .largeTurbo: .heavy
        ]

        for (size, weight) in expected {
            var settings = AppSettings()
            settings.modelSize = size
            let model = TranscriptionModelID(settings.modelSize.whisperModelName)

            #expect(
                TranscriptionCatalog.shipping.weight(of: model, in: .whisperKit) == weight,
                "\(size.rawValue)"
            )
        }
    }

    // MARK: - Idioma

    @Test("Todo idioma da tela vira um idioma de pedido — nenhum vira detecção")
    func theUILanguageMapsToTheRequestLanguage() {
        // O `rawValue` do enum da tela **é** o código que vai nas `DecodingOptions` do Whisper e
        // o `primaryCode` que o roteador compara. Um caso novo em `Language` cujo rawValue não
        // fosse o código do idioma passaria despercebido no app e apareceria como transcript no
        // idioma errado — por isso a checagem é sobre `allCases`, e não sobre uma lista escrita
        // aqui à mão.
        for language in Language.allCases {
            #expect(language.transcriptionLanguage.rawValue == language.rawValue)
        }

        #expect(Language.portuguese.transcriptionLanguage == .portuguese)
        #expect(Language.english.transcriptionLanguage == .english)
        #expect(Language.japanese.transcriptionLanguage == .japanese)
    }
}
