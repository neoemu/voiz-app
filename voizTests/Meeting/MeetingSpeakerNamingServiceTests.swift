import Foundation
import Testing

@Suite("Serviço de identificação de nomes dos falantes")
struct MeetingSpeakerNamingServiceTests {
    @Test("Prompt inclui timestamps, âncora do usuário, lista esperada, pistas de voz e regras de homônimos")
    func buildsRichPromptWithContext() throws {
        let session = MeetingSession(
            title: "Daily Time Produto",
            notes: "Pauta privada não autorizada",
            includeNotesInSummary: false,
            speakers: [
                MeetingSpeaker(source: .microphone),
                MeetingSpeaker(id: "S1", source: .systemAudio, name: "Participante 1"),
                MeetingSpeaker(id: "S2", source: .systemAudio, name: "Participante 2")
            ],
            turns: [
                MeetingTurn(source: .microphone, speakerId: "microphone", speakerName: "Você", text: "Pode falar aí, Carlos.", startTime: 5, endTime: 9),
                MeetingTurn(source: .systemAudio, speakerId: "S1", speakerName: "Participante 1", text: "Bom dia pessoal.", startTime: 10, endTime: 14),
                MeetingTurn(source: .systemAudio, speakerId: "S2", speakerName: "Participante 2", text: "Ontem terminei os testes.", startTime: 65, endTime: 72)
            ]
        )

        let context = MeetingParticipantContext(
            userDisplayName: "Marina Rocha",
            meetingTitle: "Daily Time Produto",
            expectedParticipants: ["Carlos Almeida", "Carlos Souza", "Ana Silva"],
            knownPeopleFromHistory: ["Bruno Costa"],
            voiceReport: MeetingVoiceMatchReport(
                strongMatches: [:],
                hintsBySpeakerID: [
                    "S1": [MeetingVoiceHint(name: "Carlos Almeida", similarity: 0.87, isStrong: true, sampleCount: 4)]
                ]
            ),
            notesForNaming: nil
        )

        let built = try #require(MeetingSpeakerNamingService.buildPrompt(session: session, context: context))
        #expect(built.eligibleIDs == Set(["S1", "S2"]))
        #expect(built.prompt.contains("[00:05-00:09] [microphone] Você (Marina Rocha): Pode falar aí, Carlos."))
        #expect(built.prompt.contains("[01:05-01:12] [S2] Participante 2: Ontem terminei os testes."))
        #expect(built.prompt.contains("Carlos Almeida"))
        #expect(built.prompt.contains("Carlos Souza"))
        #expect(built.prompt.contains("Bruno Costa"))
        #expect(built.prompt.contains("similaridade 0.87, forte"))
        #expect(built.prompt.contains("HOMÔNIMOS"))
        #expect(!built.prompt.contains("Pauta privada não autorizada"))
    }

    @Test("Não monta prompt quando não há falantes remotos identificados")
    func skipsPromptWithoutEligibleRemoteSpeakers() {
        let session = MeetingSession(
            speakers: [
                MeetingSpeaker(source: .microphone),
                MeetingSpeaker(source: .systemAudio)
            ],
            turns: [
                MeetingTurn(source: .microphone, speakerId: "microphone", speakerName: "Você", text: "Olá", startTime: 0, endTime: 2)
            ]
        )
        #expect(MeetingSpeakerNamingService.buildPrompt(session: session, context: .empty) == nil)
    }

    @Test("Parser aceita JSON estruturado, formato legado, prosa em volta e descarta baixa confiança e rótulos genéricos")
    func parsesStructuredLegacyAndProseWrappedResponses() {
        let known: Set<String> = ["S1", "S2", "S3", "S4"]

        let structuredResponse = """
        Claro, segue a análise dos falantes:
        ```json
        {
          "S1": {"name": "Ana Silva", "confidence": "high", "reason": "chamada pelo nome"},
          "S2": {"name": "Carlos Almeida", "confidence": "medium", "reason": "pista de voz"},
          "S3": {"name": "Bruno Costa", "confidence": "low", "reason": "incerto"},
          "S4": {"name": "Participante 4", "confidence": "high", "reason": "genérico"},
          "microphone": {"name": "Marina Rocha", "confidence": "high", "reason": "fora da allowlist"}
        }
        ```
        Espero que ajude!
        """

        let parsed = MeetingSpeakerNamingService.parseSuggestions(from: structuredResponse, knownLabels: known)
        #expect(parsed.count == 2)
        #expect(parsed["S1"] == MeetingSpeakerNameSuggestion(name: "Ana Silva", confidence: .high, reason: "chamada pelo nome"))
        #expect(parsed["S2"] == MeetingSpeakerNameSuggestion(name: "Carlos Almeida", confidence: .medium, reason: "pista de voz"))
        #expect(parsed["S3"] == nil)
        #expect(parsed["S4"] == nil)
        #expect(parsed["microphone"] == nil)

        let legacyFlatResponse = #"{"S1": "Ana Silva", "S2": "Outros na chamada"}"#
        let legacyParsed = MeetingSpeakerNamingService.parseSuggestions(from: legacyFlatResponse, knownLabels: known)
        #expect(legacyParsed.count == 1)
        #expect(legacyParsed["S1"] == MeetingSpeakerNameSuggestion(name: "Ana Silva", confidence: .medium, reason: nil))
    }
}
