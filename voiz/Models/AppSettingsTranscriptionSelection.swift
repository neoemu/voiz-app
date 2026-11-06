import Foundation

// Bloco de transcrição das Configurações (T1.4): como o usuário escolhe motor e modelo.
//
// Nada aqui é lido pelo app ainda — o coordenador (Onda 2) e a UI de Ajustes (Onda 6) é que
// vão consumir estes campos. Até lá o comportamento continua saindo de `modelSize` e
// `transcriptionEngine`, que seguem intactos: esta tarefa só **grava** a escolha num formato
// que aguenta mais de um motor.
//
// Os tipos são `nonisolated` de propósito, como os contratos da T1.2: o alvo do app compila com
// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` e o coordenador precisa lê-los fora da main thread.

/// Quem escolhe o motor de transcrição.
///
/// Só dois estados, e não um `Optional` de escolha: "automático" precisa sobreviver a uma
/// seleção antiga guardada. Quem volta para o automático depois de ter pinado um motor não
/// perde o que tinha escolhido — a seleção continua no disco, só não vale.
nonisolated enum TranscriptionSelectionMode: String, CaseIterable, Codable, Sendable, Hashable {
    /// O app decide (política versionada da Onda 6), com fallback.
    case automatic
    /// O usuário pinou motor/modelo por caso de uso.
    case advanced
}

/// O que foi pinado em cada caso de uso, no modo avançado.
///
/// É um tipo próprio em vez de um `[TranscriptionUseCase: TranscriptionEngineChoice]` cru por
/// causa do JSON: dicionário com chave enum vira **array alternado** no `JSONEncoder`, e uma
/// chave desconhecida (caso de uso criado numa versão futura do app, settings abertos numa
/// versão velha) faz o decode **lançar** — o que derrubaria todos os settings do usuário, não só
/// esta seleção. Aqui as chaves são strings e as desconhecidas são ignoradas.
nonisolated struct TranscriptionUseCaseChoices: Equatable, Hashable, Sendable, Codable {
    private var storage: [TranscriptionUseCase: TranscriptionEngineChoice]

    init(_ storage: [TranscriptionUseCase: TranscriptionEngineChoice] = [:]) {
        self.storage = storage
    }

    /// Nenhuma escolha pinada — o estado de quem nunca saiu do automático.
    static let empty = TranscriptionUseCaseChoices()

    /// Uma escolha para cada caso de uso, calculada caso a caso.
    static func perUseCase(
        _ choice: (TranscriptionUseCase) -> TranscriptionEngineChoice
    ) -> TranscriptionUseCaseChoices {
        TranscriptionUseCaseChoices(
            Dictionary(uniqueKeysWithValues: TranscriptionUseCase.allCases.map { ($0, choice($0)) })
        )
    }

    subscript(useCase: TranscriptionUseCase) -> TranscriptionEngineChoice? {
        get { storage[useCase] }
        set { storage[useCase] = newValue }
    }

    var isEmpty: Bool { storage.isEmpty }

    /// Casos de uso com escolha pinada, em ordem estável (a de `allCases`).
    var pinnedUseCases: [TranscriptionUseCase] {
        TranscriptionUseCase.allCases.filter { storage[$0] != nil }
    }

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: TranscriptionEngineChoice].self)
        storage = raw.reduce(into: [:]) { result, pair in
            guard let useCase = TranscriptionUseCase(rawValue: pair.key) else { return }
            result[useCase] = pair.value
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Dictionary(uniqueKeysWithValues: storage.map { ($0.key.rawValue, $0.value) }))
    }
}

/// O idioma da UI (`Language`) no vocabulário dos motores.
///
/// Vive aqui, e não no `TranscriptionModels.swift`, porque é a mesma ponte que
/// `effectiveTranscriptionChoice(for:)` faz — settings/UI de um lado, roteador do outro — e este
/// arquivo é o que compila nos dois alvos.
extension Language {
    /// **Não é opcional.** Era, enquanto `.auto` existia e virava `nil` (= detecção automática).
    /// O contrato ainda admite `TranscriptionRequest(language: nil)` — o probe da guarda usa —,
    /// mas nenhuma escolha de usuário produz mais esse `nil`, e devolver um opcional que nunca é
    /// nulo convidaria de volta o caminho que fez uma reunião em pt-BR sair inteira em inglês.
    nonisolated var transcriptionLanguage: TranscriptionLanguage {
        switch self {
        case .portuguese: return .portuguese
        case .english: return .english
        case .spanish: return .spanish
        case .french: return .french
        case .german: return .german
        case .japanese: return .japanese
        case .chinese: return .chinese
        }
    }

