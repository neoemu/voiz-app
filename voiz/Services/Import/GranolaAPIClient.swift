import Foundation

/// Falhas da API pública do Granola. Nunca carregam a chave nem o corpo da resposta.
nonisolated enum GranolaImportError: Error, Equatable, Sendable {
    case invalidKey
    case accessDenied
    case transcriptsDisabled
    case noteUnavailable
    case transcriptTooLarge
    case rateLimited
    case offline
    case serviceUnavailable
    case unreadableResponse

    /// Repetir nas próximas notas só desperdiçaria requisições: a chave caiu ou a rede sumiu.
    var endsImport: Bool {
        switch self {
        case .invalidKey, .accessDenied, .transcriptsDisabled, .rateLimited, .offline, .serviceUnavailable:
            return true
        case .noteUnavailable, .transcriptTooLarge, .unreadableResponse:
            return false
        }
    }

    var message: String {
        switch self {
        case .invalidKey:
            return String(localized: "O Granola recusou esta chave.")
        case .accessDenied:
            return String(localized: "Esta chave não tem acesso às notas. Confira o plano e os escopos dela.")
        case .transcriptsDisabled:
            return String(localized: "O administrador do workspace bloqueou as transcrições pela API.")
        case .rateLimited:
            return String(localized: "O Granola limitou as requisições. Tente de novo em alguns minutos.")
        case .offline:
            return String(localized: "Sem conexão com o Granola.")
        case .serviceUnavailable:
            return String(localized: "O Granola está indisponível agora.")
        case .noteUnavailable, .transcriptTooLarge, .unreadableResponse:
            return String(localized: "O Granola respondeu de um jeito inesperado.")
        }
    }
}

/// `GET /v1/notes`: o suficiente para decidir o que importar sem baixar cada reunião.
nonisolated struct GranolaNoteListing: Decodable, Equatable, Sendable {
    let id: String
    let title: String?
    let createdAt: Date
    let deletedAt: Date?
}

/// `GET /v1/notes/{id}`. `source` e `attribution` ficam como texto para um valor novo da API não
/// derrubar a reunião inteira no decode.
nonisolated struct GranolaNote: Decodable, Equatable, Sendable {
    struct CalendarEvent: Decodable, Equatable, Sendable {
        let eventTitle: String?
        let scheduledStartTime: Date?
        let scheduledEndTime: Date?
    }

    struct Folder: Decodable, Equatable, Sendable {
        let id: String
        let name: String
    }

    struct Speaker: Decodable, Equatable, Sendable {
        let source: String
        let attribution: String?
        let diarizationLabel: String?
        let name: String?
    }

    struct Segment: Decodable, Equatable, Sendable {
        let speaker: Speaker
        let text: String
        let startTime: Date
        let endTime: Date
    }

    let id: String
    let title: String?
    let createdAt: Date
    let calendarEvent: CalendarEvent?
    let folderMembership: [Folder]
    let summaryText: String?
    let summaryMarkdown: String?
    let privateNotesText: String?
    let privateNotesMarkdown: String?
    var transcript: [Segment]?
}

/// Cliente da API pública oficial: https://docs.granola.ai/introduction
///
/// Sessão efêmera, sem cookies nem cache: transcrições não ficam no `URLCache` do app.
/// Série em vez de paralelo: o limite é 5 req/s e cada nota custa uma requisição.
nonisolated struct GranolaAPIClient: Sendable {
    static let baseURL = URL(string: "https://public-api.granola.ai/v1")!
    private static let maxAttempts = 5
    private static let maxWait: TimeInterval = 30

    private let apiKey: String
    private let session: URLSession
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    init(
        apiKey: String,
        session: URLSession = GranolaAPIClient.makeSession(),
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = GranolaAPIClient.defaultSleep
    ) {
        self.apiKey = apiKey
        self.session = session
        self.sleep = sleep
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    static func defaultSleep(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func listNotes() async throws -> [GranolaNoteListing] {
        struct Page: Decodable {
            let notes: [GranolaNoteListing]
            let hasMore: Bool
            let cursor: String?
        }
        var notes: [GranolaNoteListing] = []
        var cursor: String?
        repeat {
            var query = [URLQueryItem(name: "page_size", value: "30")]
            if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
            let page: Page = try await get("notes", query: query)
            notes += page.notes
            cursor = page.hasMore ? page.cursor : nil
        } while cursor != nil
        return notes
    }

    /// Transcrição longa demais para vir junto (413) é buscada à parte, em páginas.
    func note(id: String) async throws -> GranolaNote {
        do {
            return try await get("notes/\(id)", query: [URLQueryItem(name: "include", value: "transcript")])
        } catch GranolaImportError.transcriptTooLarge {
            var note: GranolaNote = try await get("notes/\(id)")
            note.transcript = try await transcript(noteID: id)
            return note
        } catch GranolaImportError.accessDenied {
            throw GranolaImportError.transcriptsDisabled
        }
    }

    private func transcript(noteID: String) async throws -> [GranolaNote.Segment] {
        struct Page: Decodable {
            let transcript: [GranolaNote.Segment]
            let hasMore: Bool
            let cursor: String?
        }
        var segments: [GranolaNote.Segment] = []
        var cursor: String?
        do {
            repeat {
                var query = [URLQueryItem(name: "page_size", value: "100")]
                if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
                let page: Page = try await get("notes/\(noteID)/transcript", query: query)
                segments += page.transcript
                cursor = page.hasMore ? page.cursor : nil
            } while cursor != nil
        } catch GranolaImportError.accessDenied {
            throw GranolaImportError.transcriptsDisabled
        }
        return segments
    }

    private func get<Response: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> Response {
        var components = URLComponents(url: Self.baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var lastError = GranolaImportError.serviceUnavailable
        for attempt in 0..<Self.maxAttempts {
            try Task.checkCancellation()
            let wait: TimeInterval
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw GranolaImportError.unreadableResponse }
                switch http.statusCode {
                case 200..<300:
                    do { return try Self.decoder.decode(Response.self, from: data) }
                    catch { throw GranolaImportError.unreadableResponse }
                case 401: throw GranolaImportError.invalidKey
                case 403: throw GranolaImportError.accessDenied
                case 404: throw GranolaImportError.noteUnavailable
                case 413: throw GranolaImportError.transcriptTooLarge
                case 429:
                    lastError = .rateLimited
                    wait = Self.retryDelay(http, attempt: attempt)
                case 500..<600:
                    lastError = .serviceUnavailable
                    wait = Self.retryDelay(http, attempt: attempt)
                default: throw GranolaImportError.unreadableResponse
                }
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                lastError = .offline
                wait = Self.backoff(attempt)
            }
            if attempt < Self.maxAttempts - 1 { try await sleep(wait) }
        }
        throw lastError
    }

    private static func retryDelay(_ response: HTTPURLResponse, attempt: Int) -> TimeInterval {
        if let header = response.value(forHTTPHeaderField: "Retry-After"), let seconds = TimeInterval(header) {
            return min(max(seconds, 0), maxWait)
        }
        return backoff(attempt)
    }

    private static func backoff(_ attempt: Int) -> TimeInterval {
        min(pow(2, Double(attempt)), maxWait)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            if let date = try? fractional.parse(text) { return date }
            if let date = try? Date.ISO8601FormatStyle().parse(text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Data inválida"))
        }
        return decoder
    }()
}
