import Foundation
import Testing

@Suite("MCP local — transporte HTTP e política de acesso")
struct MCPHTTPTransportTests {
    private let token = "test-token-with-enough-entropy"

    @Test("POST completo é parseado e preserva apenas o path")
    func parsesCompletePOST() throws {
        let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
        let data = requestData(
            method: "POST",
            target: "/mcp?client=test",
            headers: validHeaders,
            body: body
        )

        guard case .request(let request) = MCPHTTPTransport.parseRequest(data) else {
            Issue.record("Expected a parsed request")
            return
        }
        #expect(request.method == "POST")
        #expect(request.path == "/mcp")
        #expect(request.body == body)
        #expect(MCPHTTPTransport.validate(
            request,
            endpointPath: "/mcp",
            port: 39_761,
            expectedBearerToken: token,
            supportedProtocolVersions: MCPProtocolHandler.supportedProtocolVersions,
            serviceAvailable: true
        ) == nil)
    }

    @Test("GET sem Content-Length alcança a política e recebe 405")
    func getWithoutContentLengthIsMethodNotAllowed() throws {
        let data = Data("GET /mcp HTTP/1.1\r\nHost: 127.0.0.1:39761\r\n\r\n".utf8)
        guard case .request(let request) = MCPHTTPTransport.parseRequest(data) else {
            Issue.record("GET should be parsed before method validation")
            return
        }
        let failure = try #require(MCPHTTPTransport.validate(
            request,
            endpointPath: "/mcp",
            port: 39_761,
            expectedBearerToken: token,
            supportedProtocolVersions: MCPProtocolHandler.supportedProtocolVersions,
            serviceAvailable: true
        ))
        #expect(failure.status == 405)
        #expect(failure.extraHeaders["Allow"] == "POST")
    }

    @Test("Host, Origin, media type, Bearer e disponibilidade falham fechados")
    func accessPolicy() throws {
        let base = parsedRequest(headers: validHeaders)
        #expect(validate(base)?.status == nil)

        #expect(validate(parsedRequest(headers: replacing("Host", with: "evil.example")))?.status == 403)
        #expect(validate(parsedRequest(headers: validHeaders.merging(["Origin": "https://evil.example"]) { _, new in new }))?.status == 403)
        #expect(validate(parsedRequest(headers: replacing("Content-Type", with: "text/plain")))?.status == 415)
        #expect(validate(parsedRequest(headers: replacing("Content-Type", with: "application/json-malicious")))?.status == 415)
        #expect(validate(parsedRequest(headers: replacing("Authorization", with: "Bearer wrong")))?.status == 401)
        #expect(validate(parsedRequest(headers: validHeaders.filter { $0.key != "Authorization" }))?.status == 401)
        #expect(validate(parsedRequest(headers: validHeaders.merging(["MCP-Protocol-Version": "1900-01-01"]) { _, new in new }))?.status == 400)
        #expect(validate(base, serviceAvailable: false)?.status == 503)

        let browserGET = MCPHTTPRequest(
            method: "GET",
            path: "/mcp",
            headers: ["host": "127.0.0.1:39761", "origin": "https://evil.example"],
            body: Data()
        )
        #expect(validate(browserGET)?.status == 403)

        let wrongPath = MCPHTTPRequest(
            method: base.method,
            path: "/other",
            headers: base.headers,
            body: base.body
        )
        #expect(validate(wrongPath)?.status == 404)
    }

    @Test("Política barata precede autenticação e mantém as falhas separadas")
    func structuralPolicyPrecedesAuthentication() throws {
        let wrongBearer = parsedRequest(
            headers: replacing("Authorization", with: "Bearer wrong")
        )
        #expect(MCPHTTPTransport.validateRequestPolicy(
            wrongBearer,
            endpointPath: "/mcp",
            port: 39_761,
            supportedProtocolVersions: MCPProtocolHandler.supportedProtocolVersions
        ) == nil)
        #expect(MCPHTTPTransport.validateAuthorization(
            wrongBearer,
            expectedBearerToken: token
        )?.status == 401)

        let browserRequest = parsedRequest(
            headers: validHeaders.merging(["Origin": "https://evil.example"]) { _, new in new }
        )
        #expect(MCPHTTPTransport.validateRequestPolicy(
            browserRequest,
            endpointPath: "/mcp",
            port: 39_761,
            supportedProtocolVersions: MCPProtocolHandler.supportedProtocolVersions
        )?.status == 403)
    }

    @Test("Parser rejeita framing ambíguo, headers inválidos e excesso")
    func parserFailures() {
        expectFailure("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", status: 411)
        expectFailure("POST /mcp HTTP/1.1\r\nHost: one\r\nHost: two\r\nContent-Length: 0\r\n\r\n", status: 400)
        expectFailure("POST /mcp HTTP/1.1\r\nHost : one\r\nContent-Length: 0\r\n\r\n", status: 400)
        expectFailure("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Length: 0\r\n\r\n", status: 400)
        expectFailure("POST /mcp HTTP/1.1\r\nContent-Length: +1\r\n\r\n", status: 400)
        expectFailure("POST /mcp HTTP/1.9\r\nContent-Length: 0\r\n\r\n", status: 400)
        expectFailure("POST /mcp HTTP/2.0\r\nContent-Length: 0\r\n\r\n", status: 400)
        expectFailure("POST /mcp HTTP/1.1\r\nContent-Length: 262145\r\n\r\n", status: 413)
        expectFailure("POST /mcp HTTP/1.1\r\nContent-Length: 0\r\n\r\nextra", status: 400)

        let partial = Data("POST /mcp HTTP/1.1\r\nContent-Length: 10\r\n\r\n{}".utf8)
        guard case .incomplete = MCPHTTPTransport.parseRequest(partial) else {
            Issue.record("Expected an incomplete body")
            return
        }
    }

    @Test("Respostas sempre desativam cache e sniffing; 202 fica sem body")
    func responseSecurityHeaders() {
        let accepted = String(decoding: MCPHTTPTransport.response(for: .accepted), as: UTF8.self)
        #expect(accepted.hasPrefix("HTTP/1.1 202 Accepted\r\n"))
        #expect(accepted.contains("Cache-Control: no-store\r\n"))
        #expect(accepted.contains("Content-Length: 0\r\n"))
        #expect(accepted.contains("X-Content-Type-Options: nosniff\r\n"))
        #expect(!accepted.contains("Content-Type:"))

        let unauthorized = String(
            decoding: MCPHTTPTransport.errorResponse(
                MCPHTTPFailure(
                    status: 401,
                    message: "Unauthorized",
                    extraHeaders: ["WWW-Authenticate": "Bearer realm=\"voiz-local\""]
                )
            ),
            as: UTF8.self
        )
        #expect(unauthorized.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
        #expect(unauthorized.contains("Content-Type: application/json\r\n"))
        #expect(unauthorized.contains("WWW-Authenticate: Bearer realm=\"voiz-local\"\r\n"))
        #expect(unauthorized.hasSuffix(#"{"error":"Unauthorized"}"#))
    }

    @Test("Token bucket permite rajada, limita e se recompõe pelo relógio monotônico")
    func tokenBucketRateLimit() throws {
        var bucket = MCPTokenBucket(capacity: 2, refillRatePerSecond: 2, now: 100)

        #expect(bucket.retryAfter(now: 100) == nil)
        #expect(bucket.retryAfter(now: 100) == nil)
        let firstRetry = bucket.retryAfter(now: 100)
        let firstDelay = try #require(firstRetry)
        #expect(abs(firstDelay - 0.5) < 0.000_001)

        #expect(bucket.retryAfter(now: 100.5) == nil)
        let secondRetry = bucket.retryAfter(now: 99)
        let secondDelay = try #require(secondRetry)
        #expect(abs(secondDelay - 0.5) < 0.000_001)

        bucket.reset(now: 200)
        #expect(bucket.retryAfter(now: 200) == nil)
        #expect(bucket.retryAfter(now: 200) == nil)
    }

    @Test("429 inclui Retry-After e mantém os headers de segurança")
    func rateLimitResponse() {
        let response = String(
            decoding: MCPHTTPTransport.errorResponse(
                MCPHTTPFailure(
                    status: 429,
                    message: "Too many requests",
                    extraHeaders: ["Retry-After": "1"]
                )
            ),
            as: UTF8.self
        )
        #expect(response.hasPrefix("HTTP/1.1 429 Too Many Requests\r\n"))
        #expect(response.contains("Retry-After: 1\r\n"))
        #expect(response.contains("Cache-Control: no-store\r\n"))
    }

    // MARK: - Helpers

    private var validHeaders: [String: String] {
        [
            "Host": "127.0.0.1:39761",
            "Content-Type": "application/json; charset=utf-8",
            "Authorization": "Bearer \(token)"
        ]
    }

    private func replacing(_ key: String, with value: String) -> [String: String] {
        var headers = validHeaders
        headers[key] = value
        return headers
    }

    private func requestData(
        method: String,
        target: String,
        headers: [String: String],
        body: Data
    ) -> Data {
        var lines = ["\(method) \(target) HTTP/1.1"]
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            lines.append("\(name): \(value)")
        }
        lines.append("Content-Length: \(body.count)")
        var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        data.append(body)
        return data
    }

    private func parsedRequest(headers: [String: String]) -> MCPHTTPRequest {
        let data = requestData(method: "POST", target: "/mcp", headers: headers, body: Data("{}".utf8))
        guard case .request(let request) = MCPHTTPTransport.parseRequest(data) else {
            preconditionFailure("Test fixture must be a valid HTTP request")
        }
        return request
    }

    private func validate(
        _ request: MCPHTTPRequest,
        serviceAvailable: Bool = true
    ) -> MCPHTTPFailure? {
        MCPHTTPTransport.validate(
            request,
            endpointPath: "/mcp",
            port: 39_761,
            expectedBearerToken: token,
            supportedProtocolVersions: MCPProtocolHandler.supportedProtocolVersions,
            serviceAvailable: serviceAvailable
        )
    }

    private func expectFailure(_ raw: String, status: Int) {
        guard case .failure(let failure) = MCPHTTPTransport.parseRequest(Data(raw.utf8)) else {
            Issue.record("Expected HTTP failure \(status)")
            return
        }
        #expect(failure.status == status)
    }
}