    /// O locale do `SpeechAnalyzer` para este idioma.
    ///
    /// Total de propósito: desde 29/08/2026 todo idioma do seletor tem locale no
    /// `SpeechTranscriber` (verificado em `supportedLocales` nesta máquina), e é isso que faz o
    /// motor bom ser elegível para todos eles. Acrescentar um caso em `Language` sem entrada aqui
    /// não compila — que é o aviso certo, porque o idioma novo cairia calado no motor mais fraco.
    var appleSpeechLocale: AppleSpeechLocale {
        switch self {
        case .portuguese: return .portugueseBrazil
        case .english: return .englishUS
        case .spanish: return .spanishSpain
        case .french: return .frenchFrance
        case .german: return .germanGermany
        case .japanese: return .japaneseJapan
        case .chinese: return .chineseChina
        }
    }
}

extension AppSettings {
    /// Versão do **bloco de transcrição** dos settings (não dos settings inteiros). Sobe quando a
    /// forma da escolha muda de um jeito que exige reinterpretar o que está no disco.
    ///
    /// 0 = settings gravados antes da T1.4, que só tinham `transcriptionEngine` + `modelSize`.
    /// 1 = modo + escolha por caso de uso.
    static let currentTranscriptionSettingsVersion = 1

    /// O par legado que representava "não mexi em nada". **Congelado de propósito**: são os
    /// defaults que valiam quando a migração foi escrita. Se o default do app mudar amanhã, o
    /// resultado da migração para os settings já gravados não pode mudar junto — senão a mesma
    /// entrada no disco passaria a migrar para outra coisa dependendo da versão do app.
    nonisolated static let legacyDefaultTranscriptionEngine: TranscriptionEngine = .whisper
    static let legacyDefaultModelSize: ModelSize = .small

    /// O usuário nunca tocou na escolha de transcrição?
    ///
    /// **Exceção conhecida, decidida pelo Maestro (DECISOES, 2026-08-07):** entre `b5fb41d` e
    /// `178ab42` o default persistível foi `large-v3-turbo`, não `small`. Um JSON daquela era com
    /// `whisper + large-v3-turbo` é *indistinguível* de uma escolha manual — o JSON não guarda
    /// metadado de intenção. A decisão é classificá-lo como **avançado**, preservando o
    /// `large-v3-turbo`: é o modelo que o app usaria hoje ao abrir esses settings, e trocá-lo por
    /// baixo do usuário seria mudança silenciosa de comportamento. Consequência aceita: quem vem
    /// daquela era e nunca escolheu nada fica em Avançado até mexer na UI da Onda 6.
    var usesLegacyDefaultTranscriptionChoice: Bool {
        transcriptionEngine == Self.legacyDefaultTranscriptionEngine
            && modelSize == Self.legacyDefaultModelSize
    }

    /// O modelo fixo da prévia ao vivo, hoje **hardcoded** em
    /// `MeetingLivePreviewService.previewModelName = "openai_whisper-small"` — a prévia nunca leu
    /// `AppSettings.modelSize`. A string é repetida aqui (e não referenciada) porque este arquivo
    /// também compila no alvo `voizTests`, que não tem o serviço; ela é coberta por teste.
    static let legacyMeetingPreviewChoice = TranscriptionEngineChoice(
        engine: .whisperKit,
        model: .whisperSmall
    )

    /// O WhisperKit compartilhado (`TranscriptionService`) com o tamanho configurado — o que roda
    /// em quem **ignora** `transcriptionEngine` e só chama `configure(modelName:)`.
    var legacyWhisperChoice: TranscriptionEngineChoice {
        TranscriptionEngineChoice(
            engine: .whisperKit,
            model: TranscriptionModelID(modelSize.whisperModelName)
        )
    }

