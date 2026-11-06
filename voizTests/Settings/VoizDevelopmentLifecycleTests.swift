import Foundation
import Testing

@Suite("Voiz Dev — encerramento seguro")
@MainActor
struct VoizDevelopmentLifecycleTests {
    private func makeDevelopmentLifecycle(workTracker: VoizWorkTracker? = nil) -> VoizDevelopmentLifecycle {
        VoizDevelopmentLifecycle(environment: AppEnvironment(bundleIdentifier: "com.rmb.voiz.dev"), workTracker: workTracker)
    }

    @Test("Encerrar só é liberado quando a operação termina")
    func followsCurrentActivityState() {
        let lifecycle = makeDevelopmentLifecycle()
        let operation = DevelopmentActivity()
        lifecycle.registerActivity(id: UUID()) { [weak operation] in operation?.isActive }

        #expect(!lifecycle.hasActiveWork)
        operation.isActive = true
        #expect(lifecycle.hasActiveWork)
        operation.isActive = false
        #expect(!lifecycle.hasActiveWork)
    }

    @Test("Fechar uma janela não retém seu dono nem deixa verificações expiradas")
    func expiresWeakOwnersAndPrunesTheirChecks() {
        let lifecycle = makeDevelopmentLifecycle()
        var operation: DevelopmentActivity? = DevelopmentActivity(isActive: true)
        weak var owner = operation
        var evaluations = 0
        lifecycle.registerActivity(id: UUID()) { [weak operation] in
            evaluations += 1
            return operation?.isActive
        }

        #expect(lifecycle.hasActiveWork)
        #expect(evaluations == 1)
        operation = nil
        #expect(owner == nil)
        #expect(!lifecycle.hasActiveWork)
        #expect(evaluations == 2)
        #expect(!lifecycle.hasActiveWork)
        #expect(evaluations == 2)
    }

    @Test("Concluir uma operação mantém a proteção enquanto outra segue ativa")
    func waitsForAllOperations() {
        let lifecycle = makeDevelopmentLifecycle()
        let recording = DevelopmentActivity(isActive: true)
        let response = DevelopmentActivity(isActive: true)
        lifecycle.registerActivity(id: UUID()) { [weak recording] in recording?.isActive }
        lifecycle.registerActivity(id: UUID()) { [weak response] in response?.isActive }

        #expect(lifecycle.hasActiveWork)
        recording.isActive = false
        #expect(lifecycle.hasActiveWork)
        response.isActive = false
        #expect(!lifecycle.hasActiveWork)
        recording.isActive = true
        #expect(lifecycle.hasActiveWork)
    }

    @Test("Escopos independentes protegem o trabalho até a última conclusão")
    func scopedOperationsFinishIndependently() {
        let workTracker = VoizWorkTracker()
        let lifecycle = makeDevelopmentLifecycle(workTracker: workTracker)
        let first = workTracker.beginActivity()
        let second = workTracker.beginActivity()
        #expect(lifecycle.hasActiveWork)
        first.finish()
        #expect(lifecycle.hasActiveWork)
        second.finish()
        #expect(!lifecycle.hasActiveWork)
    }

    @Test("Escopos não retêm donos e preservam o encerramento normal da produção")
    func scopedOperationsAreWeakAndPreserveProductionQuit() {
        let workTracker = VoizWorkTracker()
        let lifecycle = makeDevelopmentLifecycle(workTracker: workTracker)
        var activity: VoizWorkActivity? = workTracker.beginActivity()
        weak var owner = activity
        #expect(lifecycle.hasActiveWork)
        activity = nil
        #expect(owner == nil)
        #expect(!lifecycle.hasActiveWork)

        let production = VoizDevelopmentLifecycle(environment: AppEnvironment(bundleIdentifier: "com.rmb.voiz"), workTracker: workTracker)
        let productionActivity = workTracker.beginActivity()
        #expect(workTracker.hasActiveWork) // Updates still wait in production; normal app quit does not.
        #expect(!production.hasActiveWork)
        productionActivity.finish()
        #expect(!production.hasActiveWork)
    }

