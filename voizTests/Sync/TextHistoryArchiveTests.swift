import Foundation
import Testing

@Suite("Retained text history and paginated cache")
@MainActor
struct TextHistoryArchiveTests {
    private struct Entry: Codable, Identifiable, Equatable {
        let id: UUID
        var text: String
        var timestamp: Date
    }

    @Test func pagingAndReopeningDoNotEvictOldRecords() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite")
        let archive = try TextHistoryArchive<Entry>(databaseURL: url, kind: "dictation")
        var inserted: [Entry] = []
        for number in 0..<150 {
            let entry = Entry(id: UUID(), text: "Text \(number)", timestamp: Date(timeIntervalSince1970: Double(number + 1)))
            try archive.upsert(entry, timestamp: entry.timestamp)
            inserted.append(entry)
        }
        #expect(try archive.page().count == 100)
        #expect(try archive.count == 150)
        let reopened = try TextHistoryArchive<Entry>(databaseURL: url, kind: "dictation")
        #expect(try reopened.page(offset: 100).count == 50)
        #expect(try reopened.entry(id: inserted[0].id) == inserted[0])
        try reopened.remove(id: inserted[149].id)
        #expect(try archive.count == 149)
    }

    @Test func unreadableMigrationDoesNotMarkOrOverwriteHistory() throws {
        let archive = try TextHistoryArchive<Entry>(databaseURL: nil, kind: "translation")
        #expect(throws: (any Error).self) { try archive.migrate(Data("broken".utf8), timestamp: \.timestamp) }
        let entry = Entry(id: UUID(), text: "Recoverable", timestamp: Date(timeIntervalSince1970: 1))
        try archive.migrate(JSONEncoder().encode([entry]), timestamp: \.timestamp)
        #expect(try archive.page() == [entry])
        try archive.migrate(Data("still broken".utf8), timestamp: \.timestamp)
        #expect(try archive.page() == [entry])
    }

    @Test func separateWritersApplyDeltasWithoutResurrectingDeletedRows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite")
        let first = try TextHistoryArchive<Entry>(databaseURL: url, kind: "translation")
        let second = try TextHistoryArchive<Entry>(databaseURL: url, kind: "translation")
        let removed = Entry(id: UUID(), text: "Remove", timestamp: Date(timeIntervalSince1970: 1))
        let added = Entry(id: UUID(), text: "Keep", timestamp: Date(timeIntervalSince1970: 2))
        try first.upsert(removed, timestamp: removed.timestamp)
        _ = try second.page()
        try first.remove(id: removed.id)
        try second.upsert(added, timestamp: added.timestamp)
        #expect(try first.page() == [added])
    }
    @Test func hiddenRowsAndKeysetPagesRemainRecoverableAcrossConnections() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite")
        let archive = try TextHistoryArchive<Entry>(databaseURL: url, kind: "dictation")
        let ids = (1...4).map { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", $0))! }
        for id in ids { try archive.upsert(Entry(id: id, text: id.uuidString, timestamp: Date(timeIntervalSince1970: 1)), timestamp: Date(timeIntervalSince1970: 1)) }
        let first = try archive.page(afterID: "", limit: 2)
        #expect(first.map(\.id) == Array(ids.prefix(2)))
        let other = try TextHistoryArchive<Entry>(databaseURL: url, kind: "dictation")
        try other.setHidden(id: ids[0], true)
        try other.setHidden(id: ids[2], true)
        #expect(try archive.count == 2)
        #expect(try archive.page(afterID: ids[1].uuidString.lowercased()).map(\.id) == [ids[3]])
        #expect(try archive.entry(id: ids[2])?.text == ids[2].uuidString)
        try other.setHidden(id: ids[2], false)
        #expect(try archive.count == 3)
    }

}
