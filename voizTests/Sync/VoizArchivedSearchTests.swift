import Foundation
import Testing

@MainActor
@Suite("Global search over the complete local archive")
struct VoizArchivedSearchTests {
    @Test func findsOldDictationAndTranslationOutsideTheFirstHundredAndExcludesTrash() async throws {
        let dictations = try TextHistoryArchive<TranscriptionEntry>(databaseURL: nil, kind: "dictation")
        let translations = try TextHistoryArchive<TranslationEntry>(databaseURL: nil, kind: "translation")
        let oldest = TranscriptionEntry(text: "Ação rara guardada no arquivo", language: .english, timestamp: Date(timeIntervalSince1970: 1))
        let translation = TranslationEntry(sourceText: "Outra ação rara", translatedText: "Older translated result", sourceLanguage: .english, targetLanguage: .english, timestamp: Date(timeIntervalSince1970: 2))
        try dictations.upsert(oldest, timestamp: oldest.timestamp)
        try translations.upsert(translation, timestamp: translation.timestamp)
        for n in 0..<220 {
            let entry = TranscriptionEntry(text: "Recent unrelated \(n)", language: .english, timestamp: Date(timeIntervalSince1970: Double(100 + n)))
            try dictations.upsert(entry, timestamp: entry.timestamp)
            let translated = TranslationEntry(sourceText: "Recent source", translatedText: "Recent output", sourceLanguage: .english, targetLanguage: .english, timestamp: entry.timestamp)
            try translations.upsert(translated, timestamp: translated.timestamp)
        }
        let hidden = TranscriptionEntry(text: "Ação rara na lixeira", language: .english)
        try dictations.upsert(hidden, timestamp: hidden.timestamp)
        try dictations.setHidden(id: hidden.id, true)
        #expect(try !dictations.page().contains { $0.id == oldest.id })
        #expect(try !translations.page().contains { $0.id == translation.id })
        var pages = 0
        let found = try await VoizSearch.archivedResults(query: "acao RARA", meetings: [],
            dictationPage: { pages += 1; return try dictations.page(afterID: $0, limit: 17) },
            translationPage: { pages += 1; return try translations.page(afterID: $0, limit: 13) })
        #expect(found.map(\.id) == [translation.id, oldest.id])
        #expect(pages > 20)
        #expect(!found.contains { $0.id == hidden.id })
    }

    @Test func keepsOnlyBestFortyAcrossEveryPage() async throws {
        let archive = try TextHistoryArchive<TranscriptionEntry>(databaseURL: nil, kind: "dictation")
        var values: [TranscriptionEntry] = []
        for n in 0..<175 {
            let value = TranscriptionEntry(text: "Matched synthetic text", language: .english, timestamp: Date(timeIntervalSince1970: Double(n)))
            try archive.upsert(value, timestamp: value.timestamp)
            values.append(value)
        }
        let found = try await VoizSearch.archivedResults(query: "matched", meetings: [],
            dictationPage: { try archive.page(afterID: $0, limit: 7) }, translationPage: { _ in [] })
        #expect(found.count == VoizSearch.resultLimit)
        #expect(found.map(\.id) == values.suffix(40).reversed().map(\.id))
    }

    @Test func cancellationAndReadFailureNeverReturnAPartialSuccessfulSearch() async throws {
        let task = Task { @MainActor in
            try await VoizSearch.archivedResults(query: "text", meetings: [], dictationPage: { _ in
                Issue.record("Cancelled query read a page"); return []
            }, translationPage: { _ in [] })
        }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled query completed") }
        catch is CancellationError { }
        enum SyntheticFailure: Error { case unreadable }
        do {
            _ = try await VoizSearch.archivedResults(query: "text", meetings: [], dictationPage: { _ in throw SyntheticFailure.unreadable }, translationPage: { _ in [] })
            Issue.record("Unreadable archive appeared complete")
        } catch SyntheticFailure.unreadable { }
    }

    @Test func openingOldDictationPinsOneEntryWithoutResurrectingHiddenRows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Voiz-Search-" + UUID().uuidString)
        let suite = "Voiz.Search.Tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite")
        let archive = try TextHistoryArchive<TranscriptionEntry>(databaseURL: url, kind: "dictation")
        let oldest = TranscriptionEntry(text: "Old searchable dictation", language: .english, timestamp: Date(timeIntervalSince1970: 1))
        try archive.upsert(oldest, timestamp: oldest.timestamp)
        for n in 0..<120 {
            let entry = TranscriptionEntry(text: "Recent \(n)", language: .english, timestamp: Date(timeIntervalSince1970: Double(100 + n)))
            try archive.upsert(entry, timestamp: entry.timestamp)
        }
        let store = TranscriptionHistoryStore(defaults: defaults, audioStore: DictationAudioStore(directory: directory.appendingPathComponent("Audio")), archiveURL: url)
        #expect(store.entries.count == 100)
        #expect(store.revealEntry(id: oldest.id))
        #expect(store.entries.count == 101)
        #expect(store.entries.first?.id == oldest.id)
        try archive.setHidden(id: oldest.id, true)
        #expect(!store.revealEntry(id: oldest.id))
        #expect(store.visibleEntry(id: oldest.id) == nil)
        #expect(!store.entries.contains { $0.id == oldest.id })
        #expect(try archive.entry(id: oldest.id)?.text == oldest.text)
    }
}
