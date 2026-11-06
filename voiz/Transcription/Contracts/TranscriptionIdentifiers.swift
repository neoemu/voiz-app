import Foundation

// Contratos da transcrição V2 (T1.2). Este arquivo — e todos os outros de
// `Transcription/Contracts/` — depende **só de Foundation**: nada de UI, de serviços, de
// singletons ou de I/O. É essa pureza que permite compilá-los direto no alvo `voizTests`
// (que não tem host app, logo não tem `@testable import voiz`).
//
// Tudo aqui é `nonisolated` de propósito: o alvo do app compila com
// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, e sem a anotação estes tipos puros herdariam
// o MainActor — o coordenador da Onda 2 precisa deles fora da main thread.

/// Identificador de um motor de transcrição (WhisperKit, Parakeet, Apple SpeechAnalyzer…).
///
/// String embrulhada em vez de `enum` por dois motivos: o catálogo cresce por onda (o
/// TAGARELA entra só na Onda 5, com os artefatos CoreML dele) e os testes precisam inventar
/// motores falsos sem alterar o tipo. O `rawValue` é estável — vai para a proveniência
/// persistida e para os logs, então renomear um id é migração, não refactor.
nonisolated struct TranscriptionEngineID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }

    var description: String { rawValue }

    /// Codifica como string pura (`"whisperkit"`), não como `{"rawValue": …}`: a proveniência
    /// é persistida em JSON e lida por humanos.
    init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated extension TranscriptionEngineID {
    /// Fallback eterno: é o motor que o app já usa hoje e o único que roda em qualquer Mac.
    static let whisperKit = TranscriptionEngineID("whisperkit")
    /// Parakeet v3 genérico via FluidAudio (experimental desde o spike atual).
    static let parakeet = TranscriptionEngineID("parakeet")
    /// `SpeechAnalyzer`/`SpeechTranscriber` do macOS 26 — batch e streaming.
    static let appleSpeechAnalyzer = TranscriptionEngineID("apple-speech-analyzer")
}

/// Identificador de um conjunto de pesos. Para o WhisperKit é o nome da variante no repositório
/// CoreML (`openai_whisper-small`); para os outros motores, o id do checkpoint ou um marcador do
/// modelo do sistema. Vale a mesma regra de estabilidade do `TranscriptionEngineID`.
nonisolated struct TranscriptionModelID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }

    var description: String { rawValue }

    init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated extension TranscriptionModelID {
    // Variantes WhisperKit — os mesmos nomes que `AppSettings.ModelSize.whisperModelName`
    // já usa hoje, para a migração da Onda 2 não precisar traduzir nada.
    static let whisperBase = TranscriptionModelID("openai_whisper-base")
    static let whisperSmall = TranscriptionModelID("openai_whisper-small")
    static let whisperMedium = TranscriptionModelID("openai_whisper-medium")
    static let whisperLargeV3Turbo = TranscriptionModelID("openai_whisper-large-v3_turbo")

    /// Parakeet v3 multilíngue, distribuído pelo ModelHub do FluidAudio.
    static let parakeetTDT06BV3 = TranscriptionModelID("parakeet-tdt-0.6b-v3")

    // O modelo do `SpeechTranscriber` é do sistema: não é baixado por nós nem versionado aqui,
    // só reservado/instalado pelo `AssetInventory` **por locale**. E o locale é fixo no módulo:
    // não existe "detecte o idioma". Por isso há um id **por locale**, e não um id só — é o que
    // deixa a proveniência gravada dizer qual locale produziu o texto e o roteador escolher entre
    // eles pelo idioma pedido (T3.3).
    // Um id por locale, e não um id só para "o modelo do sistema": no Apple SpeechAnalyzer o
    // locale **é** o modelo, e um id genérico faria a proveniência gravada não dizer qual locale
    // produziu o texto.
    static let appleSystemSpeechPTBR = TranscriptionModelID("apple-system-speech.pt-BR")
    static let appleSystemSpeechENUS = TranscriptionModelID("apple-system-speech.en-US")
    static let appleSystemSpeechESES = TranscriptionModelID("apple-system-speech.es-ES")
    static let appleSystemSpeechFRFR = TranscriptionModelID("apple-system-speech.fr-FR")
    static let appleSystemSpeechDEDE = TranscriptionModelID("apple-system-speech.de-DE")
    static let appleSystemSpeechJAJP = TranscriptionModelID("apple-system-speech.ja-JP")
    static let appleSystemSpeechZHCN = TranscriptionModelID("apple-system-speech.zh-CN")
}

