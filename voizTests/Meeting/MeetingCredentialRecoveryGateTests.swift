import Foundation
import Testing

@MainActor
private final class RecoveryReadinessLatch {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func read() async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            observer?.resume()
            observer = nil
        }
    }

    func waitUntilReadStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { observer = $0 }
    }

    func complete(_ ready: Bool) {
        continuation?.resume(returning: ready)
        continuation = nil
    }
}

@MainActor
private final class RecoveryClaimRegistry {
    var inFlight: Set<UUID> = []
}

/// Exercise actual owner destruction without constructing recording services or reading meetings.
@MainActor
private final class RecoveryQueueOwner {
    let registry: RecoveryClaimRegistry
    var queue: [UUID] = []

    init(registry: RecoveryClaimRegistry, candidates: [UUID]) {
        self.registry = registry
        for candidate in candidates {
            if MeetingRecordingLifecycle.claimingPostProcessing(candidate, inFlight: &registry.inFlight) {
                queue.append(candidate)
            }
        }
    }

    isolated deinit {
        MeetingCredentialRecoveryGate.releaseQueuedClaims(queue, current: nil, inFlight: &registry.inFlight)
    }
}

@Suite("Recovery — aguarda credenciais sem perder sessões pendentes")
@MainActor
struct MeetingCredentialRecoveryGateTests {
    @Test("Snapshot do resumo mantém provedor/modelo e recebe somente as cinco chaves verificadas")
    func followupPreferencesKeepProviderWhileHydratingKeys() async throws {
        var original = AppSettings.fullyCustomizedForTests
        original.customBaseURL = "https://synthetic.invalid/chosen-endpoint"
        original.customModel = "chosen-model"
        var verified = AppSettings()
        verified.openAIKey = "SYNTHETIC_FRESH_OPENAI"
        verified.anthropicKey = "SYNTHETIC_FRESH_ANTHROPIC"
        verified.xaiKey = "SYNTHETIC_FRESH_XAI"
        verified.geminiKey = "SYNTHETIC_FRESH_GEMINI"
        verified.customKey = "SYNTHETIC_FRESH_CUSTOM"
        let hydrated = try await MeetingCredentialRecoveryGate.settingsForAI(preferences: original) { verified }
        var expected = original
        expected.openAIKey = verified.openAIKey
        expected.anthropicKey = verified.anthropicKey
        expected.xaiKey = verified.xaiKey
        expected.geminiKey = verified.geminiKey
        expected.customKey = verified.customKey
        #expect(hydrated == expected)
        #expect(hydrated.translationProvider == original.translationProvider)
        #expect(hydrated.customBaseURL == original.customBaseURL)
        #expect(hydrated.customModel == original.customModel)
    }

