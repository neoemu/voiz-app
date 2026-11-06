import Foundation

/// Request HTTP mínimo aceito pelo transporte MCP local. Não há keep-alive nem pipelining: cada
/// conexão carrega exatamente um request e é fechada após a resposta.
nonisolated struct MCPHTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

nonisolated struct MCPHTTPFailure: Equatable, Sendable {
    let status: Int
    let message: String
    let extraHeaders: [String: String]

    init(status: Int, message: String, extraHeaders: [String: String] = [:]) {
        self.status = status
        self.message = message
        self.extraHeaders = extraHeaders
    }
}

nonisolated enum MCPHTTPRequestParseResult: Sendable {
    case incomplete
    case request(MCPHTTPRequest)
    case failure(MCPHTTPFailure)
}

/// Token bucket pequeno e determinístico. O servidor mantém uma instância por capability ativa,
/// permitindo uma rajada curta de handshake/paginação sem deixar um cliente autenticado ocupar
/// indefinidamente o processo da UI.
nonisolated struct MCPTokenBucket: Sendable {
    private let capacity: Double
    private let refillRatePerSecond: Double
    private var tokens: Double
    private var lastRefill: TimeInterval

    init(capacity: Int, refillRatePerSecond: Double, now: TimeInterval) {
        precondition(capacity > 0 && refillRatePerSecond > 0)
        self.capacity = Double(capacity)
        self.refillRatePerSecond = refillRatePerSecond
        self.tokens = Double(capacity)
        self.lastRefill = now
    }

    /// Consome uma unidade ou devolve quantos segundos faltam para a próxima. O relógio pode
    /// recuar em testes/suspensão sem criar tokens extras.
    mutating func retryAfter(now: TimeInterval) -> TimeInterval? {
        let elapsed = max(0, now - lastRefill)
        tokens = min(capacity, tokens + elapsed * refillRatePerSecond)
        lastRefill = max(lastRefill, now)

        guard tokens >= 1 else {
            return (1 - tokens) / refillRatePerSecond
        }
        tokens -= 1
        return nil
    }

    mutating func reset(now: TimeInterval) {
        tokens = capacity
        lastRefill = now
    }
}

