import Foundation
import Testing

@MainActor
@Suite("Concurrent chat history persistence")
struct ChatHistoryConcurrencyTests {
    @Test func concurrentMessageAndTitleEditsAreMergedWithoutResurrectingDeletedConversations() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = ChatHistoryStore(directoryURL: directory)
        let original = ChatSession(title: "Original", messages: [ChatMessage(role: .user, content: "Question")])
        #expect(first.save([original]))
        let second = ChatHistoryStore(directoryURL: directory)
        var firstView = first.load()
        var secondView = second.load()
        firstView[0].messages.append(ChatMessage(role: .assistant, content: "Answer from the first window"))
        #expect(first.save(firstView))
        secondView[0].title = "Renamed in the second window"
        #expect(second.save(secondView))
        let merged = try #require(first.load().first)
        #expect(merged.title == secondView[0].title)
        #expect(merged.messages == firstView[0].messages)
        #expect(first.save([]))
        secondView[0].isPinned = true
        #expect(!second.save(secondView))
        #expect(ChatHistoryStore(directoryURL: directory).load().isEmpty)
    }

    @Test func divergentTitleEditsFailWithoutReplacingStoredBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = ChatHistoryStore(directoryURL: directory)
        #expect(first.save([ChatSession(title: "Original")]))
        let second = ChatHistoryStore(directoryURL: directory)
        var a = first.load(), b = second.load()
        a[0].title = "First"
        b[0].title = "Second"
        #expect(first.save(a))
        let url = directory.appendingPathComponent("sessions.json")
        let saved = try Data(contentsOf: url)
        #expect(!second.save(b))
        #expect(try Data(contentsOf: url) == saved)
    }

    @Test func corruptExistingFileIsNeverReplacedByAnEmptyWindow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("sessions.json")
        let original = Data("unreadable conversation".utf8)
        try original.write(to: url)
        let store = ChatHistoryStore(directoryURL: directory)
        #expect(store.load().isEmpty)
        #expect(!store.save([ChatSession(title: "New")]))
        #expect(try Data(contentsOf: url) == original)
    }
}
