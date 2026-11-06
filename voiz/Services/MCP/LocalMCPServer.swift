import Combine
import Foundation
@preconcurrency import Network

/// Servidor Streamable HTTP local do Voiz.
///
/// - escuta exclusivamente em 127.0.0.1;
/// - fica desligado até consentimento explícito;
/// - exige Bearer de 256 bits guardado no Keychain;
/// - rejeita Origin e Host inesperados (DNS rebinding/browser-to-localhost);
/// - compartilha o `MeetingSessionStore` vivo da UI, sem criar uma cópia stale.
@MainActor
final class LocalMCPServer: ObservableObject {
    static let shared = LocalMCPServer()
    static let port: UInt16 = AppEnvironment.current.localMCPPort
    static let endpointPath = "/mcp"

    enum Status: Equatable {
        case disabled
        case waitingForMeetingStore
        case starting
        case running
        case failed(String)
    }

    @Published private(set) var isEnabled: Bool
    @Published private(set) var status: Status
    @Published private(set) var lastRequestAt: Date?
    @Published private(set) var credentialRevision = 0

    var connectionURL: String {
        "http://127.0.0.1:\(Self.port)\(Self.endpointPath)"
    }

    /// Comando em escopo de usuário do Claude Code. Evita `.mcp.json`, que é configuração de
    /// projeto projetada para versionamento e não deve receber uma capability estática.
    var claudeCodeConfiguration: String? {
        guard let token = currentToken() else { return nil }
        return "claude mcp add --transport http \(AppEnvironment.current.mcpServerName) --scope user \(connectionURL) "
            + "--header \"Authorization: Bearer \(token)\""
    }

    var genericConfiguration: String? {
        guard let token = currentToken() else { return nil }
        return "URL: \(connectionURL)\nAuthorization: Bearer \(token)"
    }

    private static let enabledKey = "voiz.mcp.local.enabled"
    private static let maximumClients = 16
    /// Prazo absoluto, não um timeout de ociosidade. Um peer local não autenticado não pode
    /// conservar um dos slots enviando bytes lentamente para sempre (slowloris).
    private static let clientReadDeadline: Duration = .seconds(10)
    private static let clientProcessingTimeout: Duration = .seconds(30)
    private static let clientWriteTimeout: Duration = .seconds(10)
    private static let requestBurst = 20
    private static let requestRefillRate = 5.0
    private static let credentialLookupBurst = 20
    private static let credentialLookupRefillRate = 5.0

    // O singleton mantém a fonte viva mesmo quando a última janela é fechada. Não há ciclo: o
    // store não referencia o servidor, e um novo ContentView substitui esta referência no attach.
    private var meetingStore: MeetingSessionStore?
    private var meetingStoreSubscription: AnyCancellable?
    private var cachedMeetingSnapshot: MCPMeetingSnapshot?
    private var snapshotGeneration: UInt64 = 0
    private var activeToolClientID: UUID?
    private var listener: NWListener?
    private var stoppingListener: NWListener?
    private var shouldStartAfterCancellation = false
    private var clients: [UUID: HTTPClient] = [:]
    private var credentialLookupLimiter: MCPTokenBucket
    private var requestLimiter: MCPTokenBucket

    private init(defaults: UserDefaults = .standard) {
        let enabled = defaults.bool(forKey: Self.enabledKey)
        self.isEnabled = enabled
        self.status = enabled ? .waitingForMeetingStore : .disabled
        self.credentialLookupLimiter = MCPTokenBucket(
            capacity: Self.credentialLookupBurst,
            refillRatePerSecond: Self.credentialLookupRefillRate,
            now: ProcessInfo.processInfo.systemUptime
        )
        self.requestLimiter = MCPTokenBucket(
            capacity: Self.requestBurst,
            refillRatePerSecond: Self.requestRefillRate,
            now: ProcessInfo.processInfo.systemUptime
        )
    }

