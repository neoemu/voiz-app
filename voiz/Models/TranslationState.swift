import Foundation

enum TranslationIssue: Equatable {
    case missingAPIKey(provider: String)
    case credentialsUnavailable
    case requestFailed
    case speechDetectionUnavailable
    case audioProcessingFailed

    static func configuration(in settings: AppSettings, credentialsAreReady: Bool = true) -> Self? {
        guard credentialsAreReady else { return nil }
        guard settings.translationProvider.requiresAPIKey,
              settings.currentAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return .missingAPIKey(provider: settings.translationProvider.displayName)
    }

    func afterSettingsReload(settingsChanged: Bool, credentialsAreReady: Bool) -> Self? {
        if self == .credentialsUnavailable {
            return credentialsAreReady ? nil : self
        }
        return settingsChanged ? nil : self
    }

    var message: String {
        switch self {
        case .missingAPIKey(let provider):
            return String(localized: "Configure a chave de \(provider) em Configurações → IA & Tradução para começar.")
        case .credentialsUnavailable:
            return String(localized: "Não foi possível acessar as chaves de API. Tente novamente em Configurações → IA & Tradução.")
        case .speechDetectionUnavailable:
            return String(localized: "Não foi possível preparar a detecção de fala. Confira a conexão para baixar o modelo e tente novamente.")
        case .audioProcessingFailed:
            return String(localized: "A gravação foi interrompida porque o áudio não pôde ser processado. O texto disponível foi preservado.")
        case .requestFailed:
            // Provider errors can echo request content. Keep those details out of this notice and logs.
            return String(localized: "Não foi possível traduzir. Verifique a conexão e a configuração do provedor de IA.")
        }
    }
}

nonisolated enum TranslationArchiveNotice: Equatable {
    case complete
    case missingTail
    case translationIncomplete

    static func result(drainCompleted: Bool, translationFailed: Bool) -> Self {
        if translationFailed { return .translationIncomplete }
        return drainCompleted ? .complete : .missingTail
    }

    /// An archived original is not proof of a successful translation. Keep it visible after a failure.
    var shouldClearWorkspace: Bool { self != .translationIncomplete }

    var message: String {
        switch self {
        case .complete: return String(localized: "Salvo em Recentes")
        case .missingTail: return String(localized: "Salvo em Recentes (sem o final)")
        case .translationIncomplete: return String(localized: "Original salvo; tradução incompleta")
        }
    }
}


/// Provider requests may finish in any order. Only the settled source-order prefix is
/// shown live; closing a recording preserves every completed result in source order.
/// Tickets belong to one recording, so delayed callbacks cannot mutate the next one.
nonisolated struct OrderedTranslationResults {
    struct Ticket: Hashable, Sendable {
        fileprivate let session: UUID
        fileprivate let index: Int
    }

    private enum Slot {
        case pending
        case translated(String)
        case failed
    }

    private var session = UUID()
    private var slots: [Slot] = []
    private var acceptingResults = true

    mutating func reset() {
        session = UUID()
        slots = []
        acceptingResults = true
    }

    mutating func reserve() -> Ticket? {
        guard acceptingResults else { return nil }
        let ticket = Ticket(session: session, index: slots.count)
        slots.append(.pending)
        return ticket
    }

    @discardableResult
    mutating func complete(_ ticket: Ticket, text: String) -> Bool {
        settle(ticket, as: .translated(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    @discardableResult
    mutating func fail(_ ticket: Ticket) -> Bool {
        settle(ticket, as: .failed)
    }

    private mutating func settle(_ ticket: Ticket, as result: Slot) -> Bool {
        guard acceptingResults, ticket.session == session, slots.indices.contains(ticket.index),
              case .pending = slots[ticket.index] else { return false }
        slots[ticket.index] = result
        return true
    }

    var text: String {
        var parts: [String] = []
        for slot in slots {
            switch slot {
            case .pending: return parts.joined(separator: " ")
            case .translated(let text): if !text.isEmpty { parts.append(text) }
            case .failed: continue
            }
        }
        return parts.joined(separator: " ")
    }

    /// Also used when the drain deadline expires: release completed successors of a
    /// missing chunk, then refuse late results. The caller reports the partial archive.
    mutating func close() {
        for index in slots.indices {
            if case .pending = slots[index] { slots[index] = .failed }
        }
        acceptingResults = false
    }
}
