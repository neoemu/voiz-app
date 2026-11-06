import Foundation

/// Exporta uma reunião para o Notion (REST oficial, versão pinada). URLSession puro.
///
/// BYO token: quem chama passa o secret já lido do Keychain. Este tipo **não** lê
/// credenciais, **não** loga o token, **não** telemetra.
struct NotionExportPolicy: Sendable, Equatable {
    /// Tentativas extras depois do primeiro 429. Total de requests = 1 + este valor.
    var maxRateLimitRetries: Int
    /// Teto de espera por 429. Retry-After maior que isso é grampeado, não loopado.
    var maxRetryAfterSeconds: TimeInterval
    /// Prazo total da exportação (create + appends).
    var exportDeadline: TimeInterval

    static let standard = NotionExportPolicy(
        maxRateLimitRetries: 3,
        maxRetryAfterSeconds: 20,
        exportDeadline: 90
    )
}

struct NotionExportService: Sendable {
    static let apiVersion = "2022-06-28"
    static let apiHost = "api.notion.com"
    static let maxRichText = 2000
    static let maxChildrenPerRequest = 100
    static let requestTimeout: TimeInterval = 30
    static let resourceTimeout: TimeInterval = 120

    var session: URLSession
    var policy: NotionExportPolicy
    var sleep: @Sendable (TimeInterval) async throws -> Void
    var now: @Sendable () -> Date

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    static func defaultSleep(_ seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    init(
        session: URLSession = NotionExportService.makeSession(),
        policy: NotionExportPolicy = .standard,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = NotionExportService.defaultSleep,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.policy = policy
        self.sleep = sleep
        self.now = now
    }

    func export(
        _ meeting: MeetingSession,
        token: String,
        destination: String
    ) async throws -> NotionExportResult {
        try Task.checkCancellation()
        let started = now()
        try checkDeadline(started: started)

        let secret = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { throw NotionExportError.missingToken }

        guard let destinationID = NotionDestination.normalizeID(destination) else {
            let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
            throw trimmed.isEmpty ? NotionExportError.missingDestination : NotionExportError.invalidDestination
        }

        let parent = try await resolveParent(id: destinationID, token: secret, started: started)
        let children = NotionPageContent.children(for: meeting)
        let title = NotionPageContent.title(for: meeting)
        let chunks = Self.chunked(children, size: Self.maxChildrenPerRequest)
        let first = chunks.first ?? []

        let created = try await createPage(
            parent: parent,
            title: title,
            children: first,
            token: secret,
            started: started
        )
        // A partir daqui existe estado do lado de fora. Nenhuma falha pode
        // descartar `created`: a página está no Notion, e esconder isso do
        // usuário é pior que a exportação incompleta — ele fica sem saber que
        // precisa conferir, e o retry cria uma segunda página.
        var appended = first.count
        for chunk in chunks.dropFirst() {
            do {
                try await appendChildren(
                    pageID: created.id,
                    children: chunk,
                    token: secret,
                    started: started
                )
                appended += chunk.count
            } catch {
                throw NotionExportError.partiallyExported(
                    page: created,
                    appendedBlocks: appended,
                    totalBlocks: children.count,
                    cause: Self.exportError(from: error)
                )
            }
        }
        return created
    }

    /// Normaliza qualquer erro para o vocabulário do serviço. O cancelamento
    /// entra como caso próprio: `CancellationError` não é `NotionExportError`,
    /// e sem isso o parcial por cancelamento perderia a página.
    private static func exportError(from error: Error) -> NotionExportError {
        if let known = error as? NotionExportError { return known }
        if error is CancellationError { return .cancelled }
        return .requestFailed
    }

    // MARK: - Destino

    private func resolveParent(id: String, token: String, started: Date) async throws -> NotionParent {
        let dashed = NotionDestination.dashedID(id)
        let database = try await send(
            method: "GET",
            path: "/v1/databases/\(dashed)",
            token: token,
            body: nil,
            started: started
        )
        switch database.status {
        case 200:
            let titleKey = Self.titlePropertyName(in: database.json) ?? "title"
            return .database(id: dashed, titleProperty: titleKey)
        case 401:
            throw NotionExportError.invalidToken
        case 403, 404:
            break
        default:
            throw NotionExportError.requestFailed
        }

        let page = try await send(
            method: "GET",
            path: "/v1/pages/\(dashed)",
            token: token,
            body: nil,
            started: started
        )
        switch page.status {
        case 200:
            return .page(id: dashed)
        case 401:
            throw NotionExportError.invalidToken
        case 403, 404:
            throw NotionExportError.destinationNotShared
        default:
            throw NotionExportError.requestFailed
        }
    }

    // MARK: - Páginas

    private func createPage(
        parent: NotionParent,
        title: String,
        children: [[String: Any]],
        token: String,
        started: Date
    ) async throws -> NotionExportResult {
        let response = try await send(
            method: "POST",
            path: "/v1/pages",
            token: token,
            body: [
                "parent": parent.json,
                "properties": parent.titleProperties(title: Self.clipped(title)),
                "children": children
            ],
            started: started
        )
        return try Self.pageResult(from: response)
    }

    private func appendChildren(
        pageID: String,
        children: [[String: Any]],
        token: String,
        started: Date
    ) async throws {
        let response = try await send(
            method: "PATCH",
            path: "/v1/blocks/\(pageID)/children",
            token: token,
            body: ["children": children],
            started: started
        )
        switch response.status {
        case 200:
            return
        case 401:
            throw NotionExportError.invalidToken
        case 403, 404:
            throw NotionExportError.destinationNotShared
        default:
            throw NotionExportError.requestFailed
        }
    }

    // MARK: - HTTP

    private func send(
        method: String,
        path: String,
        token: String,
        body: [String: Any]?,
        started: Date
    ) async throws -> NotionHTTPResponse {
        var lastRetryAfter: Int?
        for attempt in 0...policy.maxRateLimitRetries {
            try Task.checkCancellation()
            try checkDeadline(started: started)

            // O prazo vale para a request INTEIRA, não só para o instante em
            // que ela é admitida. Antes, uma request aceita em t=89 rodava até
            // o timeout de 30 s do URLSession e estourava o prazo total em 30 s:
            // o contrato dizia 90 e a exportação levava 119.
            //
            // O teto vai para o próprio `URLRequest`, que é onde ele é
            // efetivo — cancelar por fora deixaria a conexão em voo.
            let remaining = try remainingDeadline(started: started)
            let response = try await perform(
                method: method,
                path: path,
                token: token,
                body: body,
                timeout: min(Self.requestTimeout, remaining)
            )
            // E confere de novo na volta: request que consumiu o resto do prazo
            // não pode liberar a próxima etapa como se houvesse tempo.
            try checkDeadline(started: started)
            if response.status != 429 {
                return response
            }
            lastRetryAfter = response.retryAfter
            guard attempt < policy.maxRateLimitRetries else { break }

            let requested = TimeInterval(response.retryAfter ?? 1)
            let capped = min(max(0, requested), policy.maxRetryAfterSeconds)
            let leftForSleep = try remainingDeadline(started: started)
            if leftForSleep <= 0 { throw NotionExportError.timedOut }
            try await sleep(min(capped, leftForSleep))
        }
        throw NotionExportError.rateLimited(retryAfterSeconds: lastRetryAfter)
    }

    private func perform(
        method: String,
        path: String,
        token: String,
        body: [String: Any]?,
        timeout: TimeInterval
    ) async throws -> NotionHTTPResponse {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.apiHost
        components.path = path
        guard let url = components.url else { throw NotionExportError.requestFailed }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NotionExportError.requestFailed
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let retry = Self.retryAfterSeconds(from: http)
        return NotionHTTPResponse(status: http.statusCode, json: json, retryAfter: retry)
    }

    private func checkDeadline(started: Date) throws {
        _ = try remainingDeadline(started: started)
    }

    private func remainingDeadline(started: Date) throws -> TimeInterval {
        let left = policy.exportDeadline - now().timeIntervalSince(started)
        if left <= 0 { throw NotionExportError.timedOut }
        return left
    }

    private static func pageResult(from response: NotionHTTPResponse) throws -> NotionExportResult {
        switch response.status {
        case 200, 201:
            let id = (response.json["id"] as? String) ?? ""
            let urlString = (response.json["url"] as? String) ?? ""
            guard let url = URL(string: urlString), !id.isEmpty else {
                throw NotionExportError.requestFailed
            }
            return NotionExportResult(id: id, url: url)
        case 401:
            throw NotionExportError.invalidToken
        case 403, 404:
            throw NotionExportError.destinationNotShared
        default:
            throw NotionExportError.requestFailed
        }
    }

    static func titlePropertyName(in database: [String: Any]) -> String? {
        guard let properties = database["properties"] as? [String: Any] else { return nil }
        for (name, value) in properties {
            if let property = value as? [String: Any], property["type"] as? String == "title" {
                return name
            }
        }
        return nil
    }

    static func retryAfterSeconds(from response: HTTPURLResponse) -> Int? {
        if let raw = response.value(forHTTPHeaderField: "Retry-After"),
           let seconds = Int(raw) {
            return seconds
        }
        return nil
    }

    static func chunked<T>(_ items: [T], size: Int) -> [[T]] {
        guard size > 0, !items.isEmpty else { return items.isEmpty ? [] : [items] }
        var result: [[T]] = []
        var index = 0
        while index < items.count {
            let end = min(index + size, items.count)
            result.append(Array(items[index..<end]))
            index = end
        }
        return result
    }

    static func clipped(_ text: String) -> String {
        if text.count <= maxRichText { return text }
        return String(text.prefix(maxRichText))
    }
}

struct NotionExportResult: Equatable, Sendable {
    var id: String
    var url: URL
}

enum NotionExportError: Error, Equatable, LocalizedError, Sendable {
    /// A página FOI criada no Notion, mas o conteúdo não subiu inteiro.
    ///
    /// Existe porque descartar o `NotionExportResult` quando um append falha
    /// deixa estado órfão do lado de fora: a página fica lá com os primeiros
    /// 100 blocos, o usuário vê um erro genérico sem URL, e um retry cria
    /// OUTRA página. O erro carrega a URL justamente para a UI poder oferecer
    /// "Abrir no Notion" em vez de esconder o que já existe.
    ///
    /// `cause` é o que interrompeu (prazo, cancelamento, 429, falha de rede).
    indirect case partiallyExported(
        page: NotionExportResult,
        appendedBlocks: Int,
        totalBlocks: Int,
        cause: NotionExportError
    )
    /// A exportação foi cancelada antes de criar qualquer coisa.
    case cancelled
    case missingToken
    case missingDestination
    case invalidDestination
    case invalidToken
    case destinationNotShared
    case rateLimited(retryAfterSeconds: Int?)
    case timedOut
    case requestFailed

