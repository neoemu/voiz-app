import Foundation
import Testing

@Suite("Memória local de participantes e perfis de voz")
struct MeetingParticipantMemoryTests {
    private func makeEmbedding(angle: Float, dimensions: Int = 256) -> [Float] {
        var vector = [Float](repeating: 0, count: dimensions)
        vector[0] = cos(angle)
        vector[1] = sin(angle)
        return vector
    }

    private func makeTurn(
        speakerID: String,
        name: String,
        source: MeetingCaptureSource = .systemAudio,
        start: TimeInterval = 0,
        duration: TimeInterval = 30
    ) -> MeetingTurn {
        MeetingTurn(
            source: source,
            speakerId: speakerID,
            speakerName: name,
            text: "Fala sintética de teste.",
            startTime: start,
            endTime: start + duration
        )
    }

    @Test("Limpa lista colada do Teams e Outlook removendo status, papéis, iniciais e emails")
    func parsesTeamsAndOutlookCopyPaste() {
        let raw = """
        Aceito: 3
        A
        Ana Silva
        Obrigatória
        C
        Carlos Almeida
        Obrigatória
        Carlos Souza <carlos.souza@example.com>
        Seguindo: 1 ⓘ
        Bruno Costa (Opcional)
        Não respondeu: 1
        Marina Rocha - Organizador
        Participante 1
        outro@example.com
        - Ana Silva
        """

        let parsed = MeetingParticipantMemory.parseExpectedParticipants(from: raw)
        #expect(parsed == [
            "Ana Silva",
            "Carlos Almeida",
            "Carlos Souza",
            "Bruno Costa",
            "Marina Rocha"
        ])
    }

    @Test("Rótulos genéricos nunca entram como pessoas conhecidas ou sugestões")
    func filtersGenericLabels() {
        for label in ["", "Você", "You", "Outros na chamada", "Participante 1", "Participant 2", "S1", "S12", "speaker_0"] {
            #expect(MeetingParticipantMemory.isGenericSpeakerLabel(label))
        }
        #expect(!MeetingParticipantMemory.isGenericSpeakerLabel("Ana Silva"))
        #expect(!MeetingParticipantMemory.isGenericSpeakerLabel("Carlos Souza"))
    }

    @Test("Constrói perfis de voz ponderados e separa homônimos por assinatura vocal")
    func buildsVoiceProfilesAndSeparatesHomonyms() {
        let pastSession = MeetingSession(
            title: "Daily Time",
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            speakers: [
                MeetingSpeaker(source: .microphone),
                MeetingSpeaker(id: "S1", source: .systemAudio, name: "Carlos Almeida", embedding: makeEmbedding(angle: 0.0)),
                MeetingSpeaker(id: "S2", source: .systemAudio, name: "Carlos Souza", embedding: makeEmbedding(angle: .pi / 2)),
                MeetingSpeaker(id: "S3", source: .systemAudio, name: "Participante 3", embedding: makeEmbedding(angle: .pi))
            ],
            turns: [
                makeTurn(speakerID: "S1", name: "Carlos Almeida", start: 0, duration: 40),
                makeTurn(speakerID: "S2", name: "Carlos Souza", start: 45, duration: 35)
            ]
        )

        let profiles = MeetingParticipantMemory.buildVoiceProfiles(from: [pastSession])
        #expect(profiles.count == 2)
        #expect(Set(profiles.map(\.name)) == ["Carlos Almeida", "Carlos Souza"])

        let currentSpeakers = [
            MeetingSpeaker(source: .microphone),
            MeetingSpeaker(id: "S1", source: .systemAudio, name: "Participante 1", embedding: makeEmbedding(angle: 0.05)),
            MeetingSpeaker(id: "S2", source: .systemAudio, name: "Participante 2", embedding: makeEmbedding(angle: (.pi / 2) - 0.04))
        ]
        let report = MeetingParticipantMemory.matchSpeakers(
            currentSpeakers,
            against: profiles,
            expectedParticipants: ["Carlos Almeida", "Carlos Souza"]
        )

        #expect(report.strongMatches["S1"]?.name == "Carlos Almeida")
        #expect(report.strongMatches["S2"]?.name == "Carlos Souza")
    }

    @Test("Rejeita vínculo forte quando dois perfis estão próximos (margem de ambiguidade < 0,05)")
    func rejectsAmbiguousVoiceMatch() {
        let history = MeetingSession(
            title: "Alinhamento",
            speakers: [
                MeetingSpeaker(id: "S1", source: .systemAudio, name: "Ana Silva", embedding: makeEmbedding(angle: 0.0)),
                MeetingSpeaker(id: "S2", source: .systemAudio, name: "Bruno Costa", embedding: makeEmbedding(angle: 0.35))
            ],
            turns: [
                makeTurn(speakerID: "S1", name: "Ana Silva", duration: 30),
                makeTurn(speakerID: "S2", name: "Bruno Costa", start: 40, duration: 30)
            ]
        )
        let profiles = MeetingParticipantMemory.buildVoiceProfiles(from: [history])
        // Ângulo exatamente no meio -> diferença de similaridade zero entre Ana e Bruno.
        let ambiguousSpeaker = MeetingSpeaker(
            id: "S1",
            source: .systemAudio,
            name: "Participante 1",
            embedding: makeEmbedding(angle: 0.175)
        )

        let report = MeetingParticipantMemory.matchSpeakers([ambiguousSpeaker], against: profiles)
        #expect(report.strongMatches["S1"] == nil)
        #expect((report.hintsBySpeakerID["S1"]?.count ?? 0) == 2)
    }

    @Test("Prioriza pessoas da mesma pasta, títulos parecidos e sessões importadas no histórico")
    func ranksKnownPeopleByFolderAndTitleAndBuildsRenameSuggestions() {
        let dailyFolder = MeetingFolder(
            name: "Daily",
            expectedParticipants: ["Marina Rocha"]
        )
        let otherFolder = MeetingFolder(name: "Outros")

        let dailySession = MeetingSession(
            title: "Daily Time Produto",
            startedAt: Date(timeIntervalSince1970: 1_800_050_000),
            speakers: [
                MeetingSpeaker(id: "granola-1", source: .systemAudio, name: "Ana Silva", embedding: makeEmbedding(angle: 0.1)),
                MeetingSpeaker(id: "granola-2", source: .systemAudio, name: "Bruno Costa")
            ],
            turns: [makeTurn(speakerID: "granola-1", name: "Ana Silva")],
            folderId: dailyFolder.id
        )
        let unrelatedSession = MeetingSession(
            title: "Financeiro Q4",
            startedAt: Date(timeIntervalSince1970: 1_800_040_000),
            speakers: [MeetingSpeaker(id: "S1", source: .systemAudio, name: "Lucas Ferreira")],
            folderId: otherFolder.id
        )
        let current = MeetingSession(
            title: "Daily Time Produto",
            startedAt: Date(timeIntervalSince1970: 1_800_100_000),
            speakers: [
                MeetingSpeaker(source: .microphone),
                MeetingSpeaker(id: "S1", source: .systemAudio, name: "Participante 1", embedding: makeEmbedding(angle: 0.11)),
                MeetingSpeaker(id: "S2", source: .systemAudio, name: "Ana Silva")
            ],
            folderId: dailyFolder.id,
            expectedParticipants: ["Carlos Almeida"]
        )

        let people = MeetingParticipantMemory.knownPeople(
            from: [dailySession, unrelatedSession, current],
            folders: [dailyFolder, otherFolder],
            excluding: current.id,
            preferredFolderID: dailyFolder.id,
            referenceTitle: current.title
        )
        #expect(people.first(where: { $0.name == "Ana Silva" })?.hasVoiceProfile == true)
        #expect(people.contains { $0.name == "Marina Rocha" })
        let anaIndex = people.firstIndex { $0.name == "Ana Silva" } ?? .max
        let lucasIndex = people.firstIndex { $0.name == "Lucas Ferreira" } ?? .max
        #expect(anaIndex < lucasIndex)

        let suggestions = MeetingParticipantMemory.suggestedRenameNames(
            for: current.speakers[1],
            in: current,
            allSessions: [dailySession, unrelatedSession, current],
            folders: [dailyFolder, otherFolder],
            userDisplayName: "Lucas Ferreira"
        )
        #expect(!suggestions.contains("Ana Silva"))
        #expect(!suggestions.contains("Lucas Ferreira"))
        #expect(suggestions.contains("Carlos Almeida"))
        #expect(suggestions.contains("Marina Rocha"))
    }

    @Test("resolveFinalNames combina LLM com voz forte, completa sobrenome e protege nome do usuário")
    func resolvesFinalNamesSafely() {
        let speakers = [
            MeetingSpeaker(source: .microphone),
            MeetingSpeaker(id: "S1", source: .systemAudio, name: "Participante 1"),
            MeetingSpeaker(id: "S2", source: .systemAudio, name: "Participante 2"),
            MeetingSpeaker(id: "S3", source: .systemAudio, name: "Participante 3"),
            MeetingSpeaker(id: "S4", source: .systemAudio, name: "Participante 4")
        ]
        let voiceReport = MeetingVoiceMatchReport(
            strongMatches: [
                "S1": MeetingVoiceHint(name: "Carlos Almeida", similarity: 0.91, isStrong: true, sampleCount: 3),
                "S3": MeetingVoiceHint(name: "Marina Rocha", similarity: 0.89, isStrong: true, sampleCount: 2),
                "S4": MeetingVoiceHint(name: "Lucas Ferreira", similarity: 0.90, isStrong: true, sampleCount: 1)
            ],
            hintsBySpeakerID: [:]
        )
        let llmSuggestions: [String: MeetingSpeakerNameSuggestion] = [
            "S1": MeetingSpeakerNameSuggestion(name: "Carlos", confidence: .medium, reason: "chamado de Carlos"),
            "S2": MeetingSpeakerNameSuggestion(name: "Bruno Costa", confidence: .high, reason: "auto-apresentação"),
            "S4": MeetingSpeakerNameSuggestion(name: "Ana Silva", confidence: .high, reason: "confirmada na conversa")
        ]

        let resolved = MeetingParticipantMemory.resolveFinalNames(
            llmSuggestions: llmSuggestions,
            voiceReport: voiceReport,
            speakers: speakers,
            userDisplayName: "Marina Rocha"
        )

        // S1: primeiro nome médio é completado pelo perfil de voz forte.
        #expect(resolved["S1"] == "Carlos Almeida")
        // S2: alta confiança do LLM sem voz entra normalmente.
        #expect(resolved["S2"] == "Bruno Costa")
        // S3: nome do usuário no microfone nunca vai para falante remoto S*.
        #expect(resolved["S3"] == nil)
        // S4: alta confiança do LLM prevalece mesmo havendo outra pista de voz.
        #expect(resolved["S4"] == "Ana Silva")
    }

    @Test("Decodifica sessões e pastas antigas sem expectedParticipants")
    func decodesLegacySessionsAndFoldersWithoutExpectedParticipants() throws {
        let legacySessionJSON = Data("""
        {
          "id": "11111111-1111-4111-8111-111111111111",
          "title": "Reunião antiga",
          "sessionType": "meeting",
          "startedAt": "2026-01-01T10:00:00Z",
          "notes": "",
          "speakers": [],
          "turns": [],
          "audioFiles": []
        }
        """.utf8)
        let legacyFolderJSON = Data("""
        {
          "id": "22222222-2222-4222-8222-222222222222",
          "name": "Pasta antiga",
          "details": "",
          "createdAt": "2026-01-01T10:00:00Z"
        }
        """.utf8)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(MeetingSession.self, from: legacySessionJSON)
        let folder = try decoder.decode(MeetingFolder.self, from: legacyFolderJSON)

        #expect(session.expectedParticipants == nil)
        #expect(folder.expectedParticipants == nil)
    }

    @Test("Preserva lista explicitamente vazia de evento sem cair no fallback")
    func preservesExplicitEmptyExpectedParticipantsOverFallback() {
        var fallbackCalled = false
        let explicitEmpty = MeetingParticipantMemory.resolveInitialExpectedParticipants(
            explicit: [],
            fallback: {
                fallbackCalled = true
                return ["Ana Silva"]
            }
        )
        #expect(explicitEmpty == nil)
        #expect(fallbackCalled == false)

        let fromFallback = MeetingParticipantMemory.resolveInitialExpectedParticipants(
            explicit: nil,
            fallback: {
                fallbackCalled = true
                return ["Ana Silva", "Participante 1"]
            }
        )
        #expect(fallbackCalled == true)
        #expect(fromFallback == ["Ana Silva"])

        var fallbackCalledForExplicitNames = false
        let explicitNames = MeetingParticipantMemory.resolveInitialExpectedParticipants(
            explicit: ["Bruno Costa"],
            fallback: {
                fallbackCalledForExplicitNames = true
                return ["Ana Silva"]
            }
        )
        #expect(explicitNames == ["Bruno Costa"])
        #expect(fallbackCalledForExplicitNames == false)
    }
}
