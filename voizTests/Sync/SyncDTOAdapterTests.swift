import Foundation
import Testing

@Suite("Sync safe local model adapters")
@MainActor
struct SyncDTOAdapterTests {
    @Test func meetingExportsPortableFieldsAndKeepsAudioLocalOnRestore() throws {
        var session = MeetingSession(title: "Synthetic meeting", notes: "Allowed note")
        session.audioFiles = [.microphone: "PRIVATE_AUDIO_PATH"]
        session.cleanMicFile = "PRIVATE_DERIVED_AUDIO"
        session.speakers = [MeetingSpeaker(id: "S1", source: .systemAudio, name: "Speaker", embedding: [0.12345])]
        session.systemAudioWarning = "PRIVATE_DIAGNOSTIC"
        let document = try SyncDTOAdapter.meeting(session)
        let text = String(data: try document.canonicalData(), encoding: .utf8)!
        for forbidden in ["PRIVATE_AUDIO_PATH", "PRIVATE_DERIVED_AUDIO", "PRIVATE_DIAGNOSTIC", "embedding", "0.12345"] { #expect(!text.contains(forbidden)) }
        let restored = try SyncDTOAdapter.applyingMeeting(document, to: nil)
        #expect(restored.audioFiles.isEmpty)
        #expect(restored.cleanMicFile == nil)
        #expect(restored.speakers.first?.embedding == nil)
        let merged = try SyncDTOAdapter.applyingMeeting(document, to: session)
        #expect(merged.audioFiles == session.audioFiles)
        #expect(merged.cleanMicFile == session.cleanMicFile)
        #expect(merged.speakers.first?.embedding == session.speakers.first?.embedding)
    }

    @Test func dictationAndTranslationRoundTripWithoutLocalIdentifiers() throws {
        let entry = TranscriptionEntry(text: "Synthetic dictation", language: .english, timestamp: Date(timeIntervalSince1970: 100), duration: 1.25,
                                       audioID: UUID(), rawText: "Raw", previousText: "Previous", processingMessage: "PRIVATE_PROCESSING")
        let document = try SyncDTOAdapter.dictation(entry)
        let text = String(data: try document.canonicalData(), encoding: .utf8)!
        #expect(!text.contains(entry.audioID!.uuidString))
        #expect(!text.contains("PRIVATE_PROCESSING"))
        let restored = try SyncDTOAdapter.dictationEntry(document)
        #expect(restored.text == entry.text)
        #expect(restored.rawText == entry.rawText)
        #expect(restored.audioID == nil)
        #expect(try SyncDTOAdapter.dictationEntry(document, preserving: entry).audioID == entry.audioID)
        let translation = TranslationEntry(sourceText: "Hello", translatedText: "Olá", sourceLanguage: .english, targetLanguage: .portuguese, timestamp: Date(timeIntervalSince1970: 100))
        #expect(try SyncDTOAdapter.translationEntry(SyncDTOAdapter.translation(translation)) == translation)
    }

    @Test func nestedEvidenceRetainsItemAndTurnRelationship() throws {
        let turn = MeetingTurn(source: .microphone, speakerName: "Speaker", text: "Evidence", startTime: 0, endTime: 1)
        var section = MeetingSummarySection.bullets(id: "points", title: "Points", items: ["Fact"])
        section.evidence = [MeetingSummaryEvidence(itemIndex: 0, turnIDs: [turn.id])]
        let session = MeetingSession(turns: [turn], summary: MeetingSummary(title: "Summary", sections: [section]))
        let summary = try SyncDTOAdapter.summary(session, transcriptGenerationID: UUID())
        let document = try #require(summary)
        let text = String(data: try document.canonicalData(), encoding: .utf8)!
        #expect(text.contains("\"item_index\":0"))
        #expect(text.contains(turn.id.uuidString.lowercased()))
    }

    @Test func portablePreferencesExcludeCredentialsAndEndpoints() throws {
        let settings = AppSettings.fullyCustomizedForTests
        let document = try SyncDTOAdapter.preferences(SyncPreferences(snapshot: settings), id: UUID())
        let text = String(data: try document.canonicalData(), encoding: .utf8)!
        for secret in [settings.openAIKey, settings.anthropicKey, settings.customKey, settings.customBaseURL] { #expect(!text.contains(secret)) }
    }
}
