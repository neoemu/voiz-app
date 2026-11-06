import Foundation

struct TranscriptionEntry: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    let language: Language
    let timestamp: Date
    let duration: TimeInterval
    /// Nome customizado dado pelo usuário (Renomear). `nil` = usa o preview do texto.
    var title: String?
    /// De onde veio este texto: motor, modelo e se foi fallback (T2.4a).
    ///
    /// **Opcional, e para sempre**: as entradas gravadas antes desta versão não têm a chave, e o
    /// decode sintetizado de um `Optional` usa `decodeIfPresent` — histórico antigo continua
    /// abrindo inteiro, com `nil` aqui. É a mesma disciplina da T1.4 (campo novo nunca derruba o
    /// que já está no disco). O encode omite a chave quando é `nil`, então uma entrada sem
    /// proveniência também não engorda o `UserDefaults`.
    ///
    /// A UI que mostra isso é a T6.3; aqui a proveniência só é **registrada**.
    var provenance: TranscriptionProvenance?
    /// Optional fields preserve decoding of older history entries.
    var audioID: UUID?
    var rawText: String?
    var previousText: String?
    var processingMessage: String?

    init(
        id: UUID = UUID(),
        text: String,
        language: Language,
        timestamp: Date = Date(),
        duration: TimeInterval = 0,
        title: String? = nil,
        provenance: TranscriptionProvenance? = nil,
        audioID: UUID? = nil,
        rawText: String? = nil,
        previousText: String? = nil,
        processingMessage: String? = nil
    ) {
        self.id = id
        self.text = text
        self.language = language
        self.timestamp = timestamp
        self.duration = duration
        self.title = title
        self.provenance = provenance
        self.audioID = audioID
        self.rawText = rawText
        self.previousText = previousText
        self.processingMessage = processingMessage
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.locale = .voizInterface
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }

    var preview: String {
        if text.count <= 100 {
            return text
        }
        return String(text.prefix(100)) + "..."
    }

    /// Título exibido na lista: nome customizado, se houver; senão o preview do texto.
    var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        return preview.isEmpty ? String(localized: "Ditado") : preview
    }
}
