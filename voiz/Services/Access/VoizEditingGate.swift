import Foundation

/// Keep a deliberate edit or editor session attached to its original library.
/// Starting activity before the availability check also prevents switching libraries in between.
@MainActor
final class VoizEditingGate {
    static let shared = VoizEditingGate()
    private let authorize: @MainActor () async -> Bool
    private let currentLibrary: @MainActor () -> UUID?
    private let tracker: VoizWorkTracker

    init(authorize: @escaping @MainActor () async -> Bool = { await VoizAccessStore.shared.authorizeNewOperation(kind: .editing) },
         currentLibrary: @escaping @MainActor () -> UUID? = { LocalLibraryRuntime.shared.context?.libraryID },
         tracker: VoizWorkTracker? = nil) {
        self.authorize = authorize
        self.currentLibrary = currentLibrary
        self.tracker = tracker ?? .shared
    }

    func begin() async -> VoizWorkActivity? {
        let library = currentLibrary()
        let activity = tracker.beginActivity()
        guard await authorize(), !Task.isCancelled, currentLibrary() == library else {
            activity.finish()
            return nil
        }
        return activity
    }
    @discardableResult
    func submit(_ change: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            guard let activity = await begin() else { return }
            defer { activity.finish() }
            change()
        }
    }
}
