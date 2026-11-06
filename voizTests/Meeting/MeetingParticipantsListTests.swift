import Foundation
import Testing

@Suite("Reunião — lista de participantes sem o resto de áudio sem dono")
struct MeetingParticipantsListTests {
    private static let unassigned = MeetingCaptureSource.systemAudio.rawValue

    private static func turn(_ source: MeetingCaptureSource, _ speakerId: String, _ start: TimeInterval,
                             _ end: TimeInterval) -> MeetingTurn {
        var turn = MeetingTurn(source: source, speakerName: speakerId, text: "fala", startTime: start, endTime: end)
        turn.speakerId = speakerId
        return turn
    }

    /// Você 30 s, Participante 1 com `identified` s, o áudio sem dono com `leftover` s.
    private static func session(identified: TimeInterval, leftover: TimeInterval) -> MeetingSession {
        var session = MeetingSession(title: "Reunião", sessionType: .meeting, startedAt: Date(), turns: [])
        session.speakers = [
            MeetingSpeaker(source: .microphone),
            MeetingSpeaker(source: .systemAudio),
        ]
        session.turns = [turn(.microphone, MeetingCaptureSource.microphone.rawValue, 0, 30)]
        if identified > 0 {
            session.speakers.append(MeetingSpeaker(id: "S1", source: .systemAudio, name: "Participante 1"))
            session.turns.append(turn(.systemAudio, "S1", 30, 30 + identified))
        }
        session.turns.append(turn(.systemAudio, unassigned, 100, 100 + leftover))
        return session
    }

    @Test("Resto de 2 s ao lado de participantes identificados sai da lista")
    func smallLeftoverIsHidden() {
        let session = Self.session(identified: 28, leftover: 2)   // 2 de 60 s = 3%
        #expect(!session.participantsListSpeakers.contains { $0.id == Self.unassigned })
        #expect(session.participantsListSpeakers.contains { $0.id == "S1" })
        // O tempo de fala continua com todo mundo.
        #expect(session.talkTimeStats.contains { $0.speakerId == Self.unassigned })
    }

    @Test("Resto com 5% ou mais continua na lista")
    func relevantLeftoverIsKept() {
        let session = Self.session(identified: 20, leftover: 10)  // 10 de 60 s = 17%
        #expect(session.participantsListSpeakers.contains { $0.id == Self.unassigned })
    }

    @Test("Sem participantes identificados, o áudio da chamada é o participante e fica")
    func withoutDiarizationLeftoverStays() {
        let session = Self.session(identified: 0, leftover: 1)
        #expect(session.participantsListSpeakers.contains { $0.id == Self.unassigned })
    }
}
