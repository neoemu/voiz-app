import Foundation

/// Peso de um modelo na máquina. O plano da missão só distingue dois níveis porque só existe
/// uma regra que depende disso: **um** modelo pesado residente por vez. O Whisper `small`
/// (~480 MB) explicitamente não conta como pesado.
nonisolated enum TranscriptionModelWeight: String, Sendable, Hashable, Codable, CaseIterable {
    case light
    case heavy
}

/// Um conjunto de pesos que um motor sabe carregar.
///
/// `languages` vazio significa "os mesmos do motor" — o caso comum. Só modelos que restringem
/// o idioma além do motor (um fine-tune só de pt-BR num motor multilíngue) preenchem a lista.
nonisolated struct TranscriptionModelDescriptor: Sendable, Equatable, Hashable {
    var id: TranscriptionModelID
    var engine: TranscriptionEngineID
    /// Nome do produto/checkpoint (marca, não texto de UI traduzível).
    var productName: String
    var languages: [TranscriptionLanguage]
    var weight: TranscriptionModelWeight
    /// Tamanho aproximado do download, em bytes. `0` = não baixamos nada (modelo do sistema).
    var downloadBytes: Int64
    /// Exigência própria do modelo, além da do motor (um modelo grande pede mais memória que
    /// o motor em si).
    var hardware: TranscriptionHardwareRequirement

    init(
        id: TranscriptionModelID,
        engine: TranscriptionEngineID,
        productName: String,
        languages: [TranscriptionLanguage] = [],
        weight: TranscriptionModelWeight,
        downloadBytes: Int64,
        hardware: TranscriptionHardwareRequirement = .none
    ) {
        self.id = id
        self.engine = engine
        self.productName = productName
        self.languages = languages
        self.weight = weight
        self.downloadBytes = downloadBytes
        self.hardware = hardware
    }

    /// O modelo atende o idioma pedido? `nil` = detecção automática, que é decisão do motor,
    /// não do modelo — por isso o modelo nunca barra o pedido automático.
    func supports(language: TranscriptionLanguage?) -> Bool {
        guard let language else { return true }
        guard !languages.isEmpty else { return true }
        return languages.contains { $0.matches(language) }
    }
}

