import Foundation
import Testing

@Suite("Meeting speaker identity and orphaned speech")
struct MeetingSpeakerIdentityTests {
    private func turn(_ id: String?, _ name: String, source: MeetingCaptureSource = .systemAudio,
                      start: Double = 0, duration: Double = 10) -> MeetingTurn {
        MeetingTurn(source: source, speakerId: id, speakerName: name, text: "Synthetic speech",
                    startTime: start, endTime: start + duration)
    }

    @Test("Existing English recording recovers missing Participants without reprocessing")
    func orphanedEnglishSpeech() throws {
        let original = MeetingSession(speakers: [
            MeetingSpeaker(source: .microphone, name: "Rodrigo"),
            MeetingSpeaker(id: "S1", source: .systemAudio, name: "João")
        ], turns: [turn("S1", "João"), turn(nil, "Participants", duration: 189.5)])
        var session = try JSONDecoder().decode(MeetingSession.self, from: JSONEncoder().encode(original))
        session.reconcileSpeakers()
        let recovered = try #require(session.speakers.first { $0.name == "Participants" })
        #expect(session.speakers.count == 3)
        #expect(session.turns.map(\.text) == original.turns.map(\.text))
        #expect(session.talkTimeStats.first?.duration == 189.5)
        #expect(session.talkTimeStats.first?.speakerId == recovered.id)
        let reconciled = session
        session.reconcileSpeakers()
        #expect(session == reconciled)
        session.renameSpeaker(id: recovered.id, to: "João Silva")
        #expect(session.turns.map(\.speakerName) == ["João", "João Silva"])
        #expect(session.turns[1].speakerId == recovered.id)
        #expect(try JSONDecoder().decode(MeetingSession.self, from: JSONEncoder().encode(session)) == session)
    }

    @Test("Two Joãos and two Matheus retain separate time and rename targets")
    func duplicateNames() {
        let names = ["João", "João", "Matheus", "Matheus"]
        var session = MeetingSession(speakers: names.enumerated().map {
            MeetingSpeaker(id: "S\($0.offset)", source: .systemAudio, name: $0.element)
        }, turns: names.enumerated().map {
            turn("S\($0.offset)", $0.element, duration: Double($0.offset + 1) * 10)
        })
        let stats = session.talkTimeStats
        #expect(stats.count == 4)
        #expect(Set(stats.map(\.id)).count == 4)
        #expect(stats.map(\.duration) == [40, 30, 20, 10])
        #expect(abs(stats.reduce(0) { $0 + $1.fraction } - 1) < 0.00001)
        session.renameSpeaker(id: "S1", to: "João Silva")
        #expect(session.turns.map(\.speakerName) == ["João", "João Silva", "Matheus", "Matheus"])
        #expect(session.talkTimeStats.map(\.id) == stats.map(\.id))
    }

    @Test("Legacy names never assign ambiguous speech or cross capture sources")
    func legacyAmbiguity() {
        var session = MeetingSession(speakers: [
            MeetingSpeaker(source: .microphone, name: "João"),
            MeetingSpeaker(id: "S1", source: .systemAudio, name: "João"),
            MeetingSpeaker(id: "S2", source: .systemAudio, name: "João")
        ], turns: [turn(nil, "João", source: .microphone), turn(nil, "João"), turn("S1", "João")])
        session.renameSpeaker(id: "S1", to: "João Silva")
        #expect(session.turns.map(\.speakerName) == ["João", "João", "João Silva"])
        #expect(session.turns[0].speakerId == "microphone")
        #expect(session.turns[1].speakerId?.hasPrefix("unidentified:") == true)
    }

    @Test("AI names apply simultaneously by ID even for swaps and duplicate names")
    func nameSwaps() {
        var session = MeetingSession(speakers: [
            MeetingSpeaker(id: "S1", source: .systemAudio, name: "João"),
            MeetingSpeaker(id: "S2", source: .systemAudio, name: "Matheus")
        ], turns: [turn("S1", "João"), turn("S2", "Matheus")])
        session.applySpeakerNames(["S1": "Matheus", "S2": "João"])
        #expect(session.turns.map(\.speakerName) == ["Matheus", "João"])
        session.applySpeakerNames(["S1": "João", "S2": "João"])
        #expect(session.talkTimeStats.count == 2)
    }

    @Test("Partial diarization includes unassigned speech and clears obsolete identity")
    func partialDiarization() {
        var session = MeetingSession(turns: [turn(nil, "Participants"), turn("old", "Old name", start: 20)])
        session.applyDiarization(segments: [
            DiarizedSegment(speakerId: "S1", start: 0, end: 10, embedding: []),
            DiarizedSegment(speakerId: DiarizedSegment.unassignedSpeakerId, start: 20, end: 30, embedding: [])
        ])
        #expect(session.turns.map(\.speakerId) == ["S1", "systemAudio"])
        #expect(session.speakers.contains { $0.id == "systemAudio" })
        #expect(!session.speakers.contains { $0.id == "old" })
        #expect(session.talkTimeStats.count == 2)
        session.applyDiarization(segments: [DiarizedSegment(speakerId: "S1", start: 0, end: 30, embedding: [])])
        #expect(!session.speakers.contains { $0.id == "systemAudio" })
    }

    @Test("Empty or entirely unassigned diarization preserves existing identities")
    func unavailableDiarization() {
        var session = MeetingSession(turns: [turn(nil, "Participants")])
        session.applyDiarization(segments: [])
        #expect(session.speakers.contains { $0.name == "Participants" })
        let before = session
        session.applyDiarization(segments: [
            DiarizedSegment(speakerId: DiarizedSegment.unassignedSpeakerId, start: 0, end: 10, embedding: [])
        ])
        #expect(session == before)
    }
}