    var errorDescription: String? {
        switch self {
        case .missingToken:
            String(localized: "Configure o token do Notion em Ajustes.")
        case .missingDestination:
            String(localized: "Informe o URL ou o ID da página ou database do Notion.")
        case .invalidDestination:
            String(localized: "Não reconheci esse destino. Cole o URL ou o ID da página ou database.")
        case .invalidToken:
            String(localized: "Token do Notion inválido. Gere um Internal Integration Token novo em notion.so/my-integrations.")
        case .destinationNotShared:
            String(localized: "A integração não vê esse destino. Abra a página ou database no Notion e compartilhe com a integração.")
        case .rateLimited:
            String(localized: "O Notion pediu para esperar. Tente de novo em alguns segundos.")
        case .timedOut:
            String(localized: "A exportação para o Notion demorou demais.")
        case .requestFailed:
            String(localized: "Não foi possível exportar para o Notion.")
        case .cancelled:
            String(localized: "Exportação para o Notion cancelada.")
        case .partiallyExported(_, let appended, let total, _):
            String(
                localized: "A página foi criada no Notion, mas ficou incompleta (\(appended) de \(total) partes). Exportar de novo cria outra página."
            )
        }
    }

    /// A página que já existe do lado do Notion, quando existe. É o que impede
    /// a UI de tratar uma falha parcial como se nada tivesse sido criado.
    var createdPage: NotionExportResult? {
        if case .partiallyExported(let page, _, _, _) = self { return page }
        return nil
    }
}

enum NotionDestination {
    /// 32 hex minúsculos, ou nil se o texto não é um ID/URL do Notion.
    ///
    /// O ID da página/database vive no **path**. `?v=` é o UUID da view e
    /// nunca entra nesta conta — senão dois GETs 404 viram falso "não compartilhado".
    static func normalizeID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return extractID(from: pathPortion(of: trimmed))
    }