/// O que um motor sabe fazer: idiomas, casos de uso, batch/streaming, hardware mínimo e os
/// modelos dele.
///
/// É dado, não código: o roteador é uma função destes descritores, então trocar a política de
/// escolha é trocar valores — e um teste pode montar um catálogo inteiro de motores falsos sem
/// instanciar nada real.
nonisolated struct TranscriptionEngineDescriptor: Sendable, Equatable, Hashable {
    var engine: TranscriptionEngineID
    /// Nome do produto (marca: "WhisperKit", "Parakeet v3"). Não é copy de UI e por isso não
    /// entra no `Localizable.xcstrings`; a tela da Onda 6 formata em volta dele.
    var productName: String
    var supportedLanguages: [TranscriptionLanguage]
    /// O motor detecta o idioma sozinho? Se não, um pedido com `language == nil` não pode ir
    /// para ele.
    var detectsLanguageAutomatically: Bool
    var supportedUseCases: Set<TranscriptionUseCase>
    var supportsBatch: Bool
    var supportsStreaming: Bool
    var supportsVocabulary: Bool
    var hardware: TranscriptionHardwareRequirement
    /// Modelos do motor, na ordem de preferência do modo automático.
    var models: [TranscriptionModelDescriptor]
    /// Modelo preferido quando o usuário não pinou nenhum. `nil` = o primeiro viável de `models`.
    var defaultModel: TranscriptionModelID?
    /// Ordem **base** do modo automático: **menor vem primeiro**. Empates desempatam pelo id do
    /// motor, para o plano ser determinístico.
    ///
    /// Vale para todo caso de uso que não tenha entrada em `automaticPriorityOverrides`.
    var automaticPriority: Int
    /// Ordem do modo automático **para um caso de uso específico**, quando ela contraria a base.
    ///
    /// Existe porque a qualidade de um motor não é uma propriedade dele sozinho: ela depende do
    /// material. O Apple SpeechAnalyzer perde para o Whisper como âncora geral (locale fixo, e por
    /// isso fora do idioma automático) e ganha no transcript pós-call de reunião em pt-BR — medido
    /// na reunião real 7FCA e no spike da Onda 3. Sem este eixo, promover o Apple no pós-call
    /// promoveria junto o ditado, a tradução e a prévia, que é exatamente o que a regra 6 do PLANO
    /// proíbe (e o que travou a Q-Apple).
    ///
    /// É **dado**, como o resto do descritor: a política versionada da T6.1 troca estes números
    /// sem tocar uma linha do `TranscriptionRouter`. Vazio = o motor tem uma ordem só, que é o caso
    /// comum.
    var automaticPriorityOverrides: [TranscriptionUseCase: Int]
    /// Motor ainda em avaliação. Não muda o roteamento — é rótulo para a UI da Onda 6.
    var isExperimental: Bool

    init(
        engine: TranscriptionEngineID,
        productName: String,
        supportedLanguages: [TranscriptionLanguage],
        detectsLanguageAutomatically: Bool,
        supportedUseCases: Set<TranscriptionUseCase>,
        supportsBatch: Bool,
        supportsStreaming: Bool,
        hardware: TranscriptionHardwareRequirement,
        models: [TranscriptionModelDescriptor],
        defaultModel: TranscriptionModelID? = nil,
        automaticPriority: Int,
        automaticPriorityOverrides: [TranscriptionUseCase: Int] = [:],
        isExperimental: Bool = false,
        supportsVocabulary: Bool = false
    ) {
        self.engine = engine
        self.productName = productName
        self.supportedLanguages = supportedLanguages
        self.detectsLanguageAutomatically = detectsLanguageAutomatically
        self.supportedUseCases = supportedUseCases
        self.supportsBatch = supportsBatch
        self.supportsStreaming = supportsStreaming
        self.hardware = hardware
        self.models = models
        self.defaultModel = defaultModel
        self.automaticPriority = automaticPriority
        self.automaticPriorityOverrides = automaticPriorityOverrides
        self.isExperimental = isExperimental
        self.supportsVocabulary = supportsVocabulary
    }

    /// A posição deste motor na ordem automática **deste** caso de uso.
    ///
    /// É a única leitura de prioridade que o roteador faz: quem não tem override responde a base,
    /// então acrescentar o eixo não mexeu em motor nenhum que não pediu.
    func automaticPriority(for useCase: TranscriptionUseCase) -> Int {
        automaticPriorityOverrides[useCase] ?? automaticPriority
    }

    /// O motor atende o idioma pedido? `nil` significa detecção automática, que só motores com
    /// `detectsLanguageAutomatically` aceitam.
    func supports(language: TranscriptionLanguage?) -> Bool {
        guard let language else { return detectsLanguageAutomatically }
        return supportedLanguages.contains { $0.matches(language) }
    }

    /// O motor atende o modo (streaming ou lote) que o caso de uso exige?
    func supports(useCase: TranscriptionUseCase) -> Bool {
        guard supportedUseCases.contains(useCase) else { return false }
        return useCase.requiresStreaming ? supportsStreaming : supportsBatch
    }

    func model(_ id: TranscriptionModelID) -> TranscriptionModelDescriptor? {
        models.first { $0.id == id }
    }
}