    /// O par das Configurações **honrando o motor escolhido** — o que roda em quem faz `switch`
    /// em `transcriptionEngine`.
    ///
    /// No Parakeet o `modelSize` é ignorado: ele nomeia variantes do Whisper e o Parakeet tem um
    /// checkpoint só. Quem escolheu Parakeet escolheu o motor, não o tamanho.
    var legacyEngineAwareChoice: TranscriptionEngineChoice {
        switch transcriptionEngine {
        case .whisper: return legacyWhisperChoice
        case .parakeet: return TranscriptionEngineChoice(engine: .parakeet, model: .parakeetTDT06BV3)
        // O modelo **é** o locale, então ele segue o idioma escolhido — e não um pt-BR fixo, como
        // ficou até 29/08/2026. O fixo era um defeito de verdade, escondido enquanto o app tinha
        // dois idiomas e o default era automático: quem escolhia Apple e falava inglês recebia
        // WHISPER. O modelo pinado não servia ao pedido `en`, o roteador tirava o `userSelection`
        // do candidato, e sem esse pino o Apple volta para a prioridade base 50 — atrás do Whisper.
        // A escolha guardada dizia uma coisa e o app rodava outra, calado.
        //
        // Com sete idiomas isso deixaria de ser um caso de canto e passaria a ser a regra: cinco
        // dos sete nunca chegariam ao motor escolhido.
        case .apple:
            return TranscriptionEngineChoice(
                engine: .appleSpeechAnalyzer,
                model: selectedLanguage.appleSpeechLocale.model
            )
        }
    }

    /// O que **este** caso de uso roda hoje, antes de existir seleção por caso de uso.
    ///
    /// Nenhuma linha aqui é dedução: cada caso foi lido no consumidor legado correspondente, e é
    /// por isso que o mapa tem três formas diferentes em vez de uma escolha global uniforme — as
    /// duas versões anteriores desta migração erraram exatamente aqui, nos dois críticos da review
    /// do Farol. Mexer em qualquer um destes consumidores é mexer nesta função junto.
    ///
    /// - `.dictation` — `TranscriptionViewModel.swift:280-291` faz `switch settings.transcriptionEngine`
    ///   e chama o `parakeetService` quando o usuário escolheu Parakeet.
    /// - `.meetingFinal` — `MeetingViewModel.swift:508-515,1125` congela `recordingEngine` no start
    ///   da gravação e também despacha por motor.
    /// - `.translationChunk` — `TranslationViewModel.swift:22,107,214` **nunca lê**
    ///   `transcriptionEngine`: fala direto com `TranscriptionService.shared` (WhisperKit) e só
    ///   aplica `modelSize.whisperModelName`. Com Parakeet configurado a tradução continua no
    ///   Whisper, então migrá-la para Parakeet trocaria o motor dela em silêncio.
    /// - `.meetingPreview` — `MeetingLivePreviewService.swift:50` é fixo em Whisper small e não lê
    ///   nem motor nem tamanho.
    func legacyTranscriptionChoice(for useCase: TranscriptionUseCase) -> TranscriptionEngineChoice {
        switch useCase {
        case .dictation, .meetingFinal:
            return legacyEngineAwareChoice
        case .translationChunk:
            return legacyWhisperChoice
        case .meetingPreview:
            return Self.legacyMeetingPreviewChoice
        }
    }

    /// Move o motor escolhido para um válido quando o idioma deixa de ser compatível.
    ///
    /// Sem isto, trocar o idioma para inglês com Parakeet escolhido deixaria o ajuste guardado
    /// dizendo "Parakeet" enquanto o roteador roda outra coisa. Esconder a opção inválida não
    /// basta: o que ficou salvo continuaria mentindo.
    ///
    /// Devolve o motor anterior quando houve troca, para quem quiser avisar; `nil` quando nada mudou.
    @discardableResult
    mutating func realignTranscriptionEngineWithLanguage() -> TranscriptionEngine? {
        let disponiveis = TranscriptionEngine.selectable(for: selectedLanguage)
        guard disponiveis.contains(transcriptionEngine) == false else { return nil }
        // Se nem o catálogo tem opção para este idioma, manter o que está é melhor que zerar.
        guard let substituto = disponiveis.first else { return nil }
        let anterior = transcriptionEngine
        transcriptionEngine = substituto
        return anterior
    }

