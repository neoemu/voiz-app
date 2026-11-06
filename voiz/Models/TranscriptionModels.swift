import Foundation
import AppKit
import Carbon.HIToolbox

/// O que pode ser escrito num log sobre um **segredo** (chave de API, token).
///
/// Irmão de `TranscriptionLogRedaction`, e pelo mesmo princípio: o construtor recebe o segredo e
/// devolve algo que não o contém, para que a suíte possa mandar um sentinela e reprovar se
/// qualquer pedaço dele sobreviver. Se ele recebesse um `Bool`, o teste passaria sem provar nada
/// sobre o que o chamador faz com a chave.
///
/// **Nem prefixo mascarado.** O prefixo de uma chave (`sk-proj-…`) identifica provedor e, em vários
/// provedores, projeto ou organização — e não acrescenta nada operacional aqui, porque a linha de
/// log vizinha já imprime o provedor escolhido nas Configurações. O que um dev precisa saber
/// depurando é "tem chave?" e "ela veio inteira?", e as duas cabem em presença + tamanho.
///
/// Mora neste arquivo porque é aqui que vive o `AppSettings` dono da chave, e porque ele já compila
/// no alvo `voizTests` — um arquivo próprio exigiria mexer no `pbxproj`, que está sob mutex com a
/// T2.4a. Se o Maestro preferir casa própria depois do merge, é um `git mv` e uma linha de exceção.
nonisolated enum SecretLogRedaction {
    /// "presente (51 caracteres)" ou "ausente". Nunca o segredo, nem parte dele.
    ///
    /// O tamanho não é material secreto e é o que denuncia o erro mais comum: chave colada pela
    /// metade, ou com espaço/quebra de linha no fim.
    static func presence(of secret: String) -> String {
        secret.isEmpty ? "ausente" : "presente (\(secret.count) caracteres)"
    }
}

/// O idioma **falado** que o app transcreve. Sempre um idioma concreto.
///
/// ## Não existe mais `.auto`, e o motivo é medido
///
/// A detecção automática não guardava idioma nenhum: cada lote ia ao Whisper com
/// `language: nil` e o modelo decidia sozinho, lote a lote. Isso servia à reunião bilíngue —
/// e cobrava o preço em toda reunião que não era. Em 28/08/2026, uma reunião inteira em
/// pt-BR saiu em inglês, transcript oficial incluído: o modelo errou o idioma e nada no app
/// segurava a decisão de um lote para o próximo.
///
/// O automático ainda custava os dois motores bons: Apple e Parakeet declaram
/// `detectsLanguageAutomatically: false` (o locale deles é fixo), então um pedido sem idioma
/// nem chegava neles — automático caía sempre no Whisper, o pior dos motores medidos
/// (28,64% de WER contra 15,16% do Apple).
///
/// A troca: quem fala duas línguas na mesma reunião escolhe uma e a outra sai transcrita
/// errado. Perder o caso raro é mais barato que estragar o comum, e escolher no dropdown é a
/// detecção mais confiável que existe.
///
/// ## Por que estes idiomas
///
/// Os cinco novos são os que **os três lados** atendem: o Whisper multilíngue os fala; o
/// `SpeechTranscriber` do macOS 26 tem locale para todos (verificado nesta máquina em
/// 29/08/2026 — `supportedLocales` traz de_DE, es_ES, fr_FR, ja_JP e zh_CN); e são idiomas de
/// muito dado de treino, onde a qualidade do Whisper não desaba. Acrescentar um idioma aqui
/// exige a mesma checagem: sem locale do Apple, o idioma cai sempre no motor mais fraco.
nonisolated enum Language: String, CaseIterable, Identifiable, Codable {
    case portuguese = "pt"
    case english = "en"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case japanese = "ja"
    case chinese = "zh"

    var id: String { rawValue }

    /// O nome do idioma **no próprio idioma**. Não passa por `String(localized:)` de propósito:
    /// "Deutsch" é Deutsch em qualquer menu, e quem procura a própria língua numa lista a acha
    /// pelo nome dela, não pela tradução.
    var displayName: String {
        switch self {
        case .portuguese: return "Português (BR)"
        case .english: return "English"
        case .spanish: return "Español"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .japanese: return "日本語"
        case .chinese: return "中文 (简体)"
        }
    }

    /// O locale regional. É o que vira `AppleSpeechLocale`: o `SpeechTranscriber` não aceita
    /// idioma sem região, então cada caso escolhe uma variante — a de maior alcance, e para o
    /// chinês o mandarim simplificado (`zh-CN`), que é o que a maioria dos falantes usa.
    var locale: Locale {
        switch self {
        case .portuguese: return Locale(identifier: "pt-BR")
        case .english: return Locale(identifier: "en-US")
        case .spanish: return Locale(identifier: "es-ES")
        case .french: return Locale(identifier: "fr-FR")
        case .german: return Locale(identifier: "de-DE")
        case .japanese: return Locale(identifier: "ja-JP")
        case .chinese: return Locale(identifier: "zh-CN")
        }
    }
}

struct TranscriptionSegment: Identifiable {
    let id = UUID()
    let text: String
    let language: Language
    let confidence: Float
    let timestamp: Date
    let duration: TimeInterval
}

struct TranscriptionResult {
    let segments: [TranscriptionSegment]
    let fullText: String
    let detectedLanguage: Language
    let processingTime: TimeInterval
}

enum TranscriptionState: Equatable {
    case idle
    case listening
    case processing
    case error(String)
}

