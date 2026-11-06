import Foundation
import Testing

@Suite("MCP local — contrato read-only de reuniões")
struct MCPProtocolHandlerTests {
    private let completedID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let processingID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let folderID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

    @Test("Handshake negocia versão suportada e anuncia apenas tools")
    func initialize() throws {
        let response = try call(
            method: "initialize",
            params: [
                "protocolVersion": "2025-11-25",
                "capabilities": [:],
                "clientInfo": ["name": "tests", "version": "1"]
            ]
        )

        let result = try dictionary(response["result"])
        #expect(result["protocolVersion"] as? String == "2025-11-25")
        #expect(dictionaryOrNil(result["capabilities"])?["tools"] != nil)
        #expect((result["instructions"] as? String)?.contains("never exposes dictations") == true)
    }

    @Test("tools/list expõe busca, detalhe e transcript paginado — nada de ditado")
    func toolCatalog() throws {
        let response = try call(method: "tools/list")
        let result = try dictionary(response["result"])
        let tools = try array(result["tools"]).map { try dictionary($0) }
        let names = tools.compactMap { $0["name"] as? String }

        #expect(names == ["search_meetings", "get_meeting", "get_meeting_transcript"])
        #expect(names.allSatisfy { !$0.localizedCaseInsensitiveContains("dictation") })
        for tool in tools {
            let annotations = try dictionary(tool["annotations"])
            #expect(annotations["readOnlyHint"] as? Bool == true)
            #expect(annotations["destructiveHint"] as? Bool == false)
        }
    }

    @Test("Preflight não pede snapshot para handshake, ping, catálogo ou tool inválida")
    func preflightSeparatesHistoryFreeRequests() throws {
        let historyFreeRequests: [[String: Any]] = [
            [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": [
                    "protocolVersion": "2025-11-25",
                    "capabilities": [:],
                    "clientInfo": ["name": "tests", "version": "1"]
                ]
            ],
            ["jsonrpc": "2.0", "id": 2, "method": "ping"],
            ["jsonrpc": "2.0", "id": 3, "method": "tools/list"],
            [
                "jsonrpc": "2.0",
                "id": 4,
                "method": "tools/call",
                "params": ["name": "delete_everything", "arguments": [:]]
            ],
            [
                "jsonrpc": "2.0",
                "id": 5,
                "method": "tools/call",
                "params": ["name": "get_meeting", "arguments": [:]]
            ],
            [
                "jsonrpc": "2.0",
                "id": 6,
                "method": "tools/call",
                "params": ["name": "search_meetings", "arguments": ["limit": 0]]
            ],
            [
                "jsonrpc": "2.0",
                "id": 7,
                "method": "tools/call",
                "params": [
                    "name": "get_meeting_transcript",
                    "arguments": ["meeting_id": "not-a-uuid"]
                ]
            ]
        ]

        for request in historyFreeRequests {
            let data = try JSONSerialization.data(withJSONObject: request)
            switch MCPProtocolHandler.preflight(data) {
            case .response(let response):
                #expect(response.statusCode == 200)
            case .requiresMeetingSnapshot:
                Issue.record("Request sem leitura de reuniões exigiu snapshot")
            }
        }