/// Idioma falado pedido a um motor, em BCP-47 (`pt-BR`, `en-US`).
///
/// Um motor pode declarar `pt-BR` e receber um pedido `pt`: `matches(_:)` casa pelo código
/// primário quando a região não é especificada dos dois lados, e nunca casa `pt-BR` com `pt-PT`.
nonisolated struct TranscriptionLanguage: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }

    /// Normaliza separador (`pt_BR` → `pt-BR`) e caixa (`PT-br` → `pt-BR`) para que dois
    /// caminhos diferentes do app não produzam idiomas "diferentes" com o mesmo significado.
    init(_ rawValue: String) {
        let unified = rawValue.replacingOccurrences(of: "_", with: "-")
        let parts = unified.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
        guard let primary = parts.first else {
            self.rawValue = ""
            return
        }
        if parts.count == 2 {
            self.rawValue = primary.lowercased() + "-" + parts[1].uppercased()
        } else {
            self.rawValue = primary.lowercased()
        }
    }

    var description: String { rawValue }

    /// `pt` em `pt-BR`.
    var primaryCode: String {
        String(rawValue.split(separator: "-", maxSplits: 1).first ?? "")
    }

    /// `BR` em `pt-BR`; `nil` quando o idioma não tem região.
    var regionCode: String? {
        let parts = rawValue.split(separator: "-", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : nil
    }

    /// Este idioma (o **suportado** por um motor) atende `wanted` (o **pedido**)?
    ///
    /// Regra: iguais casam; `pt-BR` atende um pedido `pt`; um motor que declara só `pt`
    /// atende `pt-BR` (é a leitura generosa correta — quem declara o genérico cobre as
    /// variantes); `pt-BR` **não** atende `pt-PT`.
    func matches(_ wanted: TranscriptionLanguage) -> Bool {
        if rawValue == wanted.rawValue { return true }
        guard primaryCode == wanted.primaryCode else { return false }
        return regionCode == nil || wanted.regionCode == nil
    }

    init(from decoder: any Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated extension TranscriptionLanguage {
    // Genéricos: é o vocabulário do plano e dos motores multilíngues (`canonical` reduz tudo a
    // isto). Regionais: o que os motores de locale fixo declaram, um por variante servida.
    static let portuguese = TranscriptionLanguage("pt")
    static let english = TranscriptionLanguage("en")
    static let spanish = TranscriptionLanguage("es")
    static let french = TranscriptionLanguage("fr")
    static let german = TranscriptionLanguage("de")
    static let japanese = TranscriptionLanguage("ja")
    static let chinese = TranscriptionLanguage("zh")

    static let portugueseBrazil = TranscriptionLanguage("pt-BR")
    static let englishUS = TranscriptionLanguage("en-US")
    static let spanishSpain = TranscriptionLanguage("es-ES")
    static let frenchFrance = TranscriptionLanguage("fr-FR")
    static let germanGermany = TranscriptionLanguage("de-DE")
    static let japaneseJapan = TranscriptionLanguage("ja-JP")
    static let chineseChina = TranscriptionLanguage("zh-CN")
}

/// Para que a transcrição está sendo pedida. É o eixo que decide streaming × batch,
/// prioridade e — a partir da Onda 6 — qual motor o modo automático escolhe.
///
/// Os quatro casos são os quatro chamadores reais do app. Nenhum caso especulativo entra
/// aqui: um caso a mais é uma escolha a mais para o usuário nas Configurações da Onda 6.
nonisolated enum TranscriptionUseCase: String, CaseIterable, Hashable, Sendable, Codable {
    /// Ditado (`TranscriptionViewModel`): áudio curto, usuário esperando o texto na tela.
    case dictation
    /// Trecho de tradução ao vivo (`TranslationViewModel`): áudio curto, também interativo.
    case translationChunk
    /// Preview visual da reunião (`MeetingLivePreviewService`): incremental, descartável.
    case meetingPreview
    /// Transcript oficial da reunião, em lotes (`MeetingViewModel`): roda em segundo plano e
    /// é o que fica salvo — qualidade importa mais que latência.
    case meetingFinal

    /// O caso exige um motor de streaming? Só o preview: os outros mandam um bloco de áudio
    /// fechado e esperam o resultado completo.
    var requiresStreaming: Bool { self == .meetingPreview }

    /// Tem alguém olhando a tela esperando este resultado? Define a prioridade quando o
    /// coordenador da Onda 2 tiver que escolher entre dois trabalhos.
    var isInteractive: Bool {
        switch self {
        case .dictation, .translationChunk, .meetingPreview: return true
        case .meetingFinal: return false
        }
    }
}