nonisolated struct KeyboardShortcut: Codable, Equatable {
    /// `noKeyCode` representa "sem tecla normal" — só Fn e/ou modificadores (ex.: Fn sozinho).
    static let noKeyCode: UInt16 = 0xFFFF

    let keyCode: UInt16
    let modifiers: UInt32   // modificadores Carbon (⌘⌥⌃⇧)
    let keyDisplay: String
    /// A tecla Fn/🌐 faz parte do chord. Não existe no Carbon — só é detectável via CGEvent/NSEvent.
    var usesFn: Bool = false

    /// Tem uma tecla "normal" além de Fn/modificadores?
    var hasKey: Bool { keyCode != KeyboardShortcut.noKeyCode }

    static let `default` = KeyboardShortcut(
        keyCode: UInt16(kVK_Space),
        modifiers: UInt32(cmdKey | shiftKey),
        keyDisplay: "Space"
    )

    /// Padrão "segurar pra falar" estilo Wispr: Fn sozinho.
    static let fnPushToTalk = KeyboardShortcut(
        keyCode: noKeyCode,
        modifiers: 0,
        keyDisplay: "",
        usesFn: true
    )

    /// Padrão "mãos livres" estilo Wispr: Fn + Espaço.
    static let fnSpaceHandsFree = KeyboardShortcut(
        keyCode: UInt16(kVK_Space),
        modifiers: 0,
        keyDisplay: "Space",
        usesFn: true
    )

    init(keyCode: UInt16, modifiers: UInt32, keyDisplay: String, usesFn: Bool = false) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyDisplay = keyDisplay
        self.usesFn = usesFn
    }

    /// Decode tolerante: `usesFn` é campo novo. Sem isso, os `KeyboardShortcut` já salvos (sem a chave)
    /// fariam o `decodeIfPresent` lá no `AppSettings` **lançar** e derrubar todos os settings.
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.keyCode = try c.decode(UInt16.self, forKey: .keyCode)
        self.modifiers = try c.decode(UInt32.self, forKey: .modifiers)
        self.keyDisplay = try c.decode(String.self, forKey: .keyDisplay)
        self.usesFn = try c.decodeIfPresent(Bool.self, forKey: .usesFn) ?? false
    }

    init?(event: NSEvent) {
        let cleanModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let carbonModifiers = cleanModifiers.carbonFlags
        let usesFn = event.modifierFlags.contains(.function)

        // Precisa de pelo menos Fn ou um modificador (não aceitar tecla pura, pra não roubar digitação).
        guard usesFn || carbonModifiers != 0 else { return nil }

        let keyDisplay = KeyboardShortcut.displayName(for: event)
        let hasKey = event.type == .keyDown && !keyDisplay.isEmpty

        self.keyCode = hasKey ? UInt16(event.keyCode) : KeyboardShortcut.noKeyCode
        self.modifiers = carbonModifiers
        self.keyDisplay = hasKey ? keyDisplay : ""
        self.usesFn = usesFn
    }

    var displayString: String {
        let modifierSymbols: [(UInt32, String)] = [
            (UInt32(controlKey), "⌃"),
            (UInt32(optionKey), "⌥"),
            (UInt32(shiftKey), "⇧"),
            (UInt32(cmdKey), "⌘")
        ]

        let modifiersText = modifierSymbols
            .filter { modifiers & $0.0 != 0 }
            .map(\.1)
            .joined()

        let fnText = usesFn ? "fn " : ""
        let combined = (fnText + modifiersText + keyDisplay).trimmingCharacters(in: .whitespaces)
        return combined.isEmpty ? "—" : combined
    }

    /// Pedaços para renderizar como "chips" na UI (ex.: ["fn", "Space"]).
    var chips: [String] {
        var result: [String] = []
        if usesFn { result.append("fn") }
        let modifierSymbols: [(UInt32, String)] = [
            (UInt32(controlKey), "⌃"),
            (UInt32(optionKey), "⌥"),
            (UInt32(shiftKey), "⇧"),
            (UInt32(cmdKey), "⌘")
        ]
        for (mask, symbol) in modifierSymbols where modifiers & mask != 0 {
            result.append(symbol)
        }
        if hasKey, !keyDisplay.isEmpty { result.append(keyDisplay) }
        return result
    }

    var carbonModifiers: UInt32 {
        modifiers
    }

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(carbonFlags: modifiers)
    }

    private enum CodingKeys: String, CodingKey {
        case keyCode, modifiers, keyDisplay, usesFn
    }

    private static func displayName(for event: NSEvent) -> String {
        let keyCode = event.keyCode

        if let special = specialKeyDisplayNames[UInt16(keyCode)] {
            return special
        }

        if let characters = event.charactersIgnoringModifiers,
           let first = characters.first {
            return String(first).uppercased()
        }

        return ""
    }
    
    private static let specialKeyDisplayNames: [UInt16: String] = [
        UInt16(kVK_Return): "Return",
        UInt16(kVK_ANSI_KeypadEnter): "Enter",
        UInt16(kVK_Space): "Space",
        UInt16(kVK_Delete): "Delete",
        UInt16(kVK_ForwardDelete): "Del",
        UInt16(kVK_Escape): "Esc",
        UInt16(kVK_Tab): "Tab",
        UInt16(kVK_RightArrow): "Right",
        UInt16(kVK_LeftArrow): "Left",
        UInt16(kVK_DownArrow): "Down",
        UInt16(kVK_UpArrow): "Up"
    ]
}

