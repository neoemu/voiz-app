import Foundation
import Testing

@Suite("History stores preserve retained text and local audio")
@MainActor
struct RetainedHistoryStoreTests {
    @Test func pagingNeverDeletesDictationAudioAndRemoteRemovalPreservesIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let audio = DictationAudioStore(directory: directory.appendingPathComponent("audio"))
        let recordingID = UUID()
        try audio.save([0.1, -0.1, 0.2], id: recordingID)
        let db = directory.appendingPathComponent("text.sqlite")
        let store = TranscriptionHistoryStore(defaults: defaults, audioStore: audio, archiveURL: db)
        let oldest = TranscriptionEntry(text: "Oldest", language: .portuguese,
                                       timestamp: Date(timeIntervalSince1970: 1), audioID: recordingID)
        store.addEntry(oldest)
        for index in 2...151 {
            store.addEntry(TranscriptionEntry(text: "Text \(index)", language: .portuguese,
                                             timestamp: Date(timeIntervalSince1970: Double(index))))
        }
        #expect(store.entries.count == 100)
        #expect(store.totalCount == 151)
        #expect(store.hasMoreEntries)
        #expect(audio.exists(recordingID))
        let reopened = TranscriptionHistoryStore(defaults: defaults, audioStore: audio, archiveURL: db)
        #expect(reopened.entry(id: oldest.id) == oldest)
        reopened.loadMore()
        #expect(reopened.entries.count == 151)
        reopened.removeSyncedText(id: oldest.id)
        #expect(reopened.entry(id: oldest.id) == nil)
        #expect(audio.exists(recordingID))
    }

    @Test func translationPaginationAndConcurrentRenamesDoNotResurrectRows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let db = directory.appendingPathComponent("text.sqlite")
        let first = TranslationHistoryStore(defaults: defaults, archiveURL: db, watchChanges: false)
        let oldest = TranslationEntry(sourceText: "Olá", translatedText: "Hello", sourceLanguage: .portuguese,
                                      targetLanguage: .english, timestamp: Date(timeIntervalSince1970: 1))
        #expect(first.addEntry(oldest))
        for index in 2...125 {
            #expect(first.addEntry(TranslationEntry(sourceText: "Texto \(index)", translatedText: "Text \(index)",
                sourceLanguage: .portuguese, targetLanguage: .english, timestamp: Date(timeIntervalSince1970: Double(index)))))
        }
        let second = TranslationHistoryStore(defaults: defaults, archiveURL: db, watchChanges: false)
        #expect(second.totalCount == 125)
        #expect(second.entries.count == 100)
        #expect(first.deleteEntry(oldest))
        #expect(second.renameEntry(oldest, to: "Stale rename"))
        #expect(second.entry(id: oldest.id) == nil)
        second.loadMore()
        #expect(second.entries.count == 124)
    }

    @Test func corruptLegacyHistoryRefusesNewWritesAndKeepsOriginalBytes() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let corrupt = Data("unreadable original".utf8)
        defaults.set(corrupt, forKey: "translationHistory")
        let store = TranslationHistoryStore(defaults: defaults, watchChanges: false)
        #expect(store.storageError != nil)
        #expect(!store.addEntry(TranslationEntry(sourceText: "Hi", translatedText: "Olá", sourceLanguage: .english, targetLanguage: .portuguese)))
        #expect(defaults.data(forKey: "translationHistory") == corrupt)
    }
}
