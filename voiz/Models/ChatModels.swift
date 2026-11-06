import Foundation

struct ChatMessage: Identifiable, Equatable, Codable {
    enum Role: String, Codable {
        case user
        case assistant

        /// Papel desconhecido (arquivo de um build futuro, ou editado à mão) vira `.assistant` em
        /// vez de derrubar a decodificação: perder o histórico inteiro por causa de uma mensagem
        /// seria pior do que exibir uma mensagem no lado errado da conversa.
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Role(rawValue: raw) ?? .assistant
        }
    }

    let id: UUID
    let role: Role
    let content: String

    init(id: UUID = UUID(), role: Role, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }
}

struct ChatSession: Identifiable, Equatable, Codable {
    let id: UUID
    var title: String
    var messages: [ChatMessage]
    let createdAt: Date
    var updatedAt: Date
    var isPinned: Bool

    init(
        id: UUID = UUID(),
        title: String = "",
        messages: [ChatMessage] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isPinned: Bool = false
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isPinned = isPinned
    }

    var displayTitle: String {
        if !title.isEmpty {
            return title
        }
        return messages.first(where: { $0.role == .user })?.content ?? String(localized: "Nova conversa")
    }

    var relativeDate: String {
        let interval = Date().timeIntervalSince(updatedAt)
        if interval < 60 {
            return String(localized: "agora")
        }
        if interval < 3600 {
            return "\(Int(interval / 60))m"
        }
        if Calendar.current.isDateInToday(updatedAt) {
            let formatter = DateFormatter()
            formatter.locale = .voizInterface
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            return formatter.string(from: updatedAt)
        }

        let formatter = DateFormatter()
        formatter.locale = .voizInterface
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        return formatter.string(from: updatedAt)
    }
}