nonisolated struct AppSettings: Codable, Equatable {
    /// Idioma dos menus e textos do app. Distinto de `selectedLanguage`, que é o idioma **falado**
    /// que o Whisper transcreve — os dois eram confundidos porque só existia o segundo.
    var interfaceLanguage: InterfaceLanguage = .system
    /// Aparência da interface. Escuro continua sendo o default para preservar o visual de quem
    /// já usa o app; `.system` e `.light` permitem acompanhar o macOS ou usar a nova paleta clara.
    var appearance: InterfaceAppearance = .dark
    /// O idioma falado, agora sempre concreto. Português é o default porque `.auto` deixou de
    /// existir (ver `Language`) e porque é o idioma do app.
    var selectedLanguage: Language = .portuguese
    var autoInsertText: Bool = true
    var showConfidence: Bool = true
    var modelSize: ModelSize = .small
    var transcriptionEngine: TranscriptionEngine = .apple
    var hotKey: KeyboardShortcut = .default   // legado (compat de decode); ditado agora usa os dois abaixo
    var showRecordingHUD: Bool = true

    // Atalhos de ditado estilo Wispr Flow (motor CGEventTap, suporta Fn/🌐)
    var pushToTalkShortcut: KeyboardShortcut = .fnPushToTalk    // segura pra falar
    var handsFreeShortcut: KeyboardShortcut = .fnSpaceHandsFree // toca pra alternar (mãos livres)
    var dictationHotkeysEnabled: Bool = true
    var dictationVocabulary: String = ""
    var dictationCorrectionsEnabled: Bool = false
    var dictationCorrectionMarkers: String = "corrigindo\nquer dizer\ncorrection\nI mean\nerr"

    // Translation provider settings
    var translationProvider: TranslationProvider = .openai
    var openAIKey: String = ""
    var anthropicKey: String = ""
    var xaiKey: String = ""
    var geminiKey: String = ""
    var translationModel: TranslationModel = .gpt56Luna
    var anthropicModel: AnthropicModel = .haiku45
    var xaiModel: XAIModel = .grok420NonReasoning
    var geminiModel: GeminiModel = .gemini36Flash

    /// Esforço de raciocínio pedido ao modelo ativo. Um valor só para todos os provedores: só um
    /// fica ativo por vez, e o clamp em `effectiveReasoningEffort` cuida das faixas diferentes.
    var reasoningEffort: ReasoningEffort = .auto

    // Endpoint OpenAI-compatible custom (BYO: aponta pro LiteLLM ou qualquer modelo do usuário)
    var customBaseURL: String = ""
    var customKey: String = ""
    var customModel: String = ""

    // Reuniões — sugerir gravar quando há reunião no calendário local (EventKit, on-device)
    var calendarSuggestionsEnabled: Bool = false
    var calendarSelection = MeetingCalendarSelection()

    // Reuniões — card flutuante "Gravar?" ao detectar chamada em curso (Teams/Meet/Zoom…)
    var meetingDetectionEnabled: Bool = true

    // Reuniões — idioma em que a IA escreve resumo, capítulos e respostas do assistente.
    var notesLanguage: NotesLanguage = .spoken

    // Reuniões — modo de transcrição: .quality (pós-processamento) ou .granola (ao vivo leve)
    var meetingMode: MeetingMode = .quality

    // Reuniões — preview visual durante a gravação. Desligado por padrão: não interfere
    // na captura, no transcript oficial, na diarização nem no resumo pós-call.
    var meetingLivePreviewEnabled: Bool = false

    // Notch como status (experimental): indicador de gravação e toasts ancorados no
    // notch do MacBook; vira pílula no topo em telas sem notch. Opt-in.
    var notchOverlayEnabled: Bool = false

    // Transcrição V2 (T1.4) — ver `AppSettingsTranscriptionSelection.swift`. Ninguém lê estes
    // campos ainda: quem manda no comportamento continua sendo o par `transcriptionEngine` +
    // `modelSize` acima.
    var transcriptionSelectionMode: TranscriptionSelectionMode = .automatic
    var transcriptionSelections: TranscriptionUseCaseChoices = .empty
    /// 0 = ainda não migrado (settings gravados antes da T1.4). O default **precisa** ser 0
    /// também numa instância nova: `init(from:)` parte dos defaults, então qualquer outro valor
    /// aqui faria o JSON antigo (sem a chave) se declarar migrado e pular a migração.
    var transcriptionSettingsVersion: Int = 0

    /// Dev may run alongside the user's official app. Global shortcuts and automatic meeting
    /// detection start off there, and saved opt-in choices still override these defaults.
    init(environment: AppEnvironment = .current) {
        dictationHotkeysEnabled = !environment.isDevelopment
        meetingDetectionEnabled = !environment.isDevelopment
    }

    /// Um modelo escolhido a dedo: provider **e** id. O provider anda junto porque o app fala com
    /// cinco APIs diferentes — só o id não diz qual chave, qual endpoint nem qual dialeto usar.
    ///
    /// Existe para telas que escolhem o modelo por conta própria (o seletor do Chat/Home) sem
    /// mexer no provider global das Configurações, que continua valendo para reuniões e tradução.
    struct ModelChoice: Codable, Equatable, Hashable {
        var provider: TranslationProvider
        var modelId: String
    }

    /// O que as Configurações escolheram — o padrão de quem não tem seletor próprio.
    var currentChoice: ModelChoice {
        ModelChoice(provider: translationProvider, modelId: currentModelId)
    }

    /// Providers prontos para uso: chave preenchida e, no custom, também endpoint e nome do modelo.
    ///
    /// É a lista que o seletor do Chat oferece. Sem esse filtro ele mostraria modelos de provedores
    /// sem credencial, e a escolha só falharia lá na frente, com um 401 no meio da conversa.
    var configuredProviders: [TranslationProvider] {
        TranslationProvider.allCases.filter { provider in
            guard !apiKey(for: provider).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return false
            }
            guard provider == .custom else { return true }
            return currentBaseURL != nil
                && !customModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func apiKey(for provider: TranslationProvider) -> String {
        switch provider {
        case .openai: return openAIKey
        case .anthropic: return anthropicKey
        case .xai: return xaiKey
        case .gemini: return geminiKey
        case .custom: return customKey
        }
    }

    /// Modelos que o provider oferece, na ordem em que aparecem no seletor. O custom tem um só —
    /// o nome que o usuário digitou.
    func models(for provider: TranslationProvider) -> [ModelChoice] {
        let ids: [String]
        switch provider {
        case .openai: ids = TranslationModel.allCases.map(\.modelId)
        case .anthropic: ids = AnthropicModel.allCases.map(\.modelId)
        case .xai: ids = XAIModel.allCases.map(\.modelId)
        case .gemini: ids = GeminiModel.allCases.map(\.modelId)
        case .custom: ids = customModel.isEmpty ? [] : [customModel]
        }
        return ids.map { ModelChoice(provider: provider, modelId: $0) }
    }

    func displayName(for choice: ModelChoice) -> String {
        switch choice.provider {
        case .openai: return TranslationModel(rawValue: choice.modelId)?.displayName ?? choice.modelId
        case .anthropic: return AnthropicModel(rawValue: choice.modelId)?.displayName ?? choice.modelId
        case .xai: return XAIModel(rawValue: choice.modelId)?.displayName ?? choice.modelId
        case .gemini: return GeminiModel(rawValue: choice.modelId)?.displayName ?? choice.modelId
        case .custom: return choice.modelId.isEmpty ? "Custom" : choice.modelId
        }
    }

    func supportedReasoningEfforts(for choice: ModelChoice) -> [ReasoningEffort] {
        switch choice.provider {
        case .openai: return TranslationModel(rawValue: choice.modelId)?.supportedReasoningEfforts ?? []
        case .anthropic: return AnthropicModel(rawValue: choice.modelId)?.supportedReasoningEfforts ?? []
        case .xai: return XAIModel(rawValue: choice.modelId)?.supportedReasoningEfforts ?? []
        case .gemini: return GeminiModel(rawValue: choice.modelId)?.supportedReasoningEfforts ?? []
        case .custom: return ReasoningEffort.ladder
        }
    }

    func effectiveReasoningEffort(for choice: ModelChoice) -> ReasoningEffort {
        Self.clamp(reasoningEffort, to: supportedReasoningEfforts(for: choice))
    }

    func acceptsTemperature(for choice: ModelChoice) -> Bool {
        switch choice.provider {
        case .openai: return TranslationModel(rawValue: choice.modelId)?.acceptsTemperature ?? true
        case .anthropic: return AnthropicModel(rawValue: choice.modelId)?.acceptsTemperature ?? true
        case .xai, .gemini, .custom: return true
        }
    }

    /// A escolha ainda pode ser usada? Uma chave apagada nas Configurações não deve deixar a tela
    /// presa num provider que agora responde 401 — nesse caso quem chama volta ao padrão.
    func isUsable(_ choice: ModelChoice) -> Bool {
        configuredProviders.contains(choice.provider) && !choice.modelId.isEmpty
    }

    /// A escolha, quando existe e é utilizável; senão, o que está nas Configurações.
    func resolvedChoice(_ choice: ModelChoice?) -> ModelChoice {
        guard let choice, isUsable(choice) else { return currentChoice }
        return choice
    }

    // Computed helpers
    var currentAPIKey: String {
        apiKey(for: translationProvider)
    }

    /// O que pode ser dito sobre a chave do provedor num log.
    ///
    /// Existe como propriedade — e não como interpolação no chamador — pelo mesmo motivo que
    /// `TranscriptionLogRedaction`: é o que torna a regra testável. Ver `SecretLogRedaction`.
    var apiKeyLogDescription: String {
        SecretLogRedaction.presence(of: currentAPIKey)
    }

    var currentModelId: String {
        switch translationProvider {
        case .openai: return translationModel.modelId
        case .anthropic: return anthropicModel.modelId
        case .xai: return xaiModel.modelId
        case .gemini: return geminiModel.modelId
        case .custom: return customModel
        }
    }

    var currentModelDisplayName: String {
        displayName(for: currentChoice)
    }

    /// Idioma efetivo da interface — resolve `system` para a localização que o macOS de fato escolheu.
    var resolvedInterfaceLanguageCode: String {
        interfaceLanguage.localeCode ?? Bundle.main.preferredLocalizations.first ?? "pt-BR"
    }

    /// Instrução de idioma anexada aos prompts de reunião. Vai para o modelo, não para a tela — por
    /// isso não é localizada. Cada idioma da interface tem uma instrução explícita: deixar os cinco
    /// novos caírem no `default` em inglês faria "Seguir a interface" mentir justamente quando a
    /// pessoa escolhesse espanhol, francês, alemão, japonês ou chinês.
    var notesLanguageInstruction: String {
        switch notesLanguage {
        case .portuguese: return "Escreva em português do Brasil."
        case .english: return "Write in English."
        case .interface:
            return Self.notesLanguageInstruction(forInterfaceCode: resolvedInterfaceLanguageCode)
        case .spoken:
            // Instrução para o LLM das notas, no idioma falado escolhido. Cada caso é escrito na
            // língua que ele pede: dizer "write in Japanese" em inglês funciona, mas a instrução
            // no próprio idioma é a que menos deixa o modelo escorregar de volta para o inglês.
            switch selectedLanguage {
            case .portuguese: return "Escreva em português do Brasil."
            case .english: return "Write in English."
            case .spanish: return "Escribe en español."
            case .french: return "Écris en français."
            case .german: return "Schreibe auf Deutsch."
            case .japanese: return "日本語で書いてください。"
            case .chinese: return "请用简体中文写。"
            }
        }
    }

    /// Resolve só as localizações que o bundle oferece. O fallback em inglês cobre preferências
    /// antigas/desconhecidas sem produzir uma instrução vazia para o modelo.
    private static func notesLanguageInstruction(forInterfaceCode code: String) -> String {
        switch code.split(separator: "-").first.map(String.init) {
        case "pt": return "Escreva em português do Brasil."
        case "en": return "Write in English."
        case "es": return "Escribe en español."
        case "fr": return "Écris en français."
        case "de": return "Schreibe auf Deutsch."
        case "ja": return "日本語で書いてください。"
        case "zh": return "请用简体中文写。"
        default: return "Write in English."
        }
    }

    /// Descrição curta do modelo ativo, para os subtítulos das Configurações.
    var currentModelDescription: String {
        switch translationProvider {
        case .openai: return translationModel.description
        case .anthropic: return anthropicModel.description
        case .xai: return xaiModel.description
        case .gemini: return geminiModel.description
        case .custom: return customModel.isEmpty ? String(localized: "Defina o nome do modelo") : customModel
        }
    }

    /// Esforços que o modelo ativo aceita, em ordem crescente. Vazio = o modelo não tem o
    /// parâmetro (o seletor some da tela). No provider custom não dá para saber o que roda do
    /// outro lado, então a escala inteira fica disponível e o default `.auto` não envia nada.
    var supportedReasoningEfforts: [ReasoningEffort] {
        supportedReasoningEfforts(for: currentChoice)
    }

    /// Esforço que de fato vale para o modelo ativo — o escolhido, quando ele aceita, ou o mais
    /// próximo da faixa dele.
    ///
    /// Grampeia em vez de descartar: quem pedia `none` e troca para um modelo que não desliga o
    /// raciocínio cai no mínimo dele (`low`), e não no default do provider, que costuma ser bem
    /// mais lento e caro. É também o que a tela mostra, para o seletor nunca exibir um valor que
    /// a requisição não usaria.
    var effectiveReasoningEffort: ReasoningEffort {
        effectiveReasoningEffort(for: currentChoice)
    }

    /// Grampeia `wanted` na faixa que o modelo aceita. Fora daqui ninguém precisa saber que a
    /// escada existe — quem tem um `ModelChoice` chama `effectiveReasoningEffort(for:)`.
    static func clamp(_ wanted: ReasoningEffort, to supported: [ReasoningEffort]) -> ReasoningEffort {
        guard !supported.isEmpty, wanted != .auto else { return .auto }
        if supported.contains(wanted) { return wanted }
        guard let wantedIndex = ReasoningEffort.ladder.firstIndex(of: wanted) else { return .auto }
        let clamped = supported.min { a, b in
            let ia = ReasoningEffort.ladder.firstIndex(of: a) ?? 0
            let ib = ReasoningEffort.ladder.firstIndex(of: b) ?? 0
            return abs(ia - wantedIndex) < abs(ib - wantedIndex)
        }
        return clamped ?? .auto
    }

    /// Valor de `reasoning_effort` para a requisição — `nil` quando não se deve mandar o campo.
    var currentReasoningEffort: String? { effectiveReasoningEffort.apiValue }

    /// O modelo ativo aceita `temperature`? Os modelos de raciocínio recentes (GPT-5.6 e a família
    /// Claude 5) removeram os parâmetros de amostragem e devolvem 400 se eles vierem no corpo.
    /// No provider custom não dá para saber o que roda do outro lado, então mandamos.
    var currentAcceptsTemperature: Bool {
        acceptsTemperature(for: currentChoice)
    }

    /// Endpoint `chat/completions` efetivo. Para os provedores fixos é `nil` (usa-se o `baseURL`
    /// do enum); para o custom, normaliza a URL digitada (aceita base, `.../v1` ou URL completa).
    var currentBaseURL: String? {
        guard translationProvider == .custom else { return nil }
        return AppSettings.normalizedChatCompletionsURL(from: customBaseURL)
    }

    /// Aceita "http://host:4000", "http://host:4000/v1" ou a URL completa e devolve sempre o
    /// caminho `chat/completions`. Retorna `nil` se a entrada for vazia.
    static func normalizedChatCompletionsURL(from raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/chat/completions") { return s }
        if s.hasSuffix("/v1") { return s + "/chat/completions" }
        return s + "/v1/chat/completions"
    }
    
    /// Motor de transcrição escolhido nas Configurações.
    ///
    /// O Apple entra aqui na Onda 6: ele já era o primeiro do transcript de reunião desde a Q2, mas
    /// não estava exposto para o ditado — e no corpus revisado ele é o melhor dos cinco motores
    /// medidos (15,16% de WER contra 18,17% do Parakeet pt-BR e 28,64% do Whisper small).
    ///
    /// `.apple` exige idioma explícito: o SpeechAnalyzer não detecta idioma sozinho. Com o idioma
    /// em automático, quem escolher Apple cai no fallback do roteador.
    enum TranscriptionEngine: String, CaseIterable, Codable {
        case whisper
        case parakeet
        case apple

        var displayName: String {
            switch self {
            case .whisper: return "WhisperKit (large-v3-turbo)"
            case .parakeet: return String(localized: "Parakeet v3 (FluidAudio) — pt-BR")
            case .apple: return String(localized: "Apple SpeechAnalyzer (do sistema)")
            }
        }

        var description: String {
            switch self {
            case .whisper: return String(localized: "Preciso, PT-BR nativo, real-time no Neural Engine")
            case .parakeet: return String(localized: "Muito rápido, modelo pt-BR próprio; ~600 MB")
            case .apple: return String(localized: "Modelo do próprio macOS; exige idioma definido")
            }
        }

        /// O motor correspondente no catálogo, que é quem sabe o que cada um aceita.
        var engineID: TranscriptionEngineID {
            switch self {
            case .whisper: return .whisperKit
            case .parakeet: return .parakeet
            case .apple: return .appleSpeechAnalyzer
            }
        }

        /// Os motores que o usuário pode escolher com este idioma.
        ///
        /// Derivado do catálogo, e não de uma tabela escrita aqui, de propósito: o Parakeet deixou
        /// de aceitar inglês quando os pesos viraram o fine-tune pt-BR, e uma lista paralela
        /// continuaria oferecendo o que o roteador já recusa — a tela mostrando uma escolha que o
        /// app ignora é o mesmo defeito, só que na cara do usuário.
        static func selectable(for language: Language) -> [TranscriptionEngine] {
            let catalog = TranscriptionCatalog.shipping
            return allCases.filter { engine in
                catalog.descriptor(for: engine.engineID)?
                    .supports(language: language.transcriptionLanguage) ?? false
            }
        }
    }

    enum ModelSize: String, CaseIterable, Codable {
        case base = "base"
        case small = "small"
        case medium = "medium"
        case largeTurbo = "large-v3-turbo"

        var displayName: String {
            switch self {
            case .base: return String(localized: "Base (~140MB) - Rápido")
            case .small: return String(localized: "Small (~480MB) - Recomendado")
            case .medium: return String(localized: "Medium (~1.5GB) - Preciso")
            case .largeTurbo: return String(localized: "Large v3 Turbo (~1.5GB) - Máxima qualidade (baixa 1.5GB)")
            }
        }

        /// Identificador do modelo no repositório CoreML do WhisperKit
        /// (argmaxinc/whisperkit-coreml). É o nome passado para `WhisperKit(model:)`.
        var whisperModelName: String {
            switch self {
            case .base: return "openai_whisper-base"
            case .small: return "openai_whisper-small"
            case .medium: return "openai_whisper-medium"
            case .largeTurbo: return "openai_whisper-large-v3_turbo"
            }
        }
    }
    
    /// Esforço de raciocínio (`reasoning_effort` no corpo do `chat/completions`). É o mesmo campo
    /// nos três provedores fixos — OpenAI, xAI e a camada compatível do Gemini —, então vive num
    /// enum só. `.auto` **não envia o parâmetro**: fica o default do modelo.
    ///
    /// Cada modelo declara o que aceita em `supportedReasoningEfforts`; a escolha do usuário é
    /// grampeada nessa faixa (ver `AppSettings.effectiveReasoningEffort`) para uma troca de modelo
    /// nunca produzir um valor que a API rejeite.
    enum ReasoningEffort: String, CaseIterable, Codable {
        case auto
        case none
        case low
        case medium
        case high
        case xhigh
        case max

        /// Valor mandado na API. `nil` = não enviar o campo.
        var apiValue: String? { self == .auto ? nil : rawValue }

        var displayName: String {
            switch self {
            case .auto: return String(localized: "Padrão do modelo")
            case .none: return String(localized: "Nenhum")
            case .low: return String(localized: "Baixo")
            case .medium: return String(localized: "Médio")
            case .high: return String(localized: "Alto")
            case .xhigh: return String(localized: "Muito alto")
            case .max: return String(localized: "Máximo")
            }
        }

        var description: String {
            switch self {
            case .auto: return String(localized: "Não envia o parâmetro")
            case .none: return String(localized: "Sem raciocínio: resposta imediata")
            case .low: return String(localized: "Pouco raciocínio, ainda rápido")
            case .medium: return String(localized: "Equilíbrio entre latência e precisão")
            case .high: return String(localized: "Mais preciso, bem mais lento")
            case .xhigh: return String(localized: "Raciocínio profundo; respostas demoram")
            case .max: return String(localized: "Teto de capacidade; muito lento e caro")
            }
        }

        /// Ordem crescente de esforço, usada para grampear na faixa do modelo. `.auto` fica fora.
        static let ladder: [ReasoningEffort] = [.none, .low, .medium, .high, .xhigh, .max]
    }

    /// Catálogo conferido em 10/09/2026; fontes em docs/AI_MODEL_CATALOG.md.
    enum TranslationModel: String, CaseIterable, Codable {
        case gpt56Luna = "gpt-5.6-luna"
        case gpt56Terra = "gpt-5.6-terra"
        case gpt56Sol = "gpt-5.6-sol"
        case gpt6Astra = "gpt-6-astra"

        var displayName: String {
            switch self {
            case .gpt56Luna: return "GPT-5.6 Luna"
            case .gpt56Terra: return "GPT-5.6 Terra"
            case .gpt56Sol: return "GPT-5.6 Sol"
            case .gpt6Astra: return "GPT-6 Astra"
            }
        }

        var modelId: String {
            return self.rawValue
        }

        var description: String {
            switch self {
            case .gpt56Luna: return String(localized: "Rápido e econômico")
            case .gpt56Terra: return String(localized: "Equilíbrio entre custo e qualidade")
            case .gpt56Sol: return String(localized: "Mais capaz em tarefas longas")
            case .gpt6Astra: return String(localized: "Máxima qualidade, mais caro")
            }
        }

        /// `xhigh` e `max` ficam expostos no Terra e no Luna: são baratos o bastante para valer a
        /// pena rodar nos tiers altos. No Sol, o mesmo esforço custa 5x mais por token.
        ///
        /// Os dois degraus do topo só existem pela Responses API — em `chat/completions` a OpenAI
        /// devolve "does not support 'max' with this model", mesmo a página do modelo listando o
        /// valor. É por isso que este provider usa `/v1/responses`.
        var supportedReasoningEfforts: [ReasoningEffort] {
            switch self {
            case .gpt56Luna, .gpt56Terra: return ReasoningEffort.ladder
            case .gpt56Sol: return [.none, .low, .medium, .high]
            case .gpt6Astra: return [.low, .medium, .high, .xhigh, .max]
            }
        }

        /// Os modelos de raciocínio da OpenAI removeram os parâmetros de amostragem: qualquer
        /// `temperature` diferente do default volta 400 ("does not support 0.3 with this model").
        var acceptsTemperature: Bool { false }
    }

    /// Idioma da interface. `system` deixa o macOS escolher entre as localizações do bundle.
    enum InterfaceLanguage: String, CaseIterable, Codable {
        case system
        case portuguese = "pt-BR"
        case english = "en"
        case spanish = "es"
        case french = "fr"
        case german = "de"
        case japanese = "ja"
        case chinese = "zh-Hans"

        var displayName: String {
            switch self {
            case .system: return String(localized: "Automático (idioma do sistema)")
            case .portuguese: return "Português (BR)"
            case .english: return "English"
            case .spanish: return "Español"
            case .french: return "Français"
            case .german: return "Deutsch"
            case .japanese: return "日本語"
            case .chinese: return "简体中文"
            }
        }

        /// Código para `AppleLanguages`. `nil` = remove a preferência e volta ao idioma do sistema.
        var localeCode: String? {
            self == .system ? nil : rawValue
        }
    }

    /// Preferência visual do app. A conversão para `ColorScheme` fica na camada SwiftUI para este
    /// modelo continuar independente da UI e simples de decodificar nos testes de compatibilidade.
    enum InterfaceAppearance: String, CaseIterable, Codable {
        case system
        case light
        case dark

        var displayName: String {
            switch self {
            case .system: return String(localized: "Automático (sistema)")
            case .light: return String(localized: "Claro")
            case .dark: return String(localized: "Escuro")
            }
        }
    }

    /// Idioma em que a IA escreve as notas da reunião.
    enum NotesLanguage: String, CaseIterable, Codable {
        case spoken
        case interface
        case portuguese = "pt-BR"
        case english = "en"

        var displayName: String {
            switch self {
            case .spoken: return String(localized: "Seguir o idioma falado")
            case .interface: return String(localized: "Seguir a interface")
            case .portuguese: return "Português (BR)"
            case .english: return "English"
            }
        }
    }

    /// Modo de transcrição e processamento da reunião.
    enum MeetingMode: String, CaseIterable, Codable, Identifiable, Sendable {
        case quality
        case granola

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .quality: return String(localized: "Qualidade (Pós-processamento)")
            case .granola: return String(localized: "Ao vivo")
            }
        }

        var menuLabel: String {
            switch self {
            case .quality: return String(localized: "Qualidade")
            case .granola: return String(localized: "Ao vivo")
            }
        }

        var description: String {
            switch self {
            case .quality:
                return String(localized: "Gravação com pós-processamento completo (ASR em lotes, diarização, eco e resumo automático).")
            case .granola:
                return String(localized: "Transcrição contínua com Apple SpeechAnalyzer, com resumo automático ao encerrar.")
            }
        }
    }

    enum TranslationProvider: String, CaseIterable, Codable {
        case openai
        case anthropic
        case xai
        case gemini
        case custom

        var displayName: String {
            switch self {
            case .openai: return "OpenAI"
            case .anthropic: return "Anthropic (Claude)"
            case .xai: return "xAI (Grok)"
            case .gemini: return "Google (Gemini)"
            case .custom: return String(localized: "Custom (OpenAI-compatible)")
            }
        }

        /// Todos os provedores usam a chave de API configurada pelo usuário.
        var requiresAPIKey: Bool { true }

        nonisolated init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            // Migra o provedor removido sem perder preferências ou escolhas de modelo salvas.
            // A API continua exigindo uma chave própria; nenhuma sessão é reaproveitada.
            if value == "chatgpt" {
                self = .openai
            } else if let provider = Self(rawValue: value) {
                self = provider
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Provedor de IA desconhecido")
            }
        }

        /// Cada família fala um dialeto diferente — corpo, resposta e SSE mudam. Quem monta a
        /// requisição e lê a resposta ramifica por aqui em vez de comparar o provider direto.
        enum WireProtocol {
            /// `chat/completions`: o formato que virou padrão de fato (xAI, Gemini, endpoints custom).
            case chatCompletions
            /// `/v1/responses` da OpenAI. É o endpoint onde os modelos de raciocínio rendem melhor
            /// e o único que aceita `effort: max` — o `chat/completions` para no `xhigh`.
            case openAIResponses
            /// `/v1/messages` da Anthropic: system fora do array, `max_tokens` obrigatório,
            /// autenticação por `x-api-key`.
            case anthropicMessages
        }

        var wireProtocol: WireProtocol {
            switch self {
            case .openai: return .openAIResponses
            case .anthropic: return .anthropicMessages
            case .xai, .gemini, .custom: return .chatCompletions
            }
        }

        /// Endpoint fixo do provedor. Para `.custom` é vazio — o destino real vem de
        /// `AppSettings.currentBaseURL` (a URL que o usuário configura).
        ///
        /// O Gemini entra pela camada de compatibilidade OpenAI do Google (mesmo corpo
        /// `chat/completions`, mesma autenticação `Bearer`), então usa o mesmo caminho de código dos
        /// outros — sem SDK nem tradução de payload.
        var baseURL: String {
            switch self {
            case .openai: return "https://api.openai.com/v1/responses"
            case .anthropic: return "https://api.anthropic.com/v1/messages"
            case .xai: return "https://api.x.ai/v1/chat/completions"
            case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
            case .custom: return ""
            }
        }
    }

    enum AnthropicModel: String, CaseIterable, Codable {
        case haiku45 = "claude-haiku-4-5"
        case sonnet5 = "claude-sonnet-5"
        case opus5 = "claude-opus-5"
        case fable51 = "claude-fable-5-1"

        var displayName: String {
            switch self {
            case .haiku45: return "Claude Haiku 4.5"
            case .sonnet5: return "Claude Sonnet 5"
            case .opus5: return "Claude Opus 5"
            case .fable51: return "Claude Fable 5.1"
            }
        }

        var modelId: String { rawValue }

        var description: String {
            switch self {
            case .haiku45: return String(localized: "Rápido e econômico")
            case .sonnet5: return String(localized: "Equilíbrio entre custo e qualidade")
            case .opus5: return String(localized: "Mais capaz em tarefas longas")
            case .fable51: return String(localized: "Máxima qualidade, mais caro")
            }
        }

        /// O Haiku 4.5 é da geração anterior e **rejeita** `output_config.effort`; a família 5
        /// aceita a escala, menos o "nenhum" — desligar o raciocínio nesses modelos tem efeitos
        /// colaterais documentados (tags internas vazando no texto), então o mínimo aqui é `low`.
        var supportedReasoningEfforts: [ReasoningEffort] {
            switch self {
            case .haiku45: return []
            case .sonnet5, .opus5: return [.low, .medium, .high]
            case .fable51: return [.low, .medium, .high, .xhigh, .max]
            }
        }

        /// Só o Haiku 4.5 ainda aceita `temperature`; na família 5 o parâmetro foi removido e a
        /// requisição volta 400.
        var acceptsTemperature: Bool { self == .haiku45 }
    }

    enum GeminiModel: String, CaseIterable, Codable {
        case gemini38Flash = "gemini-3.8-flash"
        case gemini37Flash = "gemini-3.7-flash"
        case gemini36Flash = "gemini-3.6-flash"
        case gemini35Flash = "gemini-3.5-flash"
        case gemini35FlashLite = "gemini-3.5-flash-lite"
        case gemini31FlashLite = "gemini-3.1-flash-lite"
        case gemini31ProPreview = "gemini-3.1-pro-preview"
        case gemini25Flash = "gemini-2.5-flash"
        case gemini25Pro = "gemini-2.5-pro"

        var displayName: String {
            switch self {
            case .gemini38Flash: return "Gemini 3.8 Flash"
            case .gemini37Flash: return "Gemini 3.7 Flash"
            case .gemini31FlashLite: return "Gemini 3.1 Flash-Lite"
            case .gemini36Flash: return "Gemini 3.6 Flash"
            case .gemini35Flash: return "Gemini 3.5 Flash"
            case .gemini35FlashLite: return "Gemini 3.5 Flash-Lite"
            case .gemini31ProPreview: return "Gemini 3.1 Pro (preview)"
            case .gemini25Flash: return "Gemini 2.5 Flash"
            case .gemini25Pro: return "Gemini 2.5 Pro"
            }
        }

        var modelId: String { rawValue }

        var description: String {
            switch self {
            case .gemini38Flash: return String(localized: "Mais recente e mais capaz")
            case .gemini37Flash: return String(localized: "Mais capaz em tarefas longas")
            case .gemini31FlashLite: return String(localized: "Geração anterior, econômico")
            case .gemini36Flash: return String(localized: "Equilíbrio de velocidade e qualidade")
            case .gemini35Flash: return String(localized: "Mais capaz em tarefas longas")
            case .gemini35FlashLite: return String(localized: "Mais rápido e barato")
            case .gemini31ProPreview: return String(localized: "Máxima capacidade; preview")
            case .gemini25Flash: return String(localized: "Geração anterior, econômico")
            case .gemini25Pro: return String(localized: "Geração anterior, raciocínio profundo")
            }
        }

        /// A camada compatível do Google traduz `reasoning_effort` para `thinking_level`/
        /// `thinking_budget`. Só o 2.5 Flash desliga o raciocínio — o 2.5 Pro e a família 3 não.
        var supportedReasoningEfforts: [ReasoningEffort] {
            switch self {
            case .gemini25Flash: return [.none, .low, .medium, .high]
            default: return [.low, .medium, .high]
            }
        }
    }

    /// Modelos vivos da API da xAI. Toda a família `grok-3`/`grok-4-fast`/`grok-4-1-fast` foi
    /// aposentada em 15/05/2026: os slugs antigos ainda respondem, mas são redirecionados para
    /// `grok-4.3` e cobrados no preço dele — por isso saíram da lista em vez de continuarem
    /// como "econômicos".
    enum XAIModel: String, CaseIterable, Codable {
        case grok46 = "grok-4.6"
        case grok420NonReasoning = "grok-4.20-0309-non-reasoning"
        case grok45 = "grok-4.5"
        case grok43 = "grok-4.3"
        case grok420Reasoning = "grok-4.20-0309-reasoning"
        case grokBuild01 = "grok-build-0.1"

        var displayName: String {
            switch self {
            case .grok46: return "Grok 4.6"
            case .grok420NonReasoning: return "Grok 4.20 Non-Reasoning"
            case .grok45: return "Grok 4.5"
            case .grok43: return "Grok 4.3"
            case .grok420Reasoning: return "Grok 4.20 Reasoning"
            case .grokBuild01: return "Grok Build 0.1"
            }
        }

        var modelId: String { rawValue }

        var description: String {
            switch self {
            case .grok420NonReasoning: return String(localized: "Sem raciocínio, menor latência")
            case .grok46: return String(localized: "Mais recente e mais capaz")
            case .grok45: return String(localized: "Mais capaz em tarefas longas")
            case .grok43: return String(localized: "Contexto de 1M, forte em ferramentas")
            case .grok420Reasoning: return String(localized: "Com raciocínio, mais preciso")
            case .grokBuild01: return String(localized: "Focado em código e agentes")
            }
        }

        /// No 4.20 o raciocínio está no próprio slug (não há parâmetro), e o 4.5 não desliga —
        /// o mínimo dele é `low`. Para o Build 0.1 a xAI não documenta o campo, então não mandamos.
        var supportedReasoningEfforts: [ReasoningEffort] {
            switch self {
            case .grok43: return [.none, .low, .medium, .high]
            case .grok46: return [.low, .medium, .high, .xhigh]
            case .grok45: return [.low, .medium, .high]
            case .grok420NonReasoning, .grok420Reasoning, .grokBuild01: return []
            }
        }
    }
}

