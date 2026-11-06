import Testing

@Suite("Provider credentials — explicit draft confirmation")
struct SettingsCredentialEditBufferTests {
    @Test("Typing and replacing text produces only the final value on apply")
    func typingCoalescesUntilConfirmation() throws {
        var buffer = SettingsCredentialEditBuffer()
        for value in ["s", "sk", "sk-", "sk-incomplete", "", "SYNTHETIC_FINAL"] {
            buffer.stage(.openAIKey, value: value)
        }
        let edits = buffer.pendingEdits
        #expect(edits.count == 1)
        let edit = try #require(edits.first)
        #expect(edit.field == .openAIKey && edit.value == "SYNTHETIC_FINAL")
        let acknowledged = buffer.acknowledge(edit)
        #expect(acknowledged)
        #expect(buffer.pendingEdits.isEmpty)
    }

    @Test("A completed write cannot clear a draft edited while it was saving")
    func oldCompletionPreservesNewDraft() throws {
        var buffer = SettingsCredentialEditBuffer()
        buffer.stage(.geminiKey, value: "SYNTHETIC_CONFIRMED")
        let confirmed = try #require(buffer.pendingEdits.first)
        buffer.stage(.geminiKey, value: "SYNTHETIC_NEW_DRAFT")
        let acknowledged = buffer.acknowledge(confirmed)
        #expect(!acknowledged)
        let next = try #require(buffer.pendingEdits.first)
        #expect(next.value == "SYNTHETIC_NEW_DRAFT")
        #expect(next.revision != confirmed.revision)
        #expect(confirmed.value == "SYNTHETIC_CONFIRMED")
    }

    @Test("Failed apply retains the exact raw draft for explicit retry, including removal")
    func failureAndRemovalRemainExplicit() throws {
        var buffer = SettingsCredentialEditBuffer()
        buffer.stage(.anthropicKey, value: "  SYNTHETIC_WITH_SPACES  ")
        buffer.stage(.customKey, value: "")
        let attempted = buffer.pendingEdits
        // A storage failure never acknowledges; retry takes the same final snapshot.
        #expect(buffer.pendingEdits.map(\.value) == attempted.map(\.value))
        #expect(attempted.count == 2)
        let removed = try #require(attempted.first { $0.field == .customKey })
        #expect(removed.value.isEmpty)
        let acknowledged = buffer.acknowledge(removed)
        #expect(acknowledged)
        #expect(buffer.pendingEdits.count == 1)
        #expect(buffer.pendingEdits.first?.value == "  SYNTHETIC_WITH_SPACES  ")
    }
}