    @Test("Falha real de storage não consome pergunta nem autoriza fábrica de IA; retry preserva a intenção")
    func unavailableStoragePreservesAIInputUntilRetry() async throws {
        let suite = "voiz-tests-meeting-ai-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = MockSettingsCredentialsStore(record: SettingsCredentialRecord(values: [.openAIKey: "SYNTHETIC_READY"]))
        backend.failReads = true
        let store = SettingsStore(defaults: defaults, credentials: backend)
        var question = "Synthetic pending question"
        var factories = 0
        func authorizeQuestion() async throws {
            let settings = try await MeetingCredentialRecoveryGate.settingsForAI {
                try await store.settingsForCredentialUse()
            }
            #expect(settings.openAIKey == "SYNTHETIC_READY")
            question = ""
            factories += 1
        }
        do {
            try await authorizeQuestion()
            Issue.record("Unavailable credentials unexpectedly allowed AI")
        } catch { #expect(error is SettingsCredentialError) }
        #expect(question == "Synthetic pending question")
        #expect(factories == 0)
        backend.failReads = false
        try await authorizeQuestion()
        #expect(question.isEmpty)
        #expect(factories == 1)
    }

    @Test("Fechar o dono de recuperação pausada libera a reserva para a próxima janela")
    func destroyedPausedOwnerAllowsImmediateRecoveryHandoff() async {
        let queued = UUID(), foreign = UUID()
        let registry = RecoveryClaimRegistry()
        registry.inFlight.insert(foreign)
        var owner: RecoveryQueueOwner? = RecoveryQueueOwner(registry: registry, candidates: [queued, foreign])
        weak var previousOwner = owner
        #expect(owner?.queue == [queued])
        var processed = false
        let result = await MeetingCredentialRecoveryGate.runNext(
            loadCredentials: { false },
            takeNext: { owner?.queue.removeFirst() },
            process: { _ in processed = true }
        )
        #expect(!result)
        #expect(!processed)
        #expect(registry.inFlight == [queued, foreign])
        owner = nil
        #expect(previousOwner == nil)
        // No task/yield is allowed between destruction and another window's claim.
        #expect(registry.inFlight == [foreign])
        let replacement = RecoveryQueueOwner(registry: registry, candidates: [queued, foreign])
        #expect(replacement.queue == [queued])
        #expect(registry.inFlight == [queued, foreign])
        withExtendedLifetime(replacement) {}
    }

    @Test("Cleanup só libera fila própria, preservando trabalho ativo e de outra instância")
    func queuedCleanupNeverReleasesOtherWork() {
        let queued = UUID(), active = UUID(), foreign = UUID()
        var claims: Set<UUID> = [queued, active, foreign]
        MeetingCredentialRecoveryGate.releaseQueuedClaims([queued, queued, active], current: active, inFlight: &claims)
        #expect(claims == [active, foreign])
        MeetingCredentialRecoveryGate.releaseQueuedClaims([queued], current: nil, inFlight: &claims)
        #expect(claims == [active, foreign])
    }

    @Test("Leitura lenta não consome fila; erro preserva sessão e retry executa uma vez")
    func delayedReadFailureAndRetry() async {
        let identifier = UUID()
        var queue = [identifier]
        var completed: [UUID] = []
        let latch = RecoveryReadinessLatch()
        let attempt = Task {
            await MeetingCredentialRecoveryGate.runNext(
                loadCredentials: { await latch.read() },
                takeNext: { queue.isEmpty ? nil : queue.removeFirst() },
                process: { completed.append($0) }
            )
        }
        await latch.waitUntilReadStarted()
        #expect(queue == [identifier])
        #expect(completed.isEmpty)
        latch.complete(false)
        #expect(await attempt.value == false)
        #expect(queue == [identifier])
        #expect(completed.isEmpty)
        let retried = await MeetingCredentialRecoveryGate.runNext(
            loadCredentials: { true }, takeNext: { queue.isEmpty ? nil : queue.removeFirst() },
            process: { completed.append($0) }
        )
        #expect(retried)
        #expect(queue.isEmpty)
        #expect(completed == [identifier])
        let duplicateWake = await MeetingCredentialRecoveryGate.runNext(
            loadCredentials: { true }, takeNext: { queue.isEmpty ? nil : queue.removeFirst() },
            process: { completed.append($0) }
        )
        #expect(!duplicateWake)
        #expect(completed == [identifier])
    }

    @Test("Cancelamento durante leitura conserva a sessão mesmo com credenciais válidas")
    func cancellationDoesNotDequeue() async {
        let identifier = UUID()
        var queue = [identifier]
        var completed = false
        let latch = RecoveryReadinessLatch()
        let attempt = Task {
            await MeetingCredentialRecoveryGate.runNext(
                loadCredentials: { await latch.read() }, takeNext: { queue.removeFirst() },
                process: { _ in completed = true }
            )
        }
        await latch.waitUntilReadStarted()
        attempt.cancel()
        latch.complete(true)
        #expect(await attempt.value == false)
        #expect(queue == [identifier])
        #expect(!completed)
    }

    @Test("Fila pausada não bloqueia saída, mas outros trabalhos ativos continuam protegidos")
    func waitingRecoveryDoesNotPermanentlyBlockQuit() {
        let queued = UUID(), manual = UUID()
        #expect(!MeetingCredentialRecoveryGate.hasActiveWork(
            processingIDs: [queued], queuedIDs: [queued], waitingForCredentials: true))
        #expect(MeetingCredentialRecoveryGate.hasActiveWork(
            processingIDs: [queued, manual], queuedIDs: [queued], waitingForCredentials: true))
        #expect(MeetingCredentialRecoveryGate.hasActiveWork(
            processingIDs: [queued], queuedIDs: [queued], waitingForCredentials: false))
    }

    @Test("Readiness pertence ao cache injetado, exige leitura confirmada e permite retry")
    func storeReadinessDistinguishesEmptyFromError() async throws {
        let suite = "voiz-tests-recovery-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = MockSettingsCredentialsStore(record: SettingsCredentialRecord(values: [.openAIKey: "SYNTHETIC_READY"]))
        let store = SettingsStore(defaults: defaults, credentials: backend)
        let other = SettingsStore(defaults: defaults, credentials: MockSettingsCredentialsStore())
        #expect(!store.credentialsAreReady)
        #expect(store.load().openAIKey.isEmpty)
        backend.failReads = true
        #expect(await store.loadCredentialsForWork() == false)
        #expect(!store.credentialsAreReady)
        backend.failReads = false
        #expect(await store.loadCredentialsForWork())
        #expect(store.load().openAIKey == "SYNTHETIC_READY")
        let readCount = backend.readCount
        #expect(await store.loadCredentialsForWork())
        #expect(backend.readCount == readCount)
        #expect(!other.credentialsAreReady)
        #expect(await other.loadCredentialsForWork()) // Confirmed absence is a valid empty vault.
        #expect(other.load().openAIKey.isEmpty)
        backend.failReads = true
        _ = store.reloadCredentials()
        #expect(!store.credentialsAreReady)
        #expect(store.load().openAIKey == "SYNTHETIC_READY")
    }
}