    /// Tudo antes de `?` e `#`. Query/fragment (view, pvs) ficam de fora.
    static func pathPortion(of raw: String) -> String {
        let withoutFragment = raw.split(
            separator: "#",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).first.map(String.init) ?? raw
        return withoutFragment.split(
            separator: "?",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).first.map(String.init) ?? withoutFragment
    }

    static func extractID(from text: String) -> String? {
        let dashed = #"([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})"#
        if let match = lastMatch(dashed, in: text) {
            return match.replacingOccurrences(of: "-", with: "").lowercased()
        }
        let compact = #"([0-9a-fA-F]{32})"#
        if let match = lastMatch(compact, in: text) {
            return match.lowercased()
        }
        return nil
    }

    static func dashedID(_ hex32: String) -> String {
        let s = hex32.lowercased()
        guard s.count == 32 else { return s }
        let chars = Array(s)
        return [
            String(chars[0..<8]),
            String(chars[8..<12]),
            String(chars[12..<16]),
            String(chars[16..<20]),
            String(chars[20..<32])
        ].joined(separator: "-")
    }

    private static func lastMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        guard let match = matches.last, let swiftRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[swiftRange])
    }
}

enum NotionParent: Equatable, Sendable {
    case database(id: String, titleProperty: String)
    case page(id: String)