    /// A escolha pinada para um caso de uso — `nil` no automático, mesmo que exista seleção
    /// guardada de uma passagem anterior pelo avançado.
    func transcriptionChoice(for useCase: TranscriptionUseCase) -> TranscriptionEngineChoice? {
        guard transcriptionSelectionMode == .advanced else { return nil }
        return transcriptionSelections[useCase]
    }

    /// O que este caso de uso deve rodar **agora**, já no vocabulário do roteador.
    ///
    /// Duas fontes, nesta ordem:
    /// 1. o que o usuário pinou no modo avançado (`transcriptionChoice(for:)`);
    /// 2. o que o consumidor legado roda hoje (`legacyTranscriptionChoice(for:)`).
    ///
    /// O passo 2 não é redundante com a migração: `migratingTranscriptionSettings()` existe desde a
    /// T1.4 mas **ninguém a chama** — quem liga a migração no `SettingsStore` é a Onda 6. Até lá
    /// todo usuário está em `.automatic` com `transcriptionSelections` vazio, e sem este segundo
    /// passo o roteador cairia na ordem automática do catálogo: Whisper **small**, ignorando o
    /// `modelSize` que o usuário escolheu nas Configurações. Quem usa `medium` ou `large-v3-turbo`
    /// veria o modelo trocar por baixo na migração dos view models — exatamente a regra 6 do PLANO.
    ///
    /// Consequência desejada, e é o que a T1.4 decidiu caso a caso: com **Parakeet** configurado
    /// globalmente, `.translationChunk` continua no Whisper, porque a tradução nunca leu
    /// `transcriptionEngine` — ela fala direto com o `TranscriptionService`. Migrá-la para Parakeet
    /// trocaria o motor dela em silêncio.
    func effectiveTranscriptionChoice(for useCase: TranscriptionUseCase) -> TranscriptionEngineChoice {
        transcriptionChoice(for: useCase) ?? legacyTranscriptionChoice(for: useCase)
    }

    /// A seleção que vai ao `TranscriptionCoordinator` para este caso de uso.
    ///
    /// - Parameter strict: `true` = sem fallback, nunca. É o que a tradução (T2.4b) usa, por
    ///   decisão do Maestro registrada em DECISOES: a regra 6 do PLANO cita a tradução
    ///   nominalmente entre o que não muda até a Onda 6, e hoje uma falha do Whisper na tradução
    ///   falha e loga — não carrega outro motor. Dar fallback a ela agora mudaria comportamento
    ///   num caminho de erro, e a decisão sobre isso é da Onda 6.
    func transcriptionSelection(
        for useCase: TranscriptionUseCase,
        strict: Bool
    ) -> TranscriptionUserSelection {
        TranscriptionUserSelection(
            preferred: effectiveTranscriptionChoice(for: useCase),
            strictEngineSelection: strict
        )
    }

    /// Traduz a escolha legada (motor + tamanho de modelo) para o formato novo, uma única vez.
    ///
    /// Determinística e idempotente: a mesma entrada sempre dá a mesma saída, e rodar de novo em
    /// cima do resultado não muda nada (o guarda de versão corta na entrada). Não é chamada por
    /// ninguém ainda — a Onda 6 liga a migração no `SettingsStore`.
    ///
    /// Regra: quem estava no default cai no **automático** (é o que ele já tinha, sem escolha);
    /// quem escolheu qualquer outra coisa vai para o **avançado** com a escolha preservada, para
    /// não perder na virada um modelo que ele baixou de propósito — **caso de uso a caso de uso**,
    /// espelhando o que cada consumidor legado roda hoje (ver `legacyTranscriptionChoice(for:)`).
    func migratingTranscriptionSettings() -> AppSettings {
        guard transcriptionSettingsVersion < Self.currentTranscriptionSettingsVersion else {
            return self
        }
        var migrated = self
        if usesLegacyDefaultTranscriptionChoice {
            migrated.transcriptionSelectionMode = .automatic
            migrated.transcriptionSelections = .empty
        } else {
            migrated.transcriptionSelectionMode = .advanced
            migrated.transcriptionSelections = .perUseCase(legacyTranscriptionChoice(for:))
        }
        migrated.transcriptionSettingsVersion = Self.currentTranscriptionSettingsVersion
        return migrated
    }
}