extension AppSettings {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case interfaceLanguage, appearance, notesLanguage
        case selectedLanguage, autoInsertText, showConfidence, modelSize, transcriptionEngine
        case hotKey, showRecordingHUD, translationProvider
        case openAIKey, anthropicKey, xaiKey, geminiKey
        case translationModel, anthropicModel, xaiModel, geminiModel, reasoningEffort
        case customBaseURL, customKey, customModel
        case calendarSuggestionsEnabled, meetingDetectionEnabled, meetingMode, meetingLivePreviewEnabled
        case calendarSelection
        case notchOverlayEnabled
        case pushToTalkShortcut, handsFreeShortcut, dictationHotkeysEnabled
        case dictationVocabulary, dictationCorrectionsEnabled, dictationCorrectionMarkers
        case transcriptionSelectionMode, transcriptionSelections, transcriptionSettingsVersion
    }

    /// As chaves que de fato são gravadas, em texto. Existe para o teste-guarda do alvo
    /// `voizTests`, que compara esta lista com as propriedades armazenadas de `AppSettings`
    /// (via `Mirror`) e quebra quando alguém adiciona um campo e esquece do `CodingKeys`.
    ///
    /// Esse esquecimento é silencioso e caro: como `CodingKeys` é manual, o `encode` sintetizado
    /// usa **estas** chaves — o campo novo simplesmente nunca chega ao disco, sem erro nenhum.
    static var persistedCodingKeyNames: [String] { CodingKeys.allCases.map(\.stringValue) }

    /// Decode tolerante a chaves ausentes: começa dos defaults e sobrescreve só o que estiver
    /// presente no JSON. Assim, **adicionar um campo novo não zera os settings já salvos** do
    /// usuário (o decode sintetizado lança em chave faltante e o `SettingsStore.load()` cairia
    /// para todos os defaults, perdendo provider/keys do BYO). Encode continua sintetizado.
    nonisolated init(from decoder: Decoder) throws {
        var s = AppSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        s.interfaceLanguage = try c.decodeIfPresent(InterfaceLanguage.self, forKey: .interfaceLanguage) ?? s.interfaceLanguage
        s.appearance = (try? c.decodeIfPresent(InterfaceAppearance.self, forKey: .appearance)) ?? s.appearance
        s.notesLanguage = try c.decodeIfPresent(NotesLanguage.self, forKey: .notesLanguage) ?? s.notesLanguage
        // `try?`, e não `try`: settings gravados antes de 29/08/2026 têm `"auto"` aqui, e esse
        // caso não existe mais. Com `try` o decode inteiro lançaria e o `SettingsStore.load()`
        // cairia para TODOS os defaults — levando junto provider, chaves do BYO e atalhos. Um
        // idioma que esta versão não entende cai no default do campo, e só nele.
        s.selectedLanguage = (try? c.decodeIfPresent(Language.self, forKey: .selectedLanguage)) ?? s.selectedLanguage
        s.autoInsertText = try c.decodeIfPresent(Bool.self, forKey: .autoInsertText) ?? s.autoInsertText
        s.showConfidence = try c.decodeIfPresent(Bool.self, forKey: .showConfidence) ?? s.showConfidence
        s.modelSize = try c.decodeIfPresent(ModelSize.self, forKey: .modelSize) ?? s.modelSize
        // Saved settings from before the engine selector implicitly used WhisperKit.
        // Preserve that behavior; only a fresh installation starts with Apple Speech.
        s.transcriptionEngine = try c.decodeIfPresent(TranscriptionEngine.self, forKey: .transcriptionEngine)
            ?? Self.legacyDefaultTranscriptionEngine
        s.hotKey = try c.decodeIfPresent(KeyboardShortcut.self, forKey: .hotKey) ?? s.hotKey
        s.showRecordingHUD = try c.decodeIfPresent(Bool.self, forKey: .showRecordingHUD) ?? s.showRecordingHUD
        s.translationProvider = try c.decodeIfPresent(TranslationProvider.self, forKey: .translationProvider) ?? s.translationProvider
        s.openAIKey = try c.decodeIfPresent(String.self, forKey: .openAIKey) ?? s.openAIKey
        s.anthropicKey = try c.decodeIfPresent(String.self, forKey: .anthropicKey) ?? s.anthropicKey
        s.xaiKey = try c.decodeIfPresent(String.self, forKey: .xaiKey) ?? s.xaiKey
        s.geminiKey = try c.decodeIfPresent(String.self, forKey: .geminiKey) ?? s.geminiKey
        // Catálogos de modelo mudam (slug aposentado pelo provider some do enum). Um raw value
        // desconhecido aqui lançaria e faria o `load()` cair para os defaults inteiros, perdendo
        // provider e keys — então os campos de modelo caem só para o default deles.
        s.translationModel = (try? c.decodeIfPresent(TranslationModel.self, forKey: .translationModel)) ?? s.translationModel
        s.anthropicModel = (try? c.decodeIfPresent(AnthropicModel.self, forKey: .anthropicModel)) ?? s.anthropicModel
        s.xaiModel = (try? c.decodeIfPresent(XAIModel.self, forKey: .xaiModel)) ?? s.xaiModel
        s.geminiModel = (try? c.decodeIfPresent(GeminiModel.self, forKey: .geminiModel)) ?? s.geminiModel
        s.reasoningEffort = (try? c.decodeIfPresent(ReasoningEffort.self, forKey: .reasoningEffort)) ?? s.reasoningEffort
        s.customBaseURL = try c.decodeIfPresent(String.self, forKey: .customBaseURL) ?? s.customBaseURL
        s.customKey = try c.decodeIfPresent(String.self, forKey: .customKey) ?? s.customKey
        s.customModel = try c.decodeIfPresent(String.self, forKey: .customModel) ?? s.customModel
        s.calendarSuggestionsEnabled = try c.decodeIfPresent(Bool.self, forKey: .calendarSuggestionsEnabled) ?? s.calendarSuggestionsEnabled
        s.calendarSelection = (try? c.decodeIfPresent(MeetingCalendarSelection.self, forKey: .calendarSelection)) ?? s.calendarSelection
        s.meetingDetectionEnabled = try c.decodeIfPresent(Bool.self, forKey: .meetingDetectionEnabled) ?? s.meetingDetectionEnabled
        s.meetingMode = (try? c.decodeIfPresent(MeetingMode.self, forKey: .meetingMode)) ?? s.meetingMode
        s.meetingLivePreviewEnabled = try c.decodeIfPresent(Bool.self, forKey: .meetingLivePreviewEnabled) ?? s.meetingLivePreviewEnabled
        s.notchOverlayEnabled = try c.decodeIfPresent(Bool.self, forKey: .notchOverlayEnabled) ?? s.notchOverlayEnabled
        s.pushToTalkShortcut = try c.decodeIfPresent(KeyboardShortcut.self, forKey: .pushToTalkShortcut) ?? s.pushToTalkShortcut
        s.handsFreeShortcut = try c.decodeIfPresent(KeyboardShortcut.self, forKey: .handsFreeShortcut) ?? s.handsFreeShortcut
        s.dictationHotkeysEnabled = try c.decodeIfPresent(Bool.self, forKey: .dictationHotkeysEnabled) ?? s.dictationHotkeysEnabled
        s.dictationVocabulary = try c.decodeIfPresent(String.self, forKey: .dictationVocabulary) ?? s.dictationVocabulary
        s.dictationCorrectionsEnabled = try c.decodeIfPresent(Bool.self, forKey: .dictationCorrectionsEnabled) ?? s.dictationCorrectionsEnabled
        s.dictationCorrectionMarkers = try c.decodeIfPresent(String.self, forKey: .dictationCorrectionMarkers) ?? s.dictationCorrectionMarkers
        // Mesma tolerância dos campos de modelo: um modo ou uma seleção que esta versão não
        // entende (settings escritos por uma versão mais nova) cai no default do campo em vez de
        // lançar e levar junto provider, keys e atalhos.
        s.transcriptionSelectionMode = (try? c.decodeIfPresent(TranscriptionSelectionMode.self, forKey: .transcriptionSelectionMode)) ?? s.transcriptionSelectionMode
        s.transcriptionSelections = (try? c.decodeIfPresent(TranscriptionUseCaseChoices.self, forKey: .transcriptionSelections)) ?? s.transcriptionSelections
        s.transcriptionSettingsVersion = (try? c.decodeIfPresent(Int.self, forKey: .transcriptionSettingsVersion)) ?? s.transcriptionSettingsVersion
        self = s
    }
}

extension NSEvent.ModifierFlags {
    nonisolated init(carbonFlags: UInt32) {
        self.init()
        if carbonFlags & UInt32(cmdKey) != 0 { insert(.command) }
        if carbonFlags & UInt32(optionKey) != 0 { insert(.option) }
        if carbonFlags & UInt32(controlKey) != 0 { insert(.control) }
        if carbonFlags & UInt32(shiftKey) != 0 { insert(.shift) }
    }
    
    nonisolated var carbonFlags: UInt32 {
        var carbon: UInt32 = 0
        if contains(.command) { carbon |= UInt32(cmdKey) }
        if contains(.option) { carbon |= UInt32(optionKey) }
        if contains(.control) { carbon |= UInt32(controlKey) }
        if contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }
}
