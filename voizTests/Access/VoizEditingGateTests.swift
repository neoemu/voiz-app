import Foundation
import Testing

@MainActor
@Suite("Editing admission and library ownership")
struct VoizEditingGateTests {
    @Test func deniedEditingDoesNotRunMutationOrKeepActivity() async {
        let tracker = VoizWorkTracker()
        var edited = false
        let gate = VoizEditingGate(authorize: { false }, currentLibrary: { nil }, tracker: tracker)
        await gate.submit { edited = true }.value
        #expect(!edited)
        #expect(!tracker.hasActiveWork)
    }
    @Test func admittedEditorKeepsWorkActiveUntilTheUserFinishes() async throws {
        let tracker = VoizWorkTracker()
        let id = UUID()
        let gate = VoizEditingGate(authorize: { #expect(tracker.hasActiveWork); return true }, currentLibrary: { id }, tracker: tracker)
        let activity = try #require(await gate.begin())
        #expect(tracker.hasActiveWork)
        activity.finish()
        #expect(!tracker.hasActiveWork)
    }
    @Test func changingLibraryDuringAuthorizationDoesNotWriteOldUIState() async {
        let tracker = VoizWorkTracker()
        var id = UUID()
        var edited = false
        let gate = VoizEditingGate(authorize: { id = UUID(); return true }, currentLibrary: { id }, tracker: tracker)
        await gate.submit { edited = true }.value
        #expect(!edited)
        #expect(!tracker.hasActiveWork)
    }
}