/// O conjunto de motores que o app conhece.
///
/// Não é singleton: é um valor que se passa para o `TranscriptionRouter`. `.shipping` é só a
/// constante com os dados de produção — os testes montam catálogos próprios.
nonisolated struct TranscriptionCatalog: Sendable, Equatable {
    /// Descritores na ordem em que foram declarados. A ordem **não** decide roteamento
    /// (quem decide é `automaticPriority(for:)`); serve para listagens estáveis na UI.
    var engines: [TranscriptionEngineDescriptor]

    init(engines: [TranscriptionEngineDescriptor]) {
        self.engines = engines
    }

    func descriptor(for engine: TranscriptionEngineID) -> TranscriptionEngineDescriptor? {
        engines.first { $0.engine == engine }
    }

    /// Todos os modelos de todos os motores. Um mesmo `TranscriptionModelID` pode aparecer em
    /// dois motores (o mesmo checkpoint rodando em runtimes diferentes), então a busca por
    /// modelo é sempre no contexto de um motor.
    var allModels: [TranscriptionModelDescriptor] {
        engines.flatMap(\.models)
    }

    /// O peso deste modelo neste motor, segundo o catálogo.
    ///
    /// **Modelo desconhecido conta como pesado**: a regra de "um pesado residente" existe para não
    /// estourar memória, e o erro seguro é manter um só. O `Whisper small` é `.light` no descritor
    /// — a regra do plano ("small não conta como pesado") mora lá, em dado, não em código.
    ///
    /// Existe como função do catálogo, e não só dentro do coordenador, porque a T2.4b precisa da
    /// mesma resposta fora dele: o dono de pesos legado (`TranscriptionForeignWeightOwner` sobre o
    /// `TranscriptionService.shared`) só libera quando o que ele segura é pesado, e duas leituras
    /// diferentes de "pesado" no mesmo processo seria a maneira mais silenciosa de a regra falhar.
    func weight(of model: TranscriptionModelID, in engine: TranscriptionEngineID) -> TranscriptionModelWeight {
        descriptor(for: engine)?.model(model)?.weight ?? .heavy
    }
}

nonisolated extension TranscriptionCatalog {
    /// Catálogo de produção.
    ///
    /// Descreve os motores **como eles serão integrados** nas Ondas 2–4: hoje nada aqui é
    /// executado, porque os adapters ainda não existem e ninguém chama o roteador. Quando um
    /// adapter entrar, ele passa a responder por este descritor — se divergir, o descritor é
    /// que está errado.
    ///
    /// As prioridades **base** reproduzem o comportamento atual do app: WhisperKit primeiro em
    /// ditado, tradução e prévia. A política automática completa, com os vencedores do benchmark,
    /// continua sendo a T6.1; mexer nesses números fora de uma exceção autorizada mudaria
    /// comportamento, o que a regra 6 do plano proíbe.
    ///
    /// **A exceção que existe hoje (Q2, autorizada pelo humano em 2026-08-18, registrada em
    /// DECISOES):** `.meetingFinal` tem ordem própria — Apple SpeechAnalyzer, Whisper, Parakeet —
    /// via `automaticPriorityOverrides`. Ela vale só para o transcript oficial da reunião, e só
    /// quando o idioma é explícito: com idioma automático o Apple sai do plano pelo
    /// `detectsLanguageAutomatically: false` e o Whisper volta a ser o rank 0 sem nenhum caso
    /// especial no roteador. Escolha manual do usuário continua vencendo a ordem automática em
    /// qualquer caso de uso — a exceção é sobre o **automático**.
    ///
    /// O TAGARELA ainda não está aqui de propósito: os artefatos CoreML dele nascem na Onda 5,
    /// e um descritor com tamanho e requisitos inventados seria pior que a ausência.
    static let shipping = TranscriptionCatalog(engines: [
        .whisperKit,
        .appleSpeechAnalyzer,
        .parakeet
    ])
}

