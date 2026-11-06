import Foundation
import Testing

/// Export Notion: payloads, erros mapeados, rate limit. Sem rede real.
/// Token sentinela nunca pode aparecer em mensagem de erro nem no fonte de log.
@Suite("Notion — export BYO", .serialized)
struct NotionExportServiceTests {

    private static let token = "ntn_SECRET_TOKEN_XYZ_NEVER_LOG"
    private static let databaseID = "277c4d8e4f6b80d7a8c3f0e12b3c4d5e"
    private static let viewID = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    private static let pageURL = URL(string: "https://www.notion.so/exported-meeting")!
    private static let finalBlockMarker = "MARCADOR_BLOCO_FINAL"

    // MARK: - Destino

    @Test("URL, UUID com hífen e 32 hex viram o mesmo ID")
    func destinationNormalizesURLAndIDs() {
        let hex = Self.databaseID
        let dashed = NotionDestination.dashedID(hex)
        #expect(NotionDestination.normalizeID(hex) == hex)
        #expect(NotionDestination.normalizeID(dashed) == hex)
        #expect(
            NotionDestination.normalizeID("https://www.notion.so/acme/Daily-277c4d8e4f6b80d7a8c3f0e12b3c4d5e")
                == hex
        )
        #expect(
            NotionDestination.normalizeID(
                "https://www.notion.so/277c4d8e4f6b80d7a8c3f0e12b3c4d5e?v=abcdef"
            ) == hex
        )
        #expect(NotionDestination.normalizeID("  \(dashed)  ") == hex)
        #expect(NotionDestination.normalizeID("") == nil)
        #expect(NotionDestination.normalizeID("não é um destino") == nil)
    }

    @Test("?v= é a view: o ID sai do path, nunca da query")
    func destinationIgnoresViewQueryUUID() {
        let pathID = Self.databaseID
        let view = Self.viewID
        let dashedView = NotionDestination.dashedID(view)
        #expect(
            NotionDestination.normalizeID(
                "https://www.notion.so/acme/Daily-\(pathID)?v=\(dashedView)"
            ) == pathID
        )
        #expect(
            NotionDestination.normalizeID(
                "https://www.notion.so/\(pathID)?v=\(view)&pvs=21"
            ) == pathID
        )
        #expect(
            NotionDestination.normalizeID("https://www.notion.so/?v=\(dashedView)") == nil,
            "só a view na query não é um destino"
        )
        #expect(NotionDestination.normalizeID(dashedView) == view, "UUID nu (sem query) continua válido")
        #expect(NotionDestination.pathPortion(of: "https://x/?v=\(view)").contains(view) == false)
    }

    // MARK: - Pacote

    @Test("O pacote leva título, participantes, seções, ações e transcript")
    func pageContentIncludesMeetingPackage() throws {
        let session = Self.sampleSession()
        let title = NotionPageContent.title(for: session)
        #expect(title == "Daily de produto")

        let data = try JSONSerialization.data(
            withJSONObject: NotionPageContent.children(for: session)
        )
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("Rafa"))
        #expect(json.contains("Ana"))
        #expect(json.contains("Falamos do Notion."))
        #expect(json.contains("Exportar reunião"))
        #expect(json.contains("olá time"))
        #expect(json.contains("to_do"))
        #expect(json.contains(Self.token) == false)
    }

    // MARK: - HTTP

    @Test("Cria página numa database e devolve o URL")
    func exportCreatesDatabasePage() async throws {
        NotionAPIStub.reset()
        NotionAPIStub.handler = { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "GET", path.contains("/databases/") {
                return Self.json(
                    200,
                    [
                        "object": "database",
                        "id": NotionDestination.dashedID(Self.databaseID),
                        "properties": [
                            "Name": ["id": "title", "type": "title", "title": [:] as [String: Any]]
                        ]
                    ]
                )
            }
            if request.httpMethod == "POST", path == "/v1/pages" {
                return Self.json(
                    200,
                    [
                        "object": "page",
                        "id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                        "url": Self.pageURL.absoluteString
                    ]
                )
            }
            return Self.json(500, ["message": "unexpected"])
        }

        let result = try await Self.service().export(
            Self.sampleSession(),
            token: Self.token,
            destination: "https://www.notion.so/\(Self.databaseID)"
        )
        #expect(result.url == Self.pageURL)
        #expect(NotionAPIStub.requests.contains { $0.value(forHTTPHeaderField: "Notion-Version") == NotionExportService.apiVersion })
        #expect(NotionAPIStub.requests.contains { $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)" })

        let create = try #require(NotionAPIStub.requests.first { $0.httpMethod == "POST" })
        let body = Self.bodyJSON(create)
        #expect((body["parent"] as? [String: Any])?["database_id"] as? String
            == NotionDestination.dashedID(Self.databaseID))
        #expect((body["properties"] as? [String: Any])?["Name"] != nil)
        let children = try #require(body["children"] as? [Any])
        #expect(!children.isEmpty)
        let dumped = String(data: create.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(dumped.contains("Rafa"))
        #expect(dumped.contains(Self.token) == false)
        for request in NotionAPIStub.requests {
            Self.assertNoTokenLeak(in: request)
        }
    }

    @Test("Página pai: GET database 404 cai no GET page e cria filho")
    func exportCreatesChildOfPage() async throws {
        NotionAPIStub.reset()
        NotionAPIStub.handler = { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "GET", path.contains("/databases/") {
                return Self.json(404, ["code": "object_not_found"])
            }
            if request.httpMethod == "GET", path.contains("/pages/") {
                return Self.json(200, ["object": "page", "id": NotionDestination.dashedID(Self.databaseID)])
            }
            if request.httpMethod == "POST", path == "/v1/pages" {
                return Self.json(
                    200,
                    ["object": "page", "id": "bbbbbbbb-cccc-dddd-eeee-ffffffffffff", "url": Self.pageURL.absoluteString]
                )
            }
            return Self.json(500, [:])
        }

        let result = try await Self.service().export(
            Self.sampleSession(),
            token: Self.token,
            destination: Self.databaseID
        )
        #expect(result.url == Self.pageURL)
        let create = try #require(NotionAPIStub.requests.first { $0.httpMethod == "POST" })
        let parent = Self.bodyJSON(create)["parent"] as? [String: Any]
        #expect(parent?["page_id"] as? String == NotionDestination.dashedID(Self.databaseID))
    }

    @Test("401 vira token inválido — sem ecoar o secret")
    func unauthorizedMapsToInvalidToken() async {
        NotionAPIStub.reset()
        NotionAPIStub.handler = { _ in Self.json(401, ["message": "Invalid token \(Self.token)"]) }

        await #expect(throws: NotionExportError.invalidToken) {
            try await Self.service().export(
                Self.sampleSession(),
                token: Self.token,
                destination: Self.databaseID
            )
        }
        #expect(NotionExportError.invalidToken.errorDescription?.contains(Self.token) == false)
    }

    @Test("404 no destino é a pegadinha clássica — não compartilhado")
    func missingObjectMapsToNotShared() async {
        NotionAPIStub.reset()
        NotionAPIStub.handler = { _ in Self.json(404, ["code": "object_not_found"]) }

        await #expect(throws: NotionExportError.destinationNotShared) {
            try await Self.service().export(
                Self.sampleSession(),
                token: Self.token,
                destination: Self.databaseID
            )
        }
    }

    @Test("URL de database com ?v=view exporta o path, não a view")
    func exportUsesPathIDNotViewQuery() async throws {
        NotionAPIStub.reset()
        NotionAPIStub.handler = { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "GET", path.contains("/databases/") {
                if path.contains(NotionDestination.dashedID(Self.viewID)) {
                    return Self.json(404, ["code": "object_not_found"])
                }
                if path.contains(NotionDestination.dashedID(Self.databaseID)) {
                    return Self.json(
                        200,
                        [
                            "object": "database",
                            "properties": ["Name": ["type": "title"]]
                        ]
                    )
                }
                return Self.json(404, ["code": "object_not_found"])
            }
            if request.httpMethod == "GET", path.contains("/pages/") {
                return Self.json(404, ["code": "object_not_found"])
            }
            if request.httpMethod == "POST", path == "/v1/pages" {
                return Self.json(
                    200,
                    [
                        "object": "page",
                        "id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                        "url": Self.pageURL.absoluteString
                    ]
                )
            }
            return Self.json(500, [:])
        }

        let url = "https://www.notion.so/acme/Daily-\(Self.databaseID)?v=\(NotionDestination.dashedID(Self.viewID))"
        let result = try await Self.service().export(
            Self.sampleSession(),
            token: Self.token,
            destination: url
        )
        #expect(result.url == Self.pageURL)
        let create = try #require(NotionAPIStub.requests.first { $0.httpMethod == "POST" })
        let parent = Self.bodyJSON(create)["parent"] as? [String: Any]
        #expect(parent?["database_id"] as? String == NotionDestination.dashedID(Self.databaseID))
        #expect(
            NotionAPIStub.requests.contains {
                ($0.url?.path ?? "").contains(NotionDestination.dashedID(Self.viewID))
            } == false
        )
    }

    @Test("429 com Retry-After:0 e depois 200 conclui; 429 eterno falha no teto")
    func rateLimitIsHonoredThenCapped() async throws {
        // Sentido A: um 429 + Retry-After 0 seguido de 200 não pode abortar.
        NotionAPIStub.reset()
        let recoveredSleeps = SleepLog()
        let gets = Counter()
        NotionAPIStub.handler = { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "GET", path.contains("/databases/") {
                let count = gets.increment()
                if count == 1 {
                    return (429, ["Retry-After": "0"], Data("{\"message\":\"slow\"}".utf8))
                }
                return Self.json(
                    200,
                    ["object": "database", "properties": ["Name": ["type": "title"]]]
                )
            }
            if request.httpMethod == "POST" {
                return Self.json(
                    200,
                    [
                        "object": "page",
                        "id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                        "url": Self.pageURL.absoluteString
                    ]
                )
            }
            return Self.json(500, [:])
        }
        let recovered = try await Self.service(sleep: recoveredSleeps.sleeper).export(
            Self.sampleSession(),
            token: Self.token,
            destination: Self.databaseID
        )
        #expect(recovered.url == Self.pageURL)
        #expect(recoveredSleeps.values == [0])
        #expect(gets.value == 2)

        // Sentido B: 429 eterno honra o teto de tentativas e não cria segunda página.
        NotionAPIStub.reset()
        let cappedSleeps = SleepLog()
        NotionAPIStub.handler = { _ in
            (429, ["Retry-After": "7"], Data("{\"message\":\"slow down\"}".utf8))
        }
        do {
            _ = try await Self.service(sleep: cappedSleeps.sleeper).export(
                Self.sampleSession(),
                token: Self.token,
                destination: Self.databaseID
            )
            Issue.record("tinha que falhar no 429 eterno")
        } catch let error as NotionExportError {
            #expect(error == .rateLimited(retryAfterSeconds: 7))
            #expect(error.errorDescription?.contains(Self.token) == false)
        } catch {
            Issue.record("erro inesperado: \(error)")
        }
        #expect(cappedSleeps.values.count == NotionExportPolicy.standard.maxRateLimitRetries)
        #expect(cappedSleeps.values.allSatisfy { $0 == 7 })
        #expect(NotionAPIStub.requests.count == NotionExportPolicy.standard.maxRateLimitRetries + 1)
        #expect(NotionAPIStub.requests.contains { $0.httpMethod == "POST" } == false)
    }

    @Test("Retry-After enorme é grampeado; 429 no PATCH não abre outra página")
    func retryAfterIsCappedAndPatchRetriesSamePage() async throws {
        let sleeps = SleepLog()
        NotionAPIStub.reset()
        let patches = Counter()
        NotionAPIStub.handler = { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "GET", path.contains("/databases/") {
                return Self.json(
                    200,
                    ["object": "database", "properties": ["Name": ["type": "title"]]]
                )
            }
            if request.httpMethod == "POST", path == "/v1/pages" {
                return Self.json(
                    200,
                    [
                        "object": "page",
                        "id": "cccccccc-dddd-eeee-ffff-000000000000",
                        "url": Self.pageURL.absoluteString
                    ]
                )
            }
            if request.httpMethod == "PATCH" {
                if patches.increment() == 1 {
                    return (429, ["Retry-After": "999"], Data("{\"message\":\"slow\"}".utf8))
                }
                return Self.json(200, ["object": "list", "results": [] as [Any]])
            }
            return Self.json(500, [:])
        }

        var session = Self.sampleSession()
        session.turns = Self.manyTurns(count: 110)
        let result = try await Self.service(sleep: sleeps.sleeper).export(
            session,
            token: Self.token,
            destination: Self.databaseID
        )
        #expect(result.url == Self.pageURL)
        #expect(sleeps.values == [NotionExportPolicy.standard.maxRetryAfterSeconds])
        #expect(NotionAPIStub.requests.filter { $0.httpMethod == "POST" }.count == 1)
        #expect(patches.value == 2)
    }

    @Test("Deadline estourado e cancelamento no sleep abortam sem loop")
    func deadlineAndCancellationStopTheExport() async {
        NotionAPIStub.reset()
        NotionAPIStub.handler = { _ in
            (429, ["Retry-After": "1"], Data("{}".utf8))
        }

        let expired = NotionExportPolicy(
            maxRateLimitRetries: 3,
            maxRetryAfterSeconds: 20,
            exportDeadline: 0
        )
        await #expect(throws: NotionExportError.timedOut) {
            try await Self.service(policy: expired).export(
                Self.sampleSession(),
                token: Self.token,
                destination: Self.databaseID
            )
        }
        #expect(NotionAPIStub.requests.isEmpty)

        NotionAPIStub.reset()
        NotionAPIStub.handler = { _ in
            (429, ["Retry-After": "1"], Data("{}".utf8))
        }
        do {
            _ = try await Self.service(sleep: { _ in throw CancellationError() }).export(
                Self.sampleSession(),
                token: Self.token,
                destination: Self.databaseID
            )
            Issue.record("cancelamento no Retry-After tinha que subir")
        } catch is CancellationError {
            // ok
        } catch {
            Issue.record("esperava CancellationError, veio \(error)")
        }
        #expect(NotionAPIStub.requests.count == 1)
    }

    @Test("A sessão própria tem timeouts finitos; a UI retém e cancela a Task")
    func sessionTimeoutsAndViewCancelsTheTask() throws {
        #expect(NotionExportService.requestTimeout <= 30)
        #expect(NotionExportService.resourceTimeout <= 180)
        #expect(NotionExportService.resourceTimeout < 7 * 24 * 60 * 60)
        #expect(NotionExportPolicy.standard.exportDeadline <= 120)

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let service = try String(
            contentsOf: repoRoot.appending(path: "voiz/Services/NotionExportService.swift"),
            encoding: .utf8
        )
        #expect(service.contains("URLSession.shared") == false)
        #expect(service.contains("timeoutIntervalForRequest"))
        #expect(service.contains("timeoutIntervalForResource"))

        let view = try String(
            contentsOf: repoRoot.appending(path: "voiz/Views/MeetingView.swift"),
            encoding: .utf8
        )
        #expect(view.contains("notionExportTask"))
        #expect(view.contains("onDisappear"))
        #expect(view.contains("notionExportTask?.cancel()"))
        #expect(view.contains("Task {") == false || view.contains("notionExportTask = Task"))
    }

    @Test("Destino vazio e texto ilegível têm erros distintos")
    func emptyAndGarbageDestinationsFailLocally() async {
        NotionAPIStub.reset()
        NotionAPIStub.handler = { _ in
            Issue.record("destino inválido não pode ir à rede")
            return Self.json(500, [:])
        }

        await #expect(throws: NotionExportError.missingToken) {
            try await Self.service().export(Self.sampleSession(), token: "  ", destination: Self.databaseID)
        }
        await #expect(throws: NotionExportError.missingDestination) {
            try await Self.service().export(Self.sampleSession(), token: Self.token, destination: "  ")
        }
        await #expect(throws: NotionExportError.invalidDestination) {
            try await Self.service().export(Self.sampleSession(), token: Self.token, destination: "slack.com/foo")
        }
        #expect(NotionAPIStub.requests.isEmpty)
    }

    @Test("201+ blocos exigem dois appends — o último bloco vai no segundo PATCH")
    func longTranscriptNeedsTwoAppends() async throws {
        #expect(NotionExportService.chunked(Array(1...201), size: 100).map(\.count) == [100, 100, 1])

        var session = Self.sampleSession()
        session.turns = Self.manyTurns(count: 220)
        session.turns[session.turns.count - 1].text = Self.finalBlockMarker
        let children = NotionPageContent.children(for: session)
        #expect(children.count > NotionExportService.maxChildrenPerRequest * 2)

        NotionAPIStub.reset()
        NotionAPIStub.handler = { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "GET", path.contains("/databases/") {
                return Self.json(
                    200,
                    [
                        "object": "database",
                        "properties": ["Name": ["type": "title"]]
                    ]
                )
            }
            if request.httpMethod == "POST", path == "/v1/pages" {
                return Self.json(
                    200,
                    [
                        "object": "page",
                        "id": "cccccccc-dddd-eeee-ffff-000000000000",
                        "url": Self.pageURL.absoluteString
                    ]
                )
            }
            if request.httpMethod == "PATCH", path.contains("/children") {
                return Self.json(200, ["object": "list", "results": [] as [Any]])
            }
            return Self.json(500, [:])
        }

        let result = try await Self.service().export(
            session,
            token: Self.token,
            destination: Self.databaseID
        )
        #expect(result.url == Self.pageURL)
        let create = try #require(NotionAPIStub.requests.first { $0.httpMethod == "POST" })
        let first = (Self.bodyJSON(create)["children"] as? [Any])?.count ?? 0
        #expect(first == NotionExportService.maxChildrenPerRequest)
        let createBody = String(data: create.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(createBody.contains(Self.finalBlockMarker) == false)

        let patches = NotionAPIStub.requests.filter { $0.httpMethod == "PATCH" }
        #expect(patches.count == 2, "produção com um único append passaria o teste antigo de 110 turns")
        #expect((Self.bodyJSON(patches[0])["children"] as? [Any])?.count == NotionExportService.maxChildrenPerRequest)
        let remainder = children.count - (NotionExportService.maxChildrenPerRequest * 2)
        #expect((Self.bodyJSON(patches[1])["children"] as? [Any])?.count == remainder)
        let secondBody = String(data: patches[1].httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(secondBody.contains(Self.finalBlockMarker))
        let firstAppendBody = String(data: patches[0].httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(firstAppendBody.contains(Self.finalBlockMarker) == false)
    }

    @Test("Append que falha depois da página criada devolve o PARCIAL com a URL")
    func failedAppendKeepsTheCreatedPage() async throws {
        var session = Self.sampleSession()
        session.turns = Self.manyTurns(count: 220)
        let children = NotionPageContent.children(for: session)

        NotionAPIStub.reset()
        NotionAPIStub.handler = { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "GET", path.contains("/databases/") {
                return Self.json(200, ["object": "database", "properties": ["Name": ["type": "title"]]])
            }
            if request.httpMethod == "POST", path == "/v1/pages" {
                return Self.json(
                    200,
                    ["object": "page", "id": "cccccccc-dddd-eeee-ffff-000000000000", "url": Self.pageURL.absoluteString]
                )
            }
            // O append cai — é o cenário do parecer: página criada, conteúdo pela metade.
            if request.httpMethod == "PATCH" { return Self.json(500, [:]) }
            return Self.json(500, [:])
        }

        do {
            _ = try await Self.service().export(
                session,
                token: Self.token,
                destination: Self.databaseID
            )
            Issue.record("a exportação tinha que falhar — o append devolveu 500")
        } catch let error as NotionExportError {
            let page = try #require(
                error.createdPage,
                "descartar o resultado deixa a página órfã no Notion e o usuário sem a URL"
            )
            #expect(page.url == Self.pageURL)
            guard case .partiallyExported(_, let appended, let total, let cause) = error else {
                Issue.record("o erro tem que ser o parcial, não um genérico")
                return
            }
            #expect(appended == NotionExportService.maxChildrenPerRequest)
            #expect(total == children.count)
            #expect(cause == .requestFailed)
            let message = try #require(error.errorDescription)
            #expect(message.contains("\(appended)"), "a mensagem diz quanto subiu")
            #expect(
                message.contains("outra página"),
                "e avisa que exportar de novo duplica — é o que o usuário precisa saber antes de tentar"
            )
        }

        // A página foi criada UMA vez: o parcial não é uma segunda tentativa.
        #expect(NotionAPIStub.requests.filter { $0.httpMethod == "POST" }.count == 1)
    }

    @Test("Cancelamento depois da página criada também vira parcial, não silêncio")
    func cancellationAfterCreateStillReportsThePage() async throws {
        var session = Self.sampleSession()
        session.turns = Self.manyTurns(count: 220)

        NotionAPIStub.reset()
        NotionAPIStub.handler = { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "GET", path.contains("/databases/") {
                return Self.json(200, ["object": "database", "properties": ["Name": ["type": "title"]]])
            }
            if request.httpMethod == "POST", path == "/v1/pages" {
                return Self.json(
                    200,
                    ["object": "page", "id": "cccccccc-dddd-eeee-ffff-000000000000", "url": Self.pageURL.absoluteString]
                )
            }
            if request.httpMethod == "PATCH" { return Self.json(429, [:], headers: ["Retry-After": "1"]) }
            return Self.json(500, [:])
        }

        // O cancelamento chega durante a espera do 429 no append.
        let service = Self.service(sleep: { _ in throw CancellationError() })
        do {
            _ = try await service.export(session, token: Self.token, destination: Self.databaseID)
            Issue.record("a exportação tinha que ser interrompida")
        } catch let error as NotionExportError {
            let page = try #require(
                error.createdPage,
                "engolir o CancellationError aqui é o silêncio total que deixa a página órfã"
            )
            #expect(page.url == Self.pageURL)
            guard case .partiallyExported(_, _, _, let cause) = error else {
                Issue.record("cancelamento com página criada tem que sair como parcial")
                return
            }
            #expect(cause == .cancelled)
        }
    }

    @Test("O prazo total limita a request, não só a admissão dela")
    func deadlineBoundsTheRequestItself() async throws {
        NotionAPIStub.reset()
        NotionAPIStub.handler = { _ in
            Self.json(200, ["object": "database", "properties": ["Name": ["type": "title"]]])
        }

        // Prazo total de 2 s. A request admitida NÃO pode sair com os 30 s de
        // timeout do serviço: uma request aceita perto do fim do prazo rodaria
        // 30 s além dele, e o contrato de 90 s viraria 119 na prática.
        let service = Self.service(
            policy: NotionExportPolicy(
                maxRateLimitRetries: 0,
                maxRetryAfterSeconds: 20,
                exportDeadline: 2
            )
        )
        var session = Self.sampleSession()
        session.turns = Self.manyTurns(count: 2)
        _ = try? await service.export(session, token: Self.token, destination: Self.databaseID)

        let sent = try #require(NotionAPIStub.requests.first)
        #expect(
            sent.timeoutInterval <= 2.0001,
            "o timeout da request tem que caber no que sobra do prazo total"
        )
        #expect(sent.timeoutInterval > 0)
        #expect(
            sent.timeoutInterval < NotionExportService.requestTimeout,
            "com o teto fixo de 30 s a request atravessaria o prazo inteiro"
        )
    }

    @Test("O parcial fica registrado em disco — o aviso não depende de canal de UI")
    func partialIsPersistedRegardlessOfUIChannel() throws {
        // O toast do notch é opt-in e vem DESLIGADO: com ele off, um parcial
        // por cancelamento não avisava NADA. O registro não depende de
        // configuração, e é ele que fecha esse buraco.
        let suite = "voiz.tests.notion.partial.\(UUID().uuidString)"
        let store = NotionPartialExportStore(suiteName: suite)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let sessionID = UUID()
        #expect(store.pending(for: sessionID) == nil)

        let partial = NotionPartialExport(
            pageURL: Self.pageURL,
            appendedBlocks: 100,
            totalBlocks: 240
        )
        store.record(partial, for: sessionID, generation: 1)

        // Uma instância NOVA lê o mesmo registro: sobrevive a fechar a tela e
        // a fechar o app, que é o cenário do cancelamento no onDisappear.
        let reopened = NotionPartialExportStore(suiteName: suite)
        #expect(reopened.pending(for: sessionID) == partial)
        #expect(reopened.pending(for: UUID()) == nil, "o registro é por sessão")

        // Reconhecido pelo usuário: some.
        reopened.clear(for: sessionID, generation: 2)
        #expect(NotionPartialExportStore(suiteName: suite).pending(for: sessionID) == nil)
    }

    @Test("O registro do parcial não vai para o Keychain nem carrega o token")
    func partialRecordCarriesNoSecret() throws {
        let suite = "voiz.tests.notion.partial.\(UUID().uuidString)"
        let store = NotionPartialExportStore(suiteName: suite)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let sessionID = UUID()
        store.record(
            NotionPartialExport(pageURL: Self.pageURL, appendedBlocks: 1, totalBlocks: 2),
            for: sessionID,
            generation: 1
        )
        let raw = UserDefaults(suiteName: suite)?.data(forKey: store.key) ?? Data()
        let text = String(data: raw, encoding: .utf8) ?? ""
        #expect(text.contains(Self.token) == false, "o token continua só no Keychain")
        // A URL vai lá, mas com as barras escapadas pelo JSON — comparo o valor
        // decodificado em vez do texto cru, senão o teste mede o encoder.
        #expect(store.pending(for: sessionID)?.pageURL == Self.pageURL)
    }

    @Test("Trocar de sessão troca o parcial: nem fantasma da anterior, nem ausência na nova")
    func switchingSessionsSwapsThePendingPartial() throws {
        // A busca global (⌘K) troca a sessão sem recriar esta parte da tela.
        // Os dois lados quebram: o parcial de A sobrevivendo em B leva o
        // "Abrir no Notion" para a página errada e o "Entendi" limpa o registro
        // errado; e B com parcial abrindo sem aviso deixa re-exportar às cegas.
        let suite = "voiz.tests.notion.switch.\(UUID().uuidString)"
        let store = NotionPartialExportStore(suiteName: suite)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let sessionA = UUID()
        let sessionB = UUID()
        let partialA = NotionPartialExport(
            pageURL: URL(string: "https://www.notion.so/pagina-da-sessao-A")!,
            appendedBlocks: 100,
            totalBlocks: 300
        )
        let partialB = NotionPartialExport(
            pageURL: URL(string: "https://www.notion.so/pagina-da-sessao-B")!,
            appendedBlocks: 200,
            totalBlocks: 250
        )

        // A tem parcial, B não: abrir B não pode herdar o de A.
        store.record(partialA, for: sessionA, generation: 1)
        #expect(store.pending(for: sessionA) == partialA)
        #expect(store.pending(for: sessionB) == nil, "B não tem parcial — nada de banner fantasma")

        // B tem parcial, A não: abrir B tem que trazer o DELE, não o silêncio.
        store.clear(for: sessionA, generation: 2)
        store.record(partialB, for: sessionB, generation: 1)
        #expect(store.pending(for: sessionA) == nil)
        let loadedB = try #require(
            store.pending(for: sessionB),
            "B com parcial abrindo sem aviso é o pior lado: re-exporta às cegas e cria a segunda página"
        )
        #expect(loadedB.pageURL == partialB.pageURL, "o link tem que ser o da sessão aberta")

        // Cada uma com o seu: um clear não alcança a outra. Gerações crescentes
        // porque o slot agora recusa escrita mais velha que a última.
        store.record(partialA, for: sessionA, generation: 3)
        store.clear(for: sessionB, generation: 3)
        #expect(store.pending(for: sessionA) == partialA)
        #expect(store.pending(for: sessionB) == nil)
    }

    @Test("O wiring do parcial na tela existe — os quatro pontos, e a recarga por SESSÃO")
    func meetingViewWiresThePartialWarning() throws {
        // `MeetingView` não compila no alvo de testes (é SwiftUI + AppKit +
        // EnvironmentObject), e sem esta guarda o Codex removeu o `record`, o
        // load e os `clear` e a suíte continuou VERDE — o store estava testado,
        // o wiring não. Mesma técnica da guarda de ordem do pipeline do O2.
        let source = try #require(
            Self.sourceOfFile("voiz/Views/MeetingView.swift"),
            "não consegui ler a view: a guarda não pode ser dada como cumprida"
        )

        #expect(
            source.contains(
                "NotionPartialExportStore.shared.record(partial, for: exportedSessionID, generation: generation)"
            ),
            "o record precisa do dono: sem a geração, escrita atrasada vence a nova"
        )
        #expect(
            source.contains("NotionPartialExportStore.shared.pending(for: newSessionID)"),
            "o load tem que ser por sessão, não uma leitura solta"
        )
        #expect(
            source.contains(".onChange(of: session.id, initial: true)"),
            "onAppear não roda quando a busca global troca a sessão no mesmo ramo"
        )
        #expect(
            source.contains(".onAppear {\n            notionPendingPartial") == false,
            "carregar o parcial no onAppear é exatamente o defeito que a troca de sessão explora"
        )
        #expect(
            source.contains("for: session.id,\n                        generation: notionExportGeneration"),
            "o \"Entendi\" limpa a sessão à vista, com a geração atual como dono da escrita"
        )
        #expect(
            source.contains("clear(for: exportedSessionID, generation: generation)"),
            "e a exportação que conclui inteira limpa a sessão que ELA exportou"
        )

        // A ORDEM importa: o registro em disco vem ANTES de qualquer canal de
        // UI, porque alerta e toast são condicionais e ele não é.
        let recordAt = try #require(source.range(of: "NotionPartialExportStore.shared.record("))
        let toastAt = try #require(source.range(of: "NotchOverlay.shared.showToast("))
        #expect(recordAt.lowerBound < toastAt.lowerBound)
    }

    @Test("Escrita atrasada não vence a nova, nem ressuscita o que foi limpo")
    func staleWriteLosesToTheNewerGeneration() throws {
        // A consequência da corrida que eu disse não conseguir testar é
        // observável AQUI: no disco. O slot era last-write-wins, então uma
        // exportação cancelada terminando tarde sobrescrevia o resultado de
        // uma exportação NOVA da mesma reunião.
        let suite = "voiz.tests.notion.cas.\(UUID().uuidString)"
        let store = NotionPartialExportStore(suiteName: suite)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let session = UUID()
        let stale = NotionPartialExport(
            pageURL: URL(string: "https://www.notion.so/pagina-VELHA")!,
            appendedBlocks: 100,
            totalBlocks: 300
        )
        let newer = NotionPartialExport(
            pageURL: URL(string: "https://www.notion.so/pagina-NOVA")!,
            appendedBlocks: 200,
            totalBlocks: 300
        )

        // A3 (geração 3) registra; A1 (geração 1) termina depois e tenta gravar.
        #expect(store.record(newer, for: session, generation: 3))
        #expect(
            store.record(stale, for: session, generation: 1) == false,
            "a escrita atrasada tem que ser RECUSADA, não aceita"
        )
        #expect(
            store.pending(for: session)?.pageURL == newer.pageURL,
            "o link que o usuário abre tem que ser o da exportação mais recente"
        )

        // Pior caso: A3 conclui INTEIRA e limpa; A1 atrasada grava de novo.
        #expect(store.clear(for: session, generation: 3))
        #expect(store.pending(for: session) == nil)
        #expect(
            store.record(stale, for: session, generation: 1) == false,
            "gravar depois do clear ressuscita um aviso sobre página que não é mais a verdade"
        )
        #expect(
            store.pending(for: session) == nil,
            "o slot limpo continua limpo — é para isso que ele não é removido"
        )

        // E o caminho normal segue funcionando: geração maior escreve.
        #expect(store.record(newer, for: session, generation: 4))
        #expect(store.pending(for: session)?.pageURL == newer.pageURL)
    }

    @Test("Execuções são ORDENADAS: nem a velha bloqueia a nova, nem a velha viva vence a nova")
    func runsAreOrderedInBothDirections() throws {
        let suite = "voiz.tests.notion.run.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let session = UUID()
        let velha = NotionPartialExportStore(suiteName: suite, runSequence: 7)
        let nova = NotionPartialExportStore(suiteName: suite, runSequence: 8)
        let deOntem = NotionPartialExport(
            pageURL: URL(string: "https://www.notion.so/de-ontem")!,
            appendedBlocks: 10,
            totalBlocks: 90
        )
        let deHoje = NotionPartialExport(
            pageURL: URL(string: "https://www.notion.so/de-hoje")!,
            appendedBlocks: 20,
            totalBlocks: 90
        )

        // Sentido 1 — VELHA → NOVA. A execução anterior deixou geração alta; a
        // nova começa em 1 e não pode ser bloqueada por isso.
        #expect(velha.record(deOntem, for: session, generation: 99))
        #expect(
            nova.record(deHoje, for: session, generation: 1),
            "execução nova começa em 1 e a geração 99 da anterior não pode barrá-la"
        )
        #expect(nova.pending(for: session)?.pageURL == deHoje.pageURL)

        // Sentido 2 — NOVA → VELHA AINDA VIVA. É a fronteira que faltava: a
        // execução nova já escreveu, e uma Task sobrevivente da anterior chega
        // depois com geração altíssima. Com UUID a comparação não tinha como
        // recusar, e o link novo era perdido.
        #expect(
            velha.record(deOntem, for: session, generation: 999) == false,
            "Task de execução anterior não vence a atual, por maior que seja a geração dela"
        )
        #expect(
            nova.pending(for: session)?.pageURL == deHoje.pageURL,
            "o link que o usuário abre continua o da execução atual"
        )
        #expect(
            velha.clear(for: session, generation: 1000) == false,
            "e ela também não pode LIMPAR o aviso da execução atual"
        )
        #expect(
            nova.pending(for: session)?.pageURL == deHoje.pageURL,
            "limpar o aviso da execução atual é o mesmo dano: o usuário re-exporta às cegas"
        )
    }

    @Test("O contador de execução é persistente e só cresce")
    func runSequenceIsPersistentAndMonotonic() throws {
        let suite = "voiz.tests.notion.seq.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = NotionPartialExportStore.nextRunSequence(in: defaults)
        let second = NotionPartialExportStore.nextRunSequence(in: defaults)
        let third = NotionPartialExportStore.nextRunSequence(in: defaults)
        #expect(first < second)
        #expect(second < third)
        #expect(
            defaults.integer(forKey: NotionPartialExportStore.runSequenceKey) == third,
            "o contador vive em disco — em memória ele reiniciaria em 1 a cada launch"
        )
    }

    @Test("A Task antiga não finaliza sobre a nova — propriedade por geração")
    func staleExportTaskCannotFinalizeOverTheCurrentOne() throws {
        // O `defer { isNotionExporting = false }` era INCONDICIONAL. Sequência:
        // A suspensa em rede; ⌘K abre B e cancela A; usuário exporta B (flag
        // true); A retoma o cancelamento e o defer DELA derruba a flag com B em
        // voo — o botão reabre, e um clique cria uma segunda exportação. Se B já
        // passou do POST, o resultado é parcial mais página duplicada.
        let source = try #require(
            Self.sourceOfFile("voiz/Views/MeetingView.swift"),
            "não consegui ler a view: a guarda não pode ser dada como cumprida"
        )

        #expect(
            source.contains("defer { isNotionExporting = false }") == false,
            "defer incondicional é a corrida: Task morta zerando flag de Task viva"
        )
        #expect(
            source.contains("if notionExportGeneration == generation { isNotionExporting = false }"),
            "só o dono ATUAL zera a flag"
        )
        #expect(
            source.contains("let generation = notionExportGeneration"),
            "a geração é congelada no início da exportação"
        )
        #expect(
            source.components(separatedBy: "notionExportGeneration += 1").count - 1 >= 2,
            "incrementa ao iniciar exportação E ao trocar de sessão — os dois trocam o dono"
        )

        // O ciclo da Task na troca de sessão: cancelar E soltar a referência.
        let switchBlock = try #require(
            source.range(of: ".onChange(of: session.id, initial: true)").map { range in
                String(source[range.lowerBound...].prefix(700))
            }
        )
        #expect(switchBlock.contains("notionExportTask?.cancel()"))
        #expect(switchBlock.contains("notionExportTask = nil"))
        #expect(switchBlock.contains("notionExportGeneration += 1"))

        // E o registro do parcial vai para a sessão EXPORTADA, não para a que
        // está à vista quando a Task termina.
        #expect(source.contains("let exportedSessionID = session.id"))
        #expect(
            source.contains(
                "NotionPartialExportStore.shared.record(partial, for: exportedSessionID, generation: generation)"
            )
        )
        #expect(
            source.contains("NotionPartialExportStore.shared.record(partial, for: session.id)") == false,
            "gravar em session.id grava na sessão ERRADA quando a Task termina tarde"
        )
        #expect(
            source.contains("clear(for: exportedSessionID, generation: generation)"),
            "o clear do sucesso também é uma escrita, e também precisa de dono"
        )
    }

    @Test("Keychain guarda token e destino fora de UserDefaults")
    func credentialsStayInKeychain() {
        let store = NotionCredentialsStore(service: "com.rmb.voiz.notion.test.\(UUID().uuidString)")
        defer { store.deleteAll() }

        #expect(store.hasToken == false)
        store.setToken(Self.token)
        store.setDestination("https://www.notion.so/\(Self.databaseID)")
        #expect(store.hasToken)
        #expect(store.token() == Self.token)
        #expect(store.destination().contains(Self.databaseID))

        let defaults = UserDefaults.standard.dictionaryRepresentation()
        for value in defaults.values {
            let text = String(describing: value)
            #expect(text.contains(Self.token) == false)
        }

        store.setToken("  ")
        #expect(store.hasToken == false)
    }

    @Test("O serviço não interpola o token em print nem em log")
    func sourceNeverLogsTheToken() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appending(path: "voiz/Services/NotionExportService.swift"),
            encoding: .utf8
        )
        #expect(source.contains("print(") == false)
        #expect(source.contains("Logger(") == false)
        #expect(source.contains("addDebugLog") == false)
        let leaked = source.split(separator: "\n").filter { line in
            (line.contains("\\(token)") || line.contains("\\(secret)"))
                && !line.contains("Authorization")
        }
        #expect(leaked.isEmpty, "token interpolado fora do header Authorization: \(leaked)")
    }

    // MARK: - Fixtures

    /// O fonte de um arquivo do app, para as guardas de FORMA — o que não
    /// compila no alvo de testes se prova lendo.
    private static func sourceOfFile(_ relativePath: String) -> String? {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Meeting/
            .deletingLastPathComponent()   // voizTests/
            .deletingLastPathComponent()   // raiz do repositório
        return try? String(contentsOf: repoRoot.appending(path: relativePath), encoding: .utf8)
    }

    private static func service(
        policy: NotionExportPolicy = .standard,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in },
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> NotionExportService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NotionAPIStub.self]
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return NotionExportService(
            session: URLSession(configuration: config),
            policy: policy,
            sleep: sleep,
            now: now
        )
    }

    private static func manyTurns(count: Int) -> [MeetingTurn] {
        (0..<count).map { index in
            MeetingTurn(
                source: .microphone,
                speakerName: "Rafa",
                text: "fala \(index)",
                startTime: Double(index),
                endTime: Double(index) + 0.5
            )
        }
    }

    private static func sampleSession() -> MeetingSession {
        var session = MeetingSession(
            title: "Daily",
            sessionType: .meeting,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            endedAt: Date(timeIntervalSince1970: 1_800_001_800)
        )
        session.speakers = [
            MeetingSpeaker(source: .microphone, name: "Rafa"),
            MeetingSpeaker(id: "S1", source: .systemAudio, name: "Ana")
        ]
        session.turns = [
            MeetingTurn(
                source: .microphone,
                speakerName: "Rafa",
                text: "olá time",
                startTime: 0,
                endTime: 2
            )
        ]
        session.summary = MeetingSummary(
            title: "Daily de produto",
            sections: [
                .paragraph(id: "overview", title: "Resumo", text: "Falamos do Notion."),
                .actions(
                    id: "actions",
                    title: "Ações",
                    items: [
                        MeetingActionItem(text: "Exportar reunião", assignee: "Rafa", dueDate: "amanhã")
                    ]
                )
            ]
        )
        return session
    }

    private static func json(
        _ status: Int,
        _ object: [String: Any],
        headers: [String: String] = [:]
    ) -> (Int, [String: String], Data) {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return (status, ["Content-Type": "application/json"].merging(headers) { _, new in new }, data)
    }

    private static func bodyJSON(_ request: URLRequest) -> [String: Any] {
        guard let data = request.httpBody,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    private static func assertNoTokenLeak(in request: URLRequest) {
        let url = request.url?.absoluteString ?? ""
        #expect(url.contains(token) == false)
        if let body = request.httpBody, let text = String(data: body, encoding: .utf8) {
            #expect(text.contains(token) == false)
        }
    }
}

/// URLProtocol fake: sem DNS, sem rede. O handler decide status/corpo.
final class NotionAPIStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock()
        handler = nil
        requests = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var materialized = request
        if materialized.httpBody == nil, let streamed = Self.bodyFromStream(request) {
            materialized.httpBody = streamed
        }

        Self.lock.lock()
        Self.requests.append(materialized)
        let handler = Self.handler
        Self.lock.unlock()

        do {
            let (status, headers, data) = try handler?(materialized) ?? (500, [:], Data())
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://api.notion.com/")!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func bodyFromStream(_ request: URLRequest) -> Data? {
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: 1024)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        return data.isEmpty ? nil : data
    }
}

final class SleepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [TimeInterval] = []

    var values: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    var sleeper: @Sendable (TimeInterval) async throws -> Void {
        { [self] seconds in
            self.lock.lock()
            self.stored.append(seconds)
            self.lock.unlock()
        }
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        stored += 1
        return stored
    }
}
