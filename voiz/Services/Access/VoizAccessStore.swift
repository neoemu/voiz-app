import Combine
import Foundation

nonisolated enum VoizOperationKind: String, Codable, Sendable {
    case recording, transcription, ai, editing
}

nonisolated enum VoizAccessMessages {
    static var libraryUnavailable: String {
        String(localized: "Não foi possível iniciar a operação nesta biblioteca. Confira a biblioteca no Perfil.")
    }
}

/// Guards local storage availability and cancellation. No account, license or network admission.
@MainActor
final class VoizAccessStore: ObservableObject {
    static let shared = VoizAccessStore(
        libraryAvailable: { LocalLibraryRuntime.shared.canStartNewWorkInLibrary }
    )

    @Published private(set) var lastError: String?
    private let libraryAvailable: @MainActor () -> Bool

    init(libraryAvailable: @escaping @MainActor () -> Bool) {
        self.libraryAvailable = libraryAvailable
    }

    func dismissError() { lastError = nil }

    /// Check before prompting for permissions and again immediately before starting work.
    func prepareNewOperation(kind: VoizOperationKind, workID: UUID) async -> Bool {
        await authorizeNewOperation(kind: kind, workID: workID)
    }

    @discardableResult
    func authorizeNewOperation(kind: VoizOperationKind = .editing, workID: UUID = UUID()) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard libraryAvailable() else {
            lastError = VoizAccessMessages.libraryUnavailable
            return false
        }
        lastError = nil
        return true
    }
}
