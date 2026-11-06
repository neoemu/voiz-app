import Foundation
import Testing

@MainActor
@Suite("Local operation availability")
struct VoizAccessTests {
    @Test func unavailableLibraryRefusesNewWork() async {
        let store = VoizAccessStore(libraryAvailable: { false })
        #expect(!(await store.authorizeNewOperation(kind: .recording)))
        #expect(store.lastError == VoizAccessMessages.libraryUnavailable)
    }

    @Test func allLocalOperationsWorkWithoutAccountOrLicense() async {
        let store = VoizAccessStore(libraryAvailable: { true })
        for kind in [VoizOperationKind.recording, .transcription, .ai, .editing] {
            #expect(await store.prepareNewOperation(kind: kind, workID: UUID()))
            #expect(await store.authorizeNewOperation(kind: kind))
            #expect(store.lastError == nil)
        }
    }

    @Test func availabilityIsCheckedAgainAfterPermissionPrompt() async {
        var available = true
        let store = VoizAccessStore(libraryAvailable: { available })
        let workID = UUID()
        #expect(await store.prepareNewOperation(kind: .recording, workID: workID))
        available = false
        #expect(!(await store.authorizeNewOperation(kind: .recording, workID: workID)))
        available = true
        #expect(await store.authorizeNewOperation(kind: .recording, workID: workID))
        #expect(store.lastError == nil)
    }

    @Test func cancelledWorkNeverStartsEvenWithAvailableStorage() async {
        let store = VoizAccessStore(libraryAvailable: { true })
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await store.authorizeNewOperation(kind: .recording)
        }
        #expect(!(await task.value))
    }
}