nonisolated extension TranscriptionEngineDescriptor {
    /// WhisperKit: o fallback eterno. Roda em qualquer Mac, fala os dois idiomas e detecta
    /// idioma sozinho — é o único motor que pode aparecer sozinho num plano.
    ///
    /// O streaming dele não é nativo: quem serve o preview é a janela deslizante da T4.1
    /// (`WhisperSlidingWindowPreviewSession`), que é exatamente o que o
    /// `MeetingLivePreviewService` já faz hoje. Por isso `supportsStreaming` é `true`.
    static let whisperKit = TranscriptionEngineDescriptor(
        engine: .whisperKit,
        productName: "WhisperKit",
        // Os sete do seletor. O modelo multilíngue conhece ~99, mas declarar o que o app não
        // oferece faria a guarda de idioma cogitar alvos que o usuário nunca pode escolher —
        // `servableLanguages` sai DESTA lista.
        supportedLanguages: [.portuguese, .english, .spanish, .french, .german, .japanese, .chinese],
        detectsLanguageAutomatically: true,
        supportedUseCases: Set(TranscriptionUseCase.allCases),
        supportsBatch: true,
        supportsStreaming: true,
        hardware: .none,
        models: [
            TranscriptionModelDescriptor(
                id: .whisperSmall,
                engine: .whisperKit,
                productName: "Whisper small",
                weight: .light,
                downloadBytes: 480 * 1024 * 1024
            ),
            TranscriptionModelDescriptor(
                id: .whisperBase,
                engine: .whisperKit,
                productName: "Whisper base",
                weight: .light,
                downloadBytes: 140 * 1024 * 1024
            ),
            TranscriptionModelDescriptor(
                id: .whisperMedium,
                engine: .whisperKit,
                productName: "Whisper medium",
                weight: .heavy,
                downloadBytes: 1_500 * 1024 * 1024
            ),
            TranscriptionModelDescriptor(
                id: .whisperLargeV3Turbo,
                engine: .whisperKit,
                productName: "Whisper large-v3 turbo",
                weight: .heavy,
                downloadBytes: 1_500 * 1024 * 1024
            )
        ],
        // O mesmo default de hoje (`TranscriptionService.defaultModelName`).
        defaultModel: .whisperSmall,
        automaticPriority: 0,
        // Q2: no transcript oficial da reunião o Whisper passa a ser o **fallback** do Apple, e
        // não a primeira escolha. Continua primeiro em ditado, tradução e prévia — e volta a ser
        // o rank 0 do próprio `.meetingFinal` quando o idioma é automático, porque aí o Apple não
        // entra no plano. `small` segue sendo o modelo padrão dele: o rebaixamento é de posição,
        // não de modelo.
        automaticPriorityOverrides: [.meetingFinal: 1],
        supportsVocabulary: true
    )

    /// `SpeechAnalyzer`/`SpeechTranscriber` do macOS 26. A sonda da T0.2 confirmou pt-BR e
    /// en-US com asset instalável, e batch + streaming no mesmo motor.
    ///
    /// Exige Apple Silicon: a sonda só rodou em Apple Silicon, e assumir o contrário colocaria
    /// um motor não verificado à frente do WhisperKit num Intel.
    ///
    /// **Nunca é escolhido em modo automático de idioma.** É o que `detectsLanguageAutomatically:
    /// false` expressa: um pedido com `language == nil` cai no `supports(language:)` do descritor
    /// e o motor sai do plano com `.languageUnsupported(nil)`. Não é preferência — o locale é fixo
    /// no módulo do `SpeechTranscriber`, então não existe nada para o motor detectar.
    ///
    /// Um modelo **por locale** (T3.3), e não um modelo multilíngue: como o locale é fixo, é o
    /// `TranscriptionModelID` que o carrega. Sem isso o roteador ofereceria o mesmo id para pt-BR
    /// e en-US e a proveniência gravada não diria qual locale produziu o texto. As `languages` de
    /// cada modelo são o que faz `automaticModel(of:in:)` escolher o id certo para o idioma
    /// pedido. `defaultModel` fica `nil` de propósito: fixar um dos dois faria o modelo do locale
    /// errado ser tentado antes do certo.
    ///
    /// `weight: .heavy` é **conservador até a medição de RSS na Onda 3**, e não uma afirmação
    /// sobre o tamanho do download. `TranscriptionModelWeight` é peso **na máquina**: este motor
    /// mantém retenção `.processLifetime` dos modelos de fala do sistema, que é RAM real — a mesma
    /// que o `unload()` existe para liberar. Classificar como `.light` porque `downloadBytes == 0`
    /// faria o coordenador da T2.3 contabilizar zero e permitir o Whisper large-v3-turbo (1,5 GB,
    /// `.heavy`) residente ao mesmo tempo, satisfazendo a regra no papel e violando-a na máquina.
    /// A T3.1/T3.2 medem RSS; a classificação final sai desse número, e a reclassificação (se o
    /// número permitir `.light`) é da T6.1, com o dado em mãos.
    ///
    /// ## Rank 0 do `.meetingFinal` (Q2)
    ///
    /// A promoção saiu de medição, não de preferência: no spike da Onda 3 este motor fez 165× RTF
    /// com 0,3 s de CPU e 102 MB de RSS para 331 s de áudio, e o melhor WER dos itens longos
    /// (3,1%); na reunião REAL 7FCA, com o locale correto, produziu texto em 31/31 lotes nos dois
    /// canais, com p50 de 0,111–0,160 s por lote de 26,5 s contra 0,185–0,946 s do Whisper small e
    /// ~20× menos CPU. É o caso de uso em que o locale fixo **não** é limitação: a reunião já
    /// congela o idioma no `TranscriptionPlanSnapshot` no início da gravação.
    ///
    /// **O preço da promoção, e por que a guarda de idioma é condição dela:** locale errado aqui
    /// não degrada, **apaga** — o transcritor descarta a fala que não é do locale e o lote volta
    /// vazio. Com o Whisper o mesmo erro produzia quasi-tradução (texto plausível e infiel, que foi
    /// o que aconteceu na 7FCA com `language=en` e fala pt-BR); com o Apple produz silêncio. Por
    /// isso a Q2 entrou junto com `TranscriptionLanguageProbe` e `TranscriptionLanguageGuard`, e é
    /// por isso que a guarda mora fora deste arquivo: ela vale para o plano, não para o motor.
    static let appleSpeechAnalyzer = TranscriptionEngineDescriptor(
        engine: .appleSpeechAnalyzer,
        productName: "Apple SpeechAnalyzer",
        // Uma variante por idioma do seletor. Todas confirmadas em `SpeechTranscriber
        // .supportedLocales` nesta máquina em 29/08/2026 — a lista do sistema também traz
        // de_AT/de_CH, es_MX, fr_CA, zh_TW e yue_CN, que ficam de fora porque o seletor do app
        // não tem como pedi-las.
        supportedLanguages: [
            .portugueseBrazil, .englishUS, .spanishSpain, .frenchFrance,
            .germanGermany, .japaneseJapan, .chineseChina
        ],
        detectsLanguageAutomatically: false,
        supportedUseCases: Set(TranscriptionUseCase.allCases),
        supportsBatch: true,
        supportsStreaming: true,
        hardware: TranscriptionHardwareRequirement(requiresAppleSilicon: true),
        models: [
            TranscriptionModelDescriptor(
                id: .appleSystemSpeechPTBR,
                engine: .appleSpeechAnalyzer,
                productName: "Modelo de fala do sistema (pt-BR)",
                languages: [.portugueseBrazil],
                weight: .heavy,
                downloadBytes: 0,
                hardware: TranscriptionHardwareRequirement(requiresAppleSilicon: true)
            ),
            TranscriptionModelDescriptor(
                id: .appleSystemSpeechENUS,
                engine: .appleSpeechAnalyzer,
                productName: "Modelo de fala do sistema (en-US)",
                languages: [.englishUS],
                weight: .heavy,
                downloadBytes: 0,
                hardware: TranscriptionHardwareRequirement(requiresAppleSilicon: true)
            ),
            TranscriptionModelDescriptor(
                id: .appleSystemSpeechESES,
                engine: .appleSpeechAnalyzer,
                productName: "Modelo de fala do sistema (es-ES)",
                languages: [.spanishSpain],
                weight: .heavy,
                downloadBytes: 0,
                hardware: TranscriptionHardwareRequirement(requiresAppleSilicon: true)
            ),
            TranscriptionModelDescriptor(
                id: .appleSystemSpeechFRFR,
                engine: .appleSpeechAnalyzer,
                productName: "Modelo de fala do sistema (fr-FR)",
                languages: [.frenchFrance],
                weight: .heavy,
                downloadBytes: 0,
                hardware: TranscriptionHardwareRequirement(requiresAppleSilicon: true)
            ),
            TranscriptionModelDescriptor(
                id: .appleSystemSpeechDEDE,
                engine: .appleSpeechAnalyzer,
                productName: "Modelo de fala do sistema (de-DE)",
                languages: [.germanGermany],
                weight: .heavy,
                downloadBytes: 0,
                hardware: TranscriptionHardwareRequirement(requiresAppleSilicon: true)
            ),
            TranscriptionModelDescriptor(
                id: .appleSystemSpeechJAJP,
                engine: .appleSpeechAnalyzer,
                productName: "Modelo de fala do sistema (ja-JP)",
                languages: [.japaneseJapan],
                weight: .heavy,
                downloadBytes: 0,
                hardware: TranscriptionHardwareRequirement(requiresAppleSilicon: true)
            ),
            TranscriptionModelDescriptor(
                id: .appleSystemSpeechZHCN,
                engine: .appleSpeechAnalyzer,
                productName: "Modelo de fala do sistema (zh-CN)",
                languages: [.chineseChina],
                weight: .heavy,
                downloadBytes: 0,
                hardware: TranscriptionHardwareRequirement(requiresAppleSilicon: true)
            )
        ],
        automaticPriority: 50,
        // Q2: primeiro no transcript oficial da reunião. Fora dele a base 50 continua valendo —
        // o ditado e a tradução seguem no Whisper, como a regra 6 exige até a T6.1.
        automaticPriorityOverrides: [.meetingFinal: 0],
        supportsVocabulary: true
    )

    /// Parakeet v3 via FluidAudio: rápido e multilíngue, mas ainda experimental (spike em
    /// avaliação). Modelo CoreML pesado, logo Apple Silicon com Neural Engine.
    ///
    /// Sem streaming: o adapter da T2.2 é batch. Fora do preview, portanto.
    static let parakeet = TranscriptionEngineDescriptor(
        engine: .parakeet,
        productName: "Parakeet v3 (FluidAudio)",
        // Só pt-BR desde a Onda 5. O modelo base da NVIDIA é multilíngue, mas os pesos que o app
        // carrega hoje são um fine-tune em português que ESQUECEU as outras línguas: medido em
        // 27/08/2026, "We deployed the new cluster last week" volta como "Nós amplamos uma cluster
        // na noite e o teu teatro está monitorando a área constante". Ele não degrada em inglês —
        // ele transcreve inglês como se fosse português, com confiança.
        supportedLanguages: [.portuguese],
        // Pelo mesmo motivo: `false` mantém fora do plano qualquer pedido sem idioma — o probe da
        // guarda é um deles — em vez de mandar áudio em outra língua a um modelo que só sabe
        // português. O seletor já não tem automático, mas o contrato ainda admite `language: nil`.
        detectsLanguageAutomatically: false,
        supportedUseCases: [.dictation, .translationChunk, .meetingFinal],
        supportsBatch: true,
        supportsStreaming: false,
        hardware: .appleSiliconNeuralEngine,
        models: [
            TranscriptionModelDescriptor(
                id: .parakeetTDT06BV3,
                engine: .parakeet,
                productName: "Parakeet TDT 0.6b v3",
                weight: .heavy,
                downloadBytes: 600 * 1024 * 1024,
                hardware: .appleSiliconNeuralEngine
            )
        ],
        automaticPriority: 100,
        // Q2: rank 2 explícito no transcript da reunião. Com a base 100 a ordem já seria a mesma;
        // o número está escrito para a política do `.meetingFinal` ser legível por inteiro nos três
        // descritores, em vez de dois valores explícitos e um implícito.
        automaticPriorityOverrides: [.meetingFinal: 2],
        isExperimental: true
    )
}