    var json: [String: Any] {
        switch self {
        case .database(let id, _):
            return ["type": "database_id", "database_id": id]
        case .page(let id):
            return ["type": "page_id", "page_id": id]
        }
    }

    func titleProperties(title: String) -> [String: Any] {
        let titleValue: [String: Any] = [
            "title": [
                ["type": "text", "text": ["content": title]]
            ]
        ]
        switch self {
        case .database(_, let key):
            return [key: titleValue]
        case .page:
            return ["title": titleValue]
        }
    }
}

/// Pacote da reunião em blocos Notion: título, data, participantes, resumo, ações, transcript.
enum NotionPageContent {
    static func title(for session: MeetingSession) -> String {
        let summaryTitle = session.summary?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !summaryTitle.isEmpty { return summaryTitle }
        let sessionTitle = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return sessionTitle.isEmpty ? String(localized: "Reunião") : sessionTitle
    }

    static func children(for session: MeetingSession) -> [[String: Any]] {
        var blocks: [[String: Any]] = []

        var meta = [session.formattedDate, session.sessionType.displayName]
        let duration = durationLabel(session.duration)
        if !duration.isEmpty { meta.append(duration) }
        blocks.append(contentsOf: paragraphs(meta.joined(separator: " · ")))

        let participants = session.speakers.map(\.name)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !participants.isEmpty {
            let label = String(localized: "Participantes")
            blocks.append(contentsOf: paragraphs("\(label): \(participants.joined(separator: ", "))"))
        }

        if let summary = session.summary, summary.hasContent {
            blocks.append(heading(2, String(localized: "Resumo")))
            for section in summary.sections where !section.isEmpty {
                blocks.append(heading(3, section.title))
                switch section.kind {
                case .paragraph:
                    blocks.append(contentsOf: paragraphs(section.paragraph))
                case .bullets:
                    for bullet in section.bullets {
                        let text = bullet.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }
                        blocks.append(contentsOf: listItems(text))
                    }
                case .actionItems:
                    for item in section.actionItems {
                        let text = actionLine(item)
                        guard !text.isEmpty else { continue }
                        blocks.append(contentsOf: toDos(text, checked: item.done))
                    }
                }
            }
        }