        let validToolCalls: [[String: Any]] = [
            ["name": "search_meetings", "arguments": [:]],
            ["name": "get_meeting", "arguments": ["meeting_id": completedID.uuidString]],
            [
                "name": "get_meeting_transcript",
                "arguments": ["meeting_id": completedID.uuidString, "limit": 1]
            ]
        ]
        for (offset, params) in validToolCalls.enumerated() {
            let toolCall = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0",
                "id": 20 + offset,
                "method": "tools/call",
                "params": params
            ])
            switch MCPProtocolHandler.preflight(toolCall) {
            case .requiresMeetingSnapshot:
                break
            case .response:
                Issue.record("Tool reconhecida e válida não solicitou snapshot")
            }
        }
    }

    @Test("Busca omite reunião em processamento e retorna somente a allowlist")
    func searchDefaultsToCompletedMeetings() throws {
        let response = try callTool(
            "search_meetings",
            arguments: ["query": "Orion", "limit": 10]
        )
        let content = try structuredContent(response)
        let meetings = try array(content["meetings"]).map { try dictionary($0) }

        #expect(meetings.count == 1)
        #expect(meetings.first?["id"] as? String == completedID.uuidString)
        #expect((meetings.first?["snippet"] as? String)?.contains("Orion") == true)
        #expect(Set(content.keys) == [
            "meetings", "offset", "returned", "total_matches", "has_more", "next_offset", "scope"
        ])
        #expect(Set(try #require(meetings.first).keys) == [
            "id", "title", "type", "started_at", "ended_at", "duration_seconds", "status",
            "has_notes", "has_summary", "transcript_turn_count", "folder", "snippet"
        ])
        #expect(Set(try dictionary(meetings.first?["folder"]).keys) == ["id", "name"])
        try expectTextAndStructuredContentMatch(response)
        try expectNoInternalSentinels(in: response)
    }

    @Test("Busca pagina deterministicamente com offset e next_offset")
    func searchPagination() throws {
        let first = try structuredContent(callTool(
            "search_meetings",
            arguments: ["include_processing": true, "limit": 1]
        ))
        let firstMeetings = try array(first["meetings"]).map { try dictionary($0) }
        #expect(firstMeetings.first?["id"] as? String == processingID.uuidString)
        #expect(first["next_offset"] as? Int == 1)

        let second = try structuredContent(callTool(
            "search_meetings",
            arguments: ["include_processing": true, "offset": 1, "limit": 1]
        ))
        let secondMeetings = try array(second["meetings"]).map { try dictionary($0) }
        #expect(secondMeetings.first?["id"] as? String == completedID.uuidString)
        #expect(second["next_offset"] is NSNull)
    }

    @Test("Detalhe leva notas, resumo e capítulos, mas não despeja o transcript")
    func meetingDetails() throws {
        let response = try callTool(
            "get_meeting",
            arguments: ["meeting_id": completedID.uuidString]
        )
        let content = try structuredContent(response)
        let summary = try dictionary(content["summary"])
        let transcript = try dictionary(content["transcript"])

        #expect(content["notes"] as? String == "Revisar o plano Orion amanhã.")
        #expect(summary["title"] as? String == "Plano Orion")
        #expect(transcript["turn_count"] as? Int == 2)
        #expect(transcript["tool"] as? String == "get_meeting_transcript")
        #expect(content["turns"] == nil)
        let talkTime = try dictionary(content["talk_time"])
        #expect(talkTime["available"] as? Bool == true)
        #expect(talkTime["is_partial"] as? Bool == false)
        let talkers = try array(talkTime["speakers"]).map { try dictionary($0) }
        #expect(talkers.count == 2)
        #expect(talkers[0]["speaker"] as? String == "Ana")
        #expect(talkers[0]["duration_seconds"] as? Double == 4)
        #expect(talkers[1]["duration_seconds"] as? Double == 3)
        #expect(abs((talkers[0]["percentage"] as? Double ?? 0) - 400.0 / 7.0) < 0.001)
        #expect(Set(content.keys) == [
            "id", "title", "type", "started_at", "ended_at", "duration_seconds", "status",
            "has_notes", "has_summary", "transcript_turn_count", "folder", "notes", "speakers",
            "chapters", "talk_time", "summary", "transcript", "data_notice"
        ])
        #expect(Set(summary.keys) == ["title", "sections"])
        let speakers = try array(content["speakers"]).map { try dictionary($0) }
        #expect(speakers.allSatisfy { Set($0.keys) == ["id", "name", "source"] })
        let chapters = try array(content["chapters"]).map { try dictionary($0) }
        #expect(chapters.allSatisfy { Set($0.keys) == ["id", "title", "start_seconds"] })
        try expectTextAndStructuredContentMatch(response)
        try expectNoInternalSentinels(in: response)
    }

    @Test("Transcript pagina por turno e fornece próximo offset")
    func transcriptPagination() throws {
        let first = try structuredContent(callTool(
            "get_meeting_transcript",
            arguments: [
                "meeting_id": completedID.uuidString,
                "offset": 0,
                "limit": 1
            ]
        ))
        let firstTurns = try array(first["turns"]).map { try dictionary($0) }
        #expect(firstTurns.count == 1)
        #expect(firstTurns.first?["speaker"] as? String == "Ana")
        #expect(first["next_offset"] as? Int == 1)
        #expect(Set(first.keys) == [
            "meeting_id", "title", "status", "is_partial", "snapshot_id", "offset", "returned",
            "total_turns", "next_offset", "turns", "data_notice"
        ])
        #expect(Set(try #require(firstTurns.first).keys) == [
            "id", "speaker", "source", "text", "start_seconds", "end_seconds", "speaker_id"
        ])
        let snapshotID = try #require(first["snapshot_id"] as? String)

        let secondResponse = try callTool(
            "get_meeting_transcript",
            arguments: [
                "meeting_id": completedID.uuidString,
                "offset": 1,
                "limit": 1,
                "expected_snapshot_id": snapshotID
            ]
        )
        let second = try structuredContent(secondResponse)
        let secondTurns = try array(second["turns"]).map { try dictionary($0) }
        #expect(secondTurns.first?["speaker"] as? String == "Bruno")
        #expect(second["next_offset"] is NSNull)
        try expectTextAndStructuredContentMatch(secondResponse)
        try expectNoInternalSentinels(in: secondResponse)

        let stale = try callTool(
            "get_meeting_transcript",
            arguments: [
                "meeting_id": completedID.uuidString,
                "offset": 1,
                "expected_snapshot_id": "stale-snapshot"
            ]
        )
        #expect(try dictionary(stale["result"])["isError"] as? Bool == true)
    }

    @Test("Argumentos inválidos falham fechados em vez de ampliar consultas")
    func invalidToolArgumentsFailClosed() throws {
        let invalidSearchArguments: [[String: Any]] = [
            ["folder_id": "not-a-uuid"],
            ["from": "tomorrow"],
            ["from": "2030-01-02T00:00:00Z", "to": "2030-01-01T00:00:00Z"],
            ["limit": true],
            ["limit": 1.5],
            ["limit": 0],
            ["include_processing": 1],
            ["unexpected": true]
        ]

        for arguments in invalidSearchArguments {
            let response = try callTool("search_meetings", arguments: arguments)
            #expect(try dictionary(response["result"])["isError"] as? Bool == true)
        }

        let invalidMeeting = try callTool("get_meeting", arguments: ["meeting_id": "short"])
        #expect(try dictionary(invalidMeeting["result"])["isError"] as? Bool == true)

        let nonObject = try call(
            method: "tools/call",
            params: ["name": "search_meetings", "arguments": "not-an-object"]
        )
        #expect(try dictionary(nonObject["result"])["isError"] as? Bool == true)
    }

    @Test("Transcript parcial exige opt-in explícito")
    func partialTranscriptRequiresOptIn() throws {
        let denied = try callTool(
            "get_meeting_transcript",
            arguments: ["meeting_id": processingID.uuidString]
        )
        let deniedResult = try dictionary(denied["result"])
        #expect(deniedResult["isError"] as? Bool == true)

        let allowed = try structuredContent(callTool(
            "get_meeting_transcript",
            arguments: [
                "meeting_id": processingID.uuidString,
                "allow_partial": true
            ]
        ))
        #expect(allowed["is_partial"] as? Bool == true)
        #expect(allowed["status"] as? String == "processing")
    }

    @Test("JSON inválido devolve Parse error; notificação devolve 202 sem body")
    func protocolErrorsAndNotifications() throws {
        let handler = makeHandler()
        let parseError = handler.handle(Data("{".utf8))
        let object = try responseObject(parseError)
        let error = try dictionary(object["error"])
        #expect(error["code"] as? Int == -32700)

        let notification = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "method": "notifications/initialized"
        ])
        let accepted = handler.handle(notification)
        #expect(accepted.statusCode == 202)
        #expect(accepted.body == nil)

        let serverResponse = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 99,
            "result": [:]
        ])
        let acceptedResponse = handler.handle(serverResponse)
        #expect(acceptedResponse.statusCode == 202)
        #expect(acceptedResponse.body == nil)
    }

    @Test("Initialize, request id e tool desconhecida são validados no protocolo")
    func strictProtocolValidation() throws {
        let missingInitializeFields = try call(
            method: "initialize",
            params: ["protocolVersion": "2025-11-25"]
        )
        #expect(try dictionary(missingInitializeFields["error"])["code"] as? Int == -32602)

        let unknownTool = try call(
            method: "tools/call",
            params: ["name": "delete_everything", "arguments": [:]]
        )
        #expect(try dictionary(unknownTool["error"])["code"] as? Int == -32602)

        let invalidIDData = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": true,
            "method": "ping"
        ])
        let invalidID = try responseObject(makeHandler().handle(invalidIDData))
        #expect(try dictionary(invalidID["error"])["code"] as? Int == -32600)
    }

    @Test("Resposta acima de 2 MiB vira erro JSON-RPC compacto e preserva o id")
    func oversizedResponseIsBounded() throws {
        let largeMeeting = MeetingSession(
            id: completedID,
            title: "Reunião grande",
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            endedAt: Date(timeIntervalSince1970: 1_800_000_100),
            notes: String(repeating: "x", count: 1_100_000),
            isProcessingCompleted: true
        )
        let handler = MCPProtocolHandler(
            snapshot: MCPMeetingSnapshot(sessions: [largeMeeting], folders: [])
        )
        let requestID = 4_242
        let request = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": requestID,
            "method": "tools/call",
            "params": [
                "name": "get_meeting",
                "arguments": ["meeting_id": completedID.uuidString]
            ]
        ])

        let response = handler.handle(request)
        let body = try #require(response.body)
        #expect(response.statusCode == 200)
        #expect(body.count <= MCPProtocolHandler.maximumResponseBytes)
        #expect(body.count < 256)

        let object = try dictionary(JSONSerialization.jsonObject(with: body))
        let error = try dictionary(object["error"])
        #expect(object["id"] as? Int == requestID)
        #expect(object["result"] == nil)
        #expect(error["code"] as? Int == -32603)
        #expect(error["message"] as? String == "Response too large")
    }

    @Test("Snapshot em allowlist pode ser processado fora do MainActor")
    func snapshotIsSendableToUtilityWork() async throws {
        let handler = makeHandler()
        let request = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 77,
            "method": "tools/call",
            "params": [
                "name": "search_meetings",
                "arguments": ["query": "Orion"]
            ]
        ])

        let response = await Task.detached(priority: .utility) {
            handler.handle(request)
        }.value
        let object = try responseObject(response)
        let result = try dictionary(object["result"])
        #expect(result["isError"] as? Bool == false)
        try expectNoInternalSentinels(in: object)
    }

    @Test("Captura cooperativa aborta quando a geração do store é invalidada")
    func cooperativeSnapshotCaptureStopsAfterInvalidation() async {
        let session = MeetingSession(
            id: completedID,
            title: "Snapshot antigo",
            endedAt: Date(),
            isProcessingCompleted: true
        )
        do {
            _ = try await MCPMeetingSnapshot.capture(
                sessions: [session],
                folders: [],
                isCurrent: { false }
            )
            Issue.record("Captura invalidada retornou um snapshot parcial")
        } catch is CancellationError {
            // Esperado: nenhum snapshot parcial é publicado/cacheado.
        } catch {
            Issue.record("Erro inesperado: \(error)")
        }
    }

    // MARK: - Fixtures

    private func makeHandler() -> MCPProtocolHandler {
        let completed = MeetingSession(
            id: completedID,
            title: "Planejamento semanal",
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            endedAt: Date(timeIntervalSince1970: 1_800_003_600),
            notes: "Revisar o plano Orion amanhã.",
            speakers: [
                MeetingSpeaker(id: "ana", source: .microphone, name: "Ana", embedding: [0.987_654]),
                MeetingSpeaker(id: "bruno", source: .systemAudio, name: "Bruno")
            ],
            turns: [
                MeetingTurn(
                    id: UUID(uuidString: "AAAAAAA1-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!,
                    source: .microphone,
                    speakerId: "ana",
                    speakerName: "Ana",
                    text: "Vamos revisar o plano Orion.",
                    startTime: 0,
                    endTime: 4,
                    confidence: 0.876_543
                ),
                MeetingTurn(
                    id: UUID(uuidString: "BBBBBBB2-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!,
                    source: .systemAudio,
                    speakerId: "bruno",
                    speakerName: "Bruno",
                    text: "Combinado para amanhã.",
                    startTime: 5,
                    endTime: 8
                )
            ],
            summary: MeetingSummary(
                title: "Plano Orion",
                sections: [
                    .paragraph(id: "overview", title: "Resumo", text: "Revisão do plano Orion."),
                    .actions(
                        id: "actions",
                        title: "Ações",
                        items: [MeetingActionItem(text: "Revisar plano", assignee: "Ana")]
                    )
                ]
            ),
            audioFiles: [.microphone: "/private/VOIZ_INTERNAL_AUDIO_SENTINEL.caf"],
            systemAudioWarning: "VOIZ_INTERNAL_WARNING_SENTINEL",
            summaryError: "VOIZ_INTERNAL_SUMMARY_ERROR_SENTINEL",
            templateId: "VOIZ_INTERNAL_TEMPLATE_SENTINEL",
            chapters: [MeetingChapter(title: "Planejamento", startTime: 0)],
            cleanMicFile: "/private/VOIZ_INTERNAL_CLEAN_MIC_SENTINEL.caf",
            folderId: folderID,
            summaryModel: "VOIZ_INTERNAL_MODEL_SENTINEL",
            summaryEffort: "VOIZ_INTERNAL_EFFORT_SENTINEL",
            isProcessingCompleted: true
        )
        let processing = MeetingSession(
            id: processingID,
            title: "Reunião ainda processando",
            startedAt: Date(timeIntervalSince1970: 1_800_010_000),
            endedAt: Date(timeIntervalSince1970: 1_800_010_300),
            turns: [
                MeetingTurn(
                    source: .microphone,
                    speakerName: "Você",
                    text: "Trecho parcial",
                    startTime: 0,
                    endTime: 2
                )
            ],
            isProcessingCompleted: false
        )
        return MCPProtocolHandler(
            snapshot: MCPMeetingSnapshot(
                sessions: [processing, completed],
                folders: [
                    MeetingFolder(
                        id: folderID,
                        name: "Produto",
                        details: "VOIZ_INTERNAL_FOLDER_DETAILS_SENTINEL"
                    )
                ]
            )
        )
    }

    // MARK: - Request helpers

    private func call(
        method: String,
        params: [String: Any] = [:],
        id: Int = 1
    ) throws -> [String: Any] {
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        return try responseObject(makeHandler().handle(data))
    }

    private func callTool(_ name: String, arguments: [String: Any]) throws -> [String: Any] {
        try call(
            method: "tools/call",
            params: ["name": name, "arguments": arguments]
        )
    }

    private func responseObject(_ response: MCPProtocolResponse) throws -> [String: Any] {
        #expect(response.statusCode == 200)
        let body = try #require(response.body)
        return try dictionary(JSONSerialization.jsonObject(with: body))
    }

    private func structuredContent(_ response: [String: Any]) throws -> [String: Any] {
        let result = try dictionary(response["result"])
        #expect(result["isError"] as? Bool == false)
        return try dictionary(result["structuredContent"])
    }

    private func expectTextAndStructuredContentMatch(_ response: [String: Any]) throws {
        let result = try dictionary(response["result"])
        let structured = try dictionary(result["structuredContent"])
        let blocks = try array(result["content"])
        let firstBlock = try dictionary(blocks.first)
        let text = try #require(firstBlock["text"] as? String)
        let textObject = try dictionary(JSONSerialization.jsonObject(with: Data(text.utf8)))
        let structuredData = try JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys])
        let textData = try JSONSerialization.data(withJSONObject: textObject, options: [.sortedKeys])
        #expect(structuredData == textData)
    }

    private func expectNoInternalSentinels(in response: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
        let serialized = try #require(String(data: data, encoding: .utf8))
        let forbidden = [
            "VOIZ_INTERNAL_AUDIO_SENTINEL",
            "VOIZ_INTERNAL_WARNING_SENTINEL",
            "VOIZ_INTERNAL_SUMMARY_ERROR_SENTINEL",
            "VOIZ_INTERNAL_TEMPLATE_SENTINEL",
            "VOIZ_INTERNAL_CLEAN_MIC_SENTINEL",
            "VOIZ_INTERNAL_FOLDER_DETAILS_SENTINEL",
            "VOIZ_INTERNAL_MODEL_SENTINEL",
            "VOIZ_INTERNAL_EFFORT_SENTINEL",
            "0.987654",
            "0.876543"
        ]
        for sentinel in forbidden {
            #expect(!serialized.contains(sentinel))
        }
    }

    private func dictionary(_ value: Any?) throws -> [String: Any] {
        try #require(value as? [String: Any])
    }

    private func dictionaryOrNil(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private func array(_ value: Any?) throws -> [Any] {
        try #require(value as? [Any])
    }
}