/// Codec e política de acesso puros, compartilhados pelo listener e pelos testes. Manter esta
/// camada fora de `NWListener` permite provar que requests de browser, DNS rebinding e tokens
/// incorretos são recusados sem precisar abrir uma porta em cada teste.
nonisolated enum MCPHTTPTransport {
    static let maximumRequestBytes = 262_144
    static let maximumHeaderBytes = 65_536

    static func parseRequest(_ data: Data) -> MCPHTTPRequestParseResult {
        let delimiter = Data([13, 10, 13, 10])
        guard let headerRange = data.range(of: delimiter) else {
            return data.count > maximumHeaderBytes
                ? .failure(MCPHTTPFailure(status: 431, message: "Headers too large"))
                : .incomplete
        }
        guard headerRange.lowerBound <= maximumHeaderBytes,
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            return .failure(MCPHTTPFailure(status: 400, message: "Invalid headers"))
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .failure(MCPHTTPFailure(status: 400, message: "Missing request line"))
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2] == "HTTP/1.1" else {
            return .failure(MCPHTTPFailure(status: 400, message: "Invalid request line"))
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                return .failure(MCPHTTPFailure(status: 400, message: "Invalid header"))
            }
            let rawName = line[..<colon]
            guard !rawName.isEmpty,
                  rawName.allSatisfy(isHTTPHeaderNameCharacter) else {
                return .failure(MCPHTTPFailure(status: 400, message: "Invalid header name"))
            }
            let name = rawName.lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard headers[name] == nil else {
                return .failure(MCPHTTPFailure(status: 400, message: "Duplicate header"))
            }
            headers[name] = value
        }
        guard headers["transfer-encoding"] == nil else {
            return .failure(MCPHTTPFailure(status: 400, message: "Transfer-Encoding is not supported"))
        }

        let method = String(parts[0])
        let contentLength: Int
        if let rawLength = headers["content-length"] {
            guard !rawLength.isEmpty,
                  rawLength.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let parsedLength = Int(rawLength) else {
                return .failure(MCPHTTPFailure(status: 400, message: "Invalid Content-Length"))
            }
            contentLength = parsedLength
        } else if method == "POST" {
            return .failure(MCPHTTPFailure(status: 411, message: "Content-Length is required"))
        } else {
            // GET de Streamable HTTP costuma chegar sem corpo. A política abaixo devolve 405
            // quando o servidor não implementa o canal SSE opcional.
            contentLength = 0
        }
        guard contentLength <= maximumRequestBytes else {
            return .failure(MCPHTTPFailure(status: 413, message: "Request too large"))
        }

        let bodyStart = headerRange.upperBound
        let expectedEnd = bodyStart + contentLength
        guard data.count >= expectedEnd else { return .incomplete }
        guard data.count == expectedEnd else {
            return .failure(MCPHTTPFailure(status: 400, message: "Pipelined requests are not supported"))
        }

        let rawTarget = String(parts[1])
        let path = rawTarget.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? rawTarget
        return .request(
            MCPHTTPRequest(
                method: method,
                path: path,
                headers: headers,
                body: Data(data[bodyStart..<expectedEnd])
            )
        )
    }

    static func validate(
        _ request: MCPHTTPRequest,
        endpointPath: String,
        port: UInt16,
        expectedBearerToken: String,
        supportedProtocolVersions: Set<String>,
        serviceAvailable: Bool
    ) -> MCPHTTPFailure? {
        if let failure = validateRequestPolicy(
            request,
            endpointPath: endpointPath,
            port: port,
            supportedProtocolVersions: supportedProtocolVersions
        ) {
            return failure
        }
        if let failure = validateAuthorization(
            request,
            expectedBearerToken: expectedBearerToken
        ) {
            return failure
        }
        guard serviceAvailable else {
            return MCPHTTPFailure(status: 503, message: "Meeting store unavailable")
        }
        return nil
    }

    /// Política puramente estrutural, executada antes de qualquer IPC com o Keychain. Requests
    /// de browser, Host/path inválidos e tipos incompatíveis são descartados sem trabalho caro.
    static func validateRequestPolicy(
        _ request: MCPHTTPRequest,
        endpointPath: String,
        port: UInt16,
        supportedProtocolVersions: Set<String>
    ) -> MCPHTTPFailure? {
        let host = request.headers["host"]
        guard host == "127.0.0.1:\(port)" || host == "127.0.0.1" else {
            return MCPHTTPFailure(status: 403, message: "Invalid Host")
        }
        // Um cliente MCP nativo não envia Origin. Rejeitá-lo impede páginas web de transformar o
        // navegador numa ponte até localhost, inclusive quando conhecem a porta e a URL.
        guard request.headers["origin"] == nil else {
            return MCPHTTPFailure(status: 403, message: "Browser origins are not allowed")
        }
        if let protocolVersion = request.headers["mcp-protocol-version"],
           !supportedProtocolVersions.contains(protocolVersion) {
            return MCPHTTPFailure(status: 400, message: "Unsupported MCP-Protocol-Version")
        }
        guard request.method == "POST" else {
            return MCPHTTPFailure(
                status: 405,
                message: "Only POST is supported",
                extraHeaders: ["Allow": "POST"]
            )
        }
        guard request.path == endpointPath else {
            return MCPHTTPFailure(status: 404, message: "Not found")
        }
        let mediaType = request.headers["content-type"]?
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard mediaType == "application/json" else {
            return MCPHTTPFailure(status: 415, message: "Content-Type must be application/json")
        }
        return nil
    }

    static func validateAuthorization(
        _ request: MCPHTTPRequest,
        expectedBearerToken: String
    ) -> MCPHTTPFailure? {
        guard let authorization = request.headers["authorization"],
              authorization.hasPrefix("Bearer "),
              !expectedBearerToken.isEmpty,
              constantTimeEqual(String(authorization.dropFirst(7)), expectedBearerToken) else {
            return MCPHTTPFailure(
                status: 401,
                message: "Unauthorized",
                extraHeaders: ["WWW-Authenticate": "Bearer realm=\"voiz-local\""]
            )
        }
        return nil
    }

    static func response(for response: MCPProtocolResponse) -> Data {
        let body = response.body ?? Data()
        var headers: [String: String] = securityHeaders(contentLength: body.count)
        if response.body != nil { headers["Content-Type"] = "application/json" }
        return encodeHTTP(
            status: response.statusCode,
            reason: reasonPhrase(response.statusCode),
            headers: headers,
            body: body
        )
    }

    static func errorResponse(_ failure: MCPHTTPFailure) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: ["error": failure.message]))
            ?? Data(#"{"error":"Request failed"}"#.utf8)
        var headers = failure.extraHeaders
        for (name, value) in securityHeaders(contentLength: body.count) { headers[name] = value }
        headers["Content-Type"] = "application/json"
        return encodeHTTP(
            status: failure.status,
            reason: reasonPhrase(failure.status),
            headers: headers,
            body: body
        )
    }

    private static func securityHeaders(contentLength: Int) -> [String: String] {
        [
            "Cache-Control": "no-store",
            "Connection": "close",
            "Content-Length": String(contentLength),
            "X-Content-Type-Options": "nosniff"
        ]
    }

    private static func encodeHTTP(
        status: Int,
        reason: String,
        headers: [String: String],
        body: Data
    ) -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        var result = Data(head.utf8)
        result.append(body)
        return result
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = left.count ^ right.count
        for index in 0..<min(left.count, right.count) {
            difference |= Int(left[index] ^ right[index])
        }
        return difference == 0
    }

    nonisolated private static func isHTTPHeaderNameCharacter(_ character: Character) -> Bool {
        character.isASCII && (
            character.isLetter
                || character.isNumber
                || "!#$%&'*+-.^_`|~".contains(character)
        )
    }

    private static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 503: return "Service Unavailable"
        default: return "Error"
        }
    }
}