    /// Conecta a fonte canônica. Chamar de novo é seguro (previews/recriação de ContentView).
    func attach(to store: MeetingSessionStore) {
        if meetingStore !== store {
            meetingStore = store
            meetingStoreSubscription?.cancel()
            invalidateMeetingSnapshot()
            meetingStoreSubscription = store.objectWillChange.sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.invalidateMeetingSnapshot()
                }
            }
        }
        if isEnabled { start() }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else {
            if enabled, listener == nil { start() }
            return
        }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled {
            start()
        } else {
            shouldStartAfterCancellation = false
            stopListener(statusAfterStop: .disabled)
        }
    }

    func retry() {
        guard isEnabled else { return }
        if listener != nil {
            shouldStartAfterCancellation = true
            stopListener(statusAfterStop: .starting)
        } else {
            start()
        }
    }

    /// Revoga imediatamente configurações copiadas anteriormente.
    func rotateCredential() {
        guard MCPCredentialsStore.shared.rotateToken() != nil else {
            // O write pode ter sido concluído antes de um readback ambíguo. Parar o listener
            // mantém o servidor fail-closed até um retry conseguir reler o slot canônico.
            shouldStartAfterCancellation = false
            stopListener(
                statusAfterStop: .failed(
                    String(localized: "Não foi possível salvar a nova credencial no Keychain.")
                )
            )
            return
        }
        credentialRevision += 1
        credentialLookupLimiter.reset(now: ProcessInfo.processInfo.systemUptime)
        requestLimiter.reset(now: ProcessInfo.processInfo.systemUptime)
        cancelAllClients()
    }

    private func start() {
        guard isEnabled else {
            status = .disabled
            return
        }
        guard listener == nil else { return }
        guard stoppingListener == nil else {
            shouldStartAfterCancellation = true
            status = .starting
            return
        }
        guard meetingStore != nil else {
            status = .waitingForMeetingStore
            return
        }
        guard currentToken() != nil else {
            status = .failed(String(localized: "Não foi possível salvar a credencial MCP no Keychain."))
            return
        }
        lastRequestAt = nil
        status = .starting

        do {
            let port = try requirePort()
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
            parameters.acceptLocalOnly = true

            // Não use `NWListener(using:on:)` aqui: o port já está no requiredLocalEndpoint e o
            // overload com `on:` tenta sobrescrevê-lo, falhando com EINVAL no macOS.
            let newListener = try NWListener(using: parameters)
            listener = newListener

            newListener.stateUpdateHandler = { [weak self, weak newListener] state in
                MainActor.assumeIsolated {
                    guard let self, self.listener === newListener else { return }
                    switch state {
                    case .ready:
                        self.credentialLookupLimiter.reset(
                            now: ProcessInfo.processInfo.systemUptime
                        )
                        self.requestLimiter.reset(now: ProcessInfo.processInfo.systemUptime)
                        self.status = .running
                    case .failed(let error):
                        self.shouldStartAfterCancellation = false
                        self.stopListener(
                            statusAfterStop: .failed(Self.safeMessage(for: error))
                        )
                    default:
                        break
                    }
                }
            }
            newListener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            newListener.start(queue: .main)
        } catch {
            listener = nil
            status = .failed(Self.safeMessage(for: error))
        }
    }

    private func stopListener(statusAfterStop: Status) {
        guard let oldListener = listener else {
            status = statusAfterStop
            return
        }

        listener = nil
        stoppingListener = oldListener
        oldListener.newConnectionHandler = nil
        cancelAllClients()
        invalidateMeetingSnapshot()
        status = statusAfterStop

        // O kernel só libera a porta depois de `.cancelled`. Aguardar esse estado evita uma
        // corrida EADDRINUSE ao tentar novamente ou ao desligar/ligar rapidamente.
        oldListener.stateUpdateHandler = { [weak self, weak oldListener] state in
            guard case .cancelled = state else { return }
            MainActor.assumeIsolated {
                guard let self, let oldListener, self.stoppingListener === oldListener else { return }
                oldListener.stateUpdateHandler = nil
                self.stoppingListener = nil
                let shouldRestart = self.shouldStartAfterCancellation && self.isEnabled
                self.shouldStartAfterCancellation = false
                if shouldRestart { self.start() }
            }
        }
        oldListener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        guard isEnabled, listener != nil else {
            connection.cancel()
            return
        }
        guard clients.count < Self.maximumClients else {
            connection.cancel()
            return
        }
        let id = UUID()
        let client = HTTPClient(connection: connection)
        clients[id] = client
        armTimeout(for: id, after: Self.clientReadDeadline)
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                MainActor.assumeIsolated { self?.removeClient(id) }
            } else if case .cancelled = state {
                MainActor.assumeIsolated { self?.removeClient(id) }
            }
        }
        connection.start(queue: .main)
        receive(from: id)
    }

    private func receive(from id: UUID) {
        guard let client = clients[id] else { return }
        client.connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1_024
        ) { [weak self] content, _, isComplete, error in
            MainActor.assumeIsolated {
                self?.received(content, isComplete: isComplete, error: error, from: id)
            }
        }
    }

    private func received(_ content: Data?, isComplete: Bool, error: NWError?, from id: UUID) {
        guard let client = clients[id], client.phase == .reading else { return }
        if let content, !content.isEmpty {
            client.buffer.append(content)
        }
        if error != nil {
            client.connection.cancel()
            removeClient(id)
            return
        }
        if client.buffer.count > MCPHTTPTransport.maximumRequestBytes
            + MCPHTTPTransport.maximumHeaderBytes {
            send(
                MCPHTTPTransport.errorResponse(
                    MCPHTTPFailure(status: 413, message: "Request too large")
                ),
                to: id
            )
            return
        }

        switch MCPHTTPTransport.parseRequest(client.buffer) {
        case .incomplete:
            if isComplete {
                send(
                    MCPHTTPTransport.errorResponse(
                        MCPHTTPFailure(status: 400, message: "Incomplete request")
                    ),
                    to: id
                )
            } else {
                receive(from: id)
            }
        case .failure(let failure):
            send(MCPHTTPTransport.errorResponse(failure), to: id)
        case .request(let request):
            client.phase = .processing
            armTimeout(for: id, after: Self.clientProcessingTimeout)
            handle(request, clientID: id)
        }
    }

    private func handle(_ request: MCPHTTPRequest, clientID: UUID) {
        if let failure = MCPHTTPTransport.validateRequestPolicy(
            request,
            endpointPath: Self.endpointPath,
            port: Self.port,
            supportedProtocolVersions: MCPProtocolHandler.supportedProtocolVersions
        ) {
            send(MCPHTTPTransport.errorResponse(failure), to: clientID)
            return
        }

        // Só requests estruturalmente válidos chegam ao IPC do Keychain. Um segundo bucket limita
        // tentativas sem credencial, evitando que um processo local transforme a validação por
        // request (necessária para revogação entre instâncias) em carga ilimitada no Securityd.
        if let retryAfter = credentialLookupLimiter.retryAfter(
            now: ProcessInfo.processInfo.systemUptime
        ) {
            send(
                MCPHTTPTransport.errorResponse(
                    MCPHTTPFailure(
                        status: 429,
                        message: "Too many authentication attempts",
                        extraHeaders: ["Retry-After": String(max(1, Int(ceil(retryAfter))))]
                    )
                ),
                to: clientID
            )
            return
        }

        let authenticationTask = Task.detached(priority: .utility) { [weak self, request] in
            guard !Task.isCancelled else { return }
            let token = MCPCredentialsStore.shared.token() ?? ""
            guard !Task.isCancelled else { return }
            let failure = MCPHTTPTransport.validateAuthorization(
                request,
                expectedBearerToken: token
            )
            guard !Task.isCancelled else { return }
            await self?.finishAuthentication(
                failure,
                request: request,
                clientID: clientID
            )
        }
        clients[clientID]?.processingTask = authenticationTask
    }

    private func finishAuthentication(
        _ failure: MCPHTTPFailure?,
        request: MCPHTTPRequest,
        clientID: UUID
    ) {
        guard let client = clients[clientID], client.phase == .processing else { return }
        client.processingTask = nil
        if let failure {
            send(MCPHTTPTransport.errorResponse(failure), to: clientID)
            return
        }
        guard meetingStore != nil else {
            send(
                MCPHTTPTransport.errorResponse(
                    MCPHTTPFailure(status: 503, message: "Meeting store unavailable")
                ),
                to: clientID
            )
            return
        }

        if let retryAfter = requestLimiter.retryAfter(now: ProcessInfo.processInfo.systemUptime) {
            send(
                MCPHTTPTransport.errorResponse(
                    MCPHTTPFailure(
                        status: 429,
                        message: "Too many requests",
                        extraHeaders: ["Retry-After": String(max(1, Int(ceil(retryAfter))))]
                    )
                ),
                to: clientID
            )
            return
        }

        lastRequestAt = Date()
        let requestBody = request.body
        let processingTask = Task.detached(priority: .utility) { [weak self, requestBody] in
            guard !Task.isCancelled else { return }
            let preflight = MCPProtocolHandler.preflight(requestBody)
            guard !Task.isCancelled else { return }
            await self?.finishPreflight(
                preflight,
                requestBody: requestBody,
                clientID: clientID
            )
        }
        clients[clientID]?.processingTask = processingTask
    }

    private func finishPreflight(
        _ preflight: MCPProtocolPreflight,
        requestBody: Data,
        clientID: UUID
    ) {
        guard let client = clients[clientID], client.phase == .processing else { return }
        // A task de preflight já entregou seu resultado ao MainActor.
        client.processingTask = nil

        switch preflight {
        case .response(let response):
            finishProcessing(MCPHTTPTransport.response(for: response), clientID: clientID)
        case .requiresMeetingSnapshot:
            // Um único snapshot/scan pesado por vez. Handshake, ping e tools/list não passam por
            // este gate e continuam baratos mesmo enquanto uma busca longa está em andamento.
            guard activeToolClientID == nil else {
                finishProcessing(
                    MCPHTTPTransport.errorResponse(
                        MCPHTTPFailure(
                            status: 429,
                            message: "Another meeting query is still processing",
                            extraHeaders: ["Retry-After": "1"]
                        )
                    ),
                    clientID: clientID
                )
                return
            }
            activeToolClientID = clientID
            startToolProcessing(requestBody: requestBody, clientID: clientID)
        }
    }

    private func startToolProcessing(requestBody: Data, clientID: UUID) {
        guard let client = clients[clientID], client.phase == .processing else { return }
        let snapshotTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            guard let snapshot = await self.meetingSnapshotForTools() else {
                guard !Task.isCancelled else { return }
                self.finishProcessing(
                    MCPHTTPTransport.errorResponse(
                        MCPHTTPFailure(status: 503, message: "Meeting history changed; retry")
                    ),
                    clientID: clientID
                )
                return
            }
            guard !Task.isCancelled else { return }
            self.runToolRequest(
                requestBody: requestBody,
                snapshot: snapshot,
                clientID: clientID
            )
        }
        client.processingTask = snapshotTask
    }

    private func runToolRequest(
        requestBody: Data,
        snapshot: MCPMeetingSnapshot,
        clientID: UUID
    ) {
        guard let client = clients[clientID], client.phase == .processing,
              activeToolClientID == clientID else { return }
        // A task de captura está terminando; a partir daqui o trabalho é Sendable/utility.
        client.processingTask = nil
        let processingTask = Task.detached(priority: .utility) { [weak self, snapshot, requestBody] in
            guard !Task.isCancelled else { return }
            let response = MCPProtocolHandler(snapshot: snapshot).handle(requestBody)
            guard !Task.isCancelled else { return }
            let encodedResponse = MCPHTTPTransport.response(for: response)
            guard !Task.isCancelled else { return }
            await self?.finishProcessing(encodedResponse, clientID: clientID)
        }
        client.processingTask = processingTask
    }

    private func finishProcessing(_ data: Data, clientID: UUID) {
        guard let client = clients[clientID], client.phase == .processing else { return }
        // A própria tarefa acabou; remover o handle antes de iniciar a escrita evita cancelá-la
        // a partir do callback que ela acabou de entregar ao MainActor.
        client.processingTask = nil
        if activeToolClientID == clientID { activeToolClientID = nil }
        send(data, to: clientID)
    }

    private func send(_ data: Data, to id: UUID) {
        guard let client = clients[id] else { return }
        client.phase = .writing
        client.processingTask?.cancel()
        client.processingTask = nil
        // Backpressure também precisa de prazo: um peer que pare de ler não pode manter um dos
        // slots e o completion handler vivos indefinidamente.
        armTimeout(for: id, after: Self.clientWriteTimeout)
        client.connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated { self?.closeClient(id, cancelConnection: true) }
        })
    }

    private func armTimeout(for id: UUID, after duration: Duration) {
        guard let client = clients[id] else { return }
        client.timeoutTask?.cancel()
        client.timeoutGeneration &+= 1
        let generation = client.timeoutGeneration
        client.timeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            // Cancelar depois do deadline, mas antes da continuação retomar no MainActor, pode
            // fazer `sleep` retornar normalmente. A flag e a geração impedem que um timer antigo
            // encerre uma fase mais nova do mesmo cliente.
            guard !Task.isCancelled else { return }
            self?.timeoutClient(id, generation: generation)
        }
    }

    private func cancelAllClients() {
        let activeClients = Array(clients.values)
        clients.removeAll()
        activeToolClientID = nil
        for client in activeClients {
            client.timeoutTask?.cancel()
            client.timeoutTask = nil
            client.processingTask?.cancel()
            client.processingTask = nil
            client.connection.cancel()
        }
    }

    private func removeClient(_ id: UUID) {
        closeClient(id, cancelConnection: false)
    }

    private func closeClient(_ id: UUID, cancelConnection: Bool) {
        guard let client = clients.removeValue(forKey: id) else { return }
        if activeToolClientID == id { activeToolClientID = nil }
        client.timeoutTask?.cancel()
        client.timeoutTask = nil
        client.processingTask?.cancel()
        client.processingTask = nil
        if cancelConnection { client.connection.cancel() }
    }

    private func timeoutClient(_ id: UUID, generation: UInt64) {
        guard clients[id]?.timeoutGeneration == generation else { return }
        closeClient(id, cancelConnection: true)
    }

    private func invalidateMeetingSnapshot() {
        snapshotGeneration &+= 1
        cachedMeetingSnapshot = nil
    }

    /// Reutiliza a mesma allowlist enquanto o store não muda. A captura cooperativa é única e
    /// cede o MainActor em lotes; `objectWillChange` cancela/invalida antes da próxima consulta.
    private func meetingSnapshotForTools() async -> MCPMeetingSnapshot? {
        if let cachedMeetingSnapshot { return cachedMeetingSnapshot }
        guard let meetingStore else { return nil }

        let generation = snapshotGeneration
        // Arrays de structs têm copy-on-write: esta leitura fixa a versão de origem antes de a
        // captura começar a ceder o actor.
        let sessions = meetingStore.sessions
        let folders = meetingStore.folders
        do {
            // A captura roda na própria task rastreada pelo HTTPClient. Timeout, disconnect,
            // stop e rotação cancelam o trabalho real, não apenas uma task externa que o aguarda.
            let snapshot = try await MCPMeetingSnapshot.capture(
                sessions: sessions,
                folders: folders,
                isCurrent: { [weak self] in
                    self?.snapshotGeneration == generation
                }
            )
            try Task.checkCancellation()
            guard generation == snapshotGeneration else { return nil }
            // `duration` de uma sessão aberta depende de Date() e avança mesmo sem publicação do
            // store. Não cachear durante gravação mantém duration_seconds atual a cada consulta.
            if !snapshot.sessions.contains(where: { $0.endedAt == nil }) {
                cachedMeetingSnapshot = snapshot
            }
            return snapshot
        } catch {
            return nil
        }
    }

    private func currentToken() -> String? {
        // Não cachear no processo: outra instância do Voiz pode rotacionar a credencial. Cada
        // request/configuração consulta o slot canônico, revogando o token antigo imediatamente.
        MCPCredentialsStore.shared.token()
    }

    private func requirePort() throws -> NWEndpoint.Port {
        guard let port = NWEndpoint.Port(rawValue: Self.port) else {
            throw MCPServerError.invalidPort
        }
        return port
    }

    private static func safeMessage(for error: Error) -> String {
        if let nwError = error as? NWError {
            switch nwError {
            case .posix(let code) where code == .EADDRINUSE:
                return String(localized: "A porta local \(Self.port) já está em uso. Feche o outro serviço e tente novamente.")
            default:
                return String(localized: "Não foi possível iniciar o servidor MCP local.")
            }
        }
        return String(localized: "Não foi possível iniciar o servidor MCP local.")
    }

    private final class HTTPClient {
        enum Phase {
            case reading
            case processing
            case writing
        }

        let connection: NWConnection
        var buffer = Data()
        var phase = Phase.reading
        var timeoutGeneration: UInt64 = 0
        var timeoutTask: Task<Void, Never>?
        var processingTask: Task<Void, Never>?

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    private enum MCPServerError: Error {
        case invalidPort
    }
}