        let notes = session.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            blocks.append(heading(2, String(localized: "Notas")))
            blocks.append(contentsOf: paragraphs(notes))
        }

        let spokenTurns = session.turns.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if !spokenTurns.isEmpty {
            blocks.append(heading(2, String(localized: "Transcript")))
            for turn in spokenTurns {
                let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let line = "**\(turn.speakerName)** (\(timeLabel(turn.startTime))): \(text)"
                blocks.append(contentsOf: paragraphs(line))
            }
        }

        return blocks
    }

    // MARK: - Blocos

    private static func heading(_ level: Int, _ text: String) -> [String: Any] {
        let type = level >= 3 ? "heading_3" : (level == 2 ? "heading_2" : "heading_1")
        return [
            "object": "block",
            "type": type,
            type: ["rich_text": richText(clipped(text))]
        ]
    }

    private static func paragraphs(_ text: String) -> [[String: Any]] {
        chunks(of: text.trimmingCharacters(in: .whitespacesAndNewlines)).map { chunk in
            [
                "object": "block",
                "type": "paragraph",
                "paragraph": ["rich_text": richText(chunk)]
            ]
        }
    }

    private static func listItems(_ text: String) -> [[String: Any]] {
        chunks(of: text).map { chunk in
            [
                "object": "block",
                "type": "bulleted_list_item",
                "bulleted_list_item": ["rich_text": richText(chunk)]
            ]
        }
    }

    private static func toDos(_ text: String, checked: Bool) -> [[String: Any]] {
        chunks(of: text).map { chunk in
            [
                "object": "block",
                "type": "to_do",
                "to_do": [
                    "rich_text": richText(chunk),
                    "checked": checked
                ]
            ]
        }
    }

    private static func richText(_ text: String) -> [[String: Any]] {
        [["type": "text", "text": ["content": text]]]
    }

    private static func chunks(of text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var result: [String] = []
        var remainder = trimmed
        while remainder.count > NotionExportService.maxRichText {
            let index = remainder.index(remainder.startIndex, offsetBy: NotionExportService.maxRichText)
            result.append(String(remainder[..<index]))
            remainder = String(remainder[index...])
        }
        if !remainder.isEmpty { result.append(remainder) }
        return result
    }

    private static func clipped(_ text: String) -> String {
        NotionExportService.clipped(text)
    }

    private static func actionLine(_ item: MeetingActionItem) -> String {
        var line = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var tags: [String] = []
        if let assignee = item.assignee?.trimmingCharacters(in: .whitespacesAndNewlines), !assignee.isEmpty {
            tags.append(assignee)
        }
        if let due = item.dueDate?.trimmingCharacters(in: .whitespacesAndNewlines), !due.isEmpty {
            tags.append(due)
        }
        if !tags.isEmpty {
            line += " — " + tags.joined(separator: " · ")
        }
        return line
    }

    private static func durationLabel(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    private static func timeLabel(_ time: TimeInterval) -> String {
        let total = max(0, Int(time))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct NotionHTTPResponse {
    var status: Int
    var json: [String: Any]
    var retryAfter: Int?
}