    @Test("Pergunta agendada bloqueia saída até concluir ou falhar", arguments: [false, true])
    func scheduledQuestionProtectsItsAsyncLifetime(fails: Bool) async throws {
        let suite = "VoizDevelopmentLifecycleTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let workTracker = VoizWorkTracker()
        let lifecycle = makeDevelopmentLifecycle(workTracker: workTracker)
        var completion: CheckedContinuation<String, any Error>?
        let (starts, started) = AsyncStream<Void>.makeStream()
        var iterator = starts.makeAsyncIterator()
        let model = ScheduledMeetingModel(eventID: "synthetic", store: MeetingWorkspaceStore(defaults: defaults),
                                          workTracker: workTracker, loadSettings: { AppSettings() }) { _, _ in
            try await withCheckedThrowingContinuation { continuation in
                completion = continuation
                started.yield(())
            }
        }
        let event = CalendarEvent(id: "synthetic", title: "Test", startDate: .now,
                                  endDate: .now.addingTimeInterval(60), hasVideoLink: false)
        let request = try #require(model.ask("Synthetic question", event: event, sessions: []))
        // Authorization waiting has not admitted AI work or blocked a normal quit.
        #expect(!lifecycle.hasActiveWork)
        await iterator.next()
        #expect(lifecycle.hasActiveWork)
        let continuation = try #require(completion)
        if fails { continuation.resume(throwing: NSError(domain: "Synthetic", code: 1)) }
        else { continuation.resume(returning: "Synthetic answer") }
        await request.value
        #expect(!model.running)
        #expect(!lifecycle.hasActiveWork)
        #expect((model.error != nil) == fails)
    }

    @Test("Cancelar e tentar novamente protege ambos os pedidos até cada um terminar")
    func canceledRequestCannotUnlockItsReplacement() async throws {
        let suite = "VoizDevelopmentLifecycleTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let workTracker = VoizWorkTracker()
        let lifecycle = makeDevelopmentLifecycle(workTracker: workTracker)
        var completions: [CheckedContinuation<String, any Error>] = []
        let (starts, started) = AsyncStream<Void>.makeStream()
        var iterator = starts.makeAsyncIterator()
        let model = ScheduledMeetingModel(eventID: "synthetic", store: MeetingWorkspaceStore(defaults: defaults),
                                          workTracker: workTracker, loadSettings: { AppSettings() }) { _, _ in
            try await withCheckedThrowingContinuation { continuation in
                completions.append(continuation)
                started.yield(())
            }
        }
        let event = CalendarEvent(id: "synthetic", title: "Test", startDate: .now,
                                  endDate: .now.addingTimeInterval(60), hasVideoLink: false)
        let first = try #require(model.ask("Synthetic question", event: event, sessions: []))
        await iterator.next()
        model.cancel()
        #expect(!model.running)
        #expect(lifecycle.hasActiveWork) // Cancellation has been requested, but has not unwound yet.
        let second = try #require(model.ask("Synthetic question", event: event, sessions: []))
        await iterator.next()
        completions[0].resume(returning: "Stale answer")
        await first.value
        #expect(lifecycle.hasActiveWork)
        #expect(model.running)
        completions[1].resume(returning: "Current answer")
        await second.value
        #expect(!lifecycle.hasActiveWork)
        #expect(model.draft.messages.last?.content == "Current answer")
    }

    @Test("Atualização aguarda uma tarefa mesmo após liberar o dono da janela")
    func updateProtectionOutlivesWindowOwner() async {
        let workTracker = VoizWorkTracker()
        let officialQuit = VoizDevelopmentLifecycle(
            environment: AppEnvironment(bundleIdentifier: "com.rmb.voiz"), workTracker: workTracker
        )
        var window: SyntheticWindowOwner? = SyntheticWindowOwner(activity: workTracker.beginActivity())
        weak var windowReference = window
        let activity = window!.activity
        let (completion, finish) = AsyncStream<Void>.makeStream()
        let request = Task {
            defer { activity.finish() }
            for await _ in completion { break }
        }
        window = nil
        #expect(windowReference == nil)
        #expect(workTracker.hasActiveWork)
        #expect(!officialQuit.hasActiveWork)
        finish.yield(())
        finish.finish()
        await request.value
        #expect(!workTracker.hasActiveWork)
    }

    @Test("Build oficial não registra nem avalia atividades do guard Dev")
    func leavesProductionUnchanged() {
        let lifecycle = VoizDevelopmentLifecycle(environment: AppEnvironment(bundleIdentifier: "com.rmb.voiz"))
        var operation: DevelopmentActivity? = DevelopmentActivity(isActive: true)
        weak var owner = operation
        var evaluations = 0
        // A strong capture exposes accidental registration: production must discard this closure.
        lifecycle.registerActivity(id: UUID()) { [operation] in
            evaluations += 1
            return operation?.isActive
        }
        operation = nil

        #expect(owner == nil)
        #expect(!lifecycle.hasActiveWork)
        #expect(evaluations == 0)
    }
}

@MainActor
private final class DevelopmentActivity {
    var isActive: Bool

    init(isActive: Bool = false) {
        self.isActive = isActive
    }
}

@MainActor
private final class SyntheticWindowOwner {
    let activity: VoizWorkActivity

    init(activity: VoizWorkActivity) { self.activity = activity }
}
