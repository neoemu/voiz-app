import Foundation
import Combine
import CryptoKit
import Testing

@MainActor
@Suite("Scheduled meeting preparation")
struct ScheduledMeetingTests {
    @Test("Same calendar event stays isolated across libraries, including a late AI result")
    func workspaceLibraryIsolation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "WorkspaceIsolation." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let initial = root.appendingPathComponent("initial")
        let registry = try SyncLibraryRegistry(baseURL: root.appendingPathComponent("registry"), initialLocalRoot: initial)
        let generation = UUID().uuidString.lowercased()
        let a = try registry.activate(accountID: "account-a", collectionGeneration: generation,
            claimInitialLocalLibrary: true, syncConsentConfirmed: true, hasActiveWork: false)
        let storeA = MeetingWorkspaceStore(context: a, defaults: defaults, initialLocalRoot: initial)
        #expect(storeA.savePreparation(.init(eventID: "one", title: "A", eventDate: .now,
            selectedSessionIDs: [], text: "PRIVATE_A_BRIEFING", generatedAt: .now)))
        #expect(storeA.saveAssistantAnswer(scope: "one", question: "A?", text: "PRIVATE_A_ANSWER", operationID: nil))
        storeA.saveRecipes([MeetingAIRecipe(command: "private-a", title: "A", instruction: "PRIVATE_A_RECIPE")])
        let (starts, started) = AsyncStream<Void>.makeStream()
        var iterator = starts.makeAsyncIterator()
        var resume: CheckedContinuation<String, Never>?
        let modelA = ScheduledMeetingModel(eventID: "one", store: storeA, authorize: { true },
            loadSettings: { AppSettings() }, complete: { _, _ in
                await withCheckedContinuation { resume = $0; started.yield(()) }
            })
        modelA.draft.notes = "PRIVATE_A_NOTES"
        let task = try #require(modelA.ask("A question", event: event("one", start: .now), sessions: []))
        await iterator.next()
        // Deliberately retain an old request even though the runtime normally waits for work.
        let b = try registry.activate(accountID: "account-b", collectionGeneration: generation,
            claimInitialLocalLibrary: false, syncConsentConfirmed: true, hasActiveWork: false)
        let storeB = MeetingWorkspaceStore(context: b, defaults: defaults, initialLocalRoot: initial)
        #expect(storeB.preparations.isEmpty && storeB.scheduledDrafts.isEmpty && storeB.assistantAnswers.isEmpty)
        #expect(!storeB.recipes.contains { $0.command == "private-a" })
        var promptB = ""
        let modelB = ScheduledMeetingModel(eventID: "one", store: storeB, authorize: { true },
            loadSettings: { AppSettings() }, complete: { prompt, _ in promptB = prompt; return "B answer" })
        #expect(modelB.draft.notes.isEmpty)
        let taskB = try #require(modelB.ask("B question", event: event("one", start: .now), sessions: []))
        await taskB.value
        #expect(!promptB.contains("PRIVATE_A") && !promptB.contains("A question"))
        try #require(resume).resume(returning: "Late A answer")
        await task.value
        let reopenedB = MeetingWorkspaceStore(context: b, defaults: defaults, initialLocalRoot: initial)
        #expect(reopenedB.scheduledDrafts["one"]?.messages.map(\.content) == ["B question", "B answer"])
        let returnedA = try registry.activate(accountID: "account-a", collectionGeneration: generation,
            claimInitialLocalLibrary: false, syncConsentConfirmed: true, hasActiveWork: false)
        let reopenedA = MeetingWorkspaceStore(context: returnedA, defaults: defaults, initialLocalRoot: initial)
        #expect(reopenedA.scheduledDrafts["one"]?.notes == "PRIVATE_A_NOTES")
        #expect(reopenedA.scheduledDrafts["one"]?.messages.last?.content == "Late A answer")
        #expect(reopenedA.assistantAnswers["one"]?.text == "PRIVATE_A_ANSWER")
        #expect(reopenedA.preparations["one"]?.text == "PRIVATE_A_BRIEFING")
        started.finish()
    }

    @Test("Only the initial library inherits legacy workspace preferences and file")
    func legacyWorkspaceBelongsOnlyToInitialLibrary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "WorkspaceLegacy." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let legacy = MeetingWorkspaceStore(defaults: defaults)
        var draft = ScheduledMeetingDraft(eventID: "one"); draft.notes = "Legacy notes"
        #expect(legacy.saveScheduledDraft(draft))
        let a = SyncLibraryContext(libraryID: UUID(), ownerAccountID: nil, collectionGeneration: nil, rootURL: root, journal: nil)
        let b = SyncLibraryContext(libraryID: UUID(), ownerAccountID: "other", collectionGeneration: nil, rootURL: root.appendingPathComponent("other"), journal: nil)
        let storeA = MeetingWorkspaceStore(context: a, defaults: defaults, initialLocalRoot: root)
        #expect(storeA.scheduledDrafts["one"]?.notes == "Legacy notes")
        #expect(storeA.saveAssistantAnswer(scope: "one", question: "", text: "Durable original", operationID: nil))
        let oldURL = root.appendingPathComponent(AppEnvironment.current.bundleIdentifier + "/MeetingWorkspace/workspace-v2.json")
        #expect(MeetingWorkspaceStore(defaults: defaults, storageURL: oldURL).assistantAnswers["one"]?.text == "Durable original")
        let storeB = MeetingWorkspaceStore(context: b, defaults: defaults, initialLocalRoot: root)
        #expect(storeB.scheduledDrafts.isEmpty && storeB.assistantAnswers.isEmpty)
        #expect(storeB.saveAssistantAnswer(scope: "one", question: "", text: "Other library", operationID: nil))
        #expect(MeetingWorkspaceStore(context: a, defaults: defaults, initialLocalRoot: root).assistantAnswers["one"]?.text == "Durable original")
        let unavailable = MeetingWorkspaceStore(context: nil, defaults: defaults, initialLocalRoot: root)
        #expect(unavailable.scheduledDrafts.isEmpty)
        #expect(!unavailable.saveScheduledDraft(draft))
        #expect(legacy.scheduledDrafts["one"]?.notes == "Legacy notes")
    }

    @Test("Credential loading reserves a scheduled request; cancellation never reaches AI")
    func credentialWaitCanBeCanceledWithoutCompletion() async throws {
        let suite = "ScheduledMeetingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (starts, started) = AsyncStream<Void>.makeStream()
        var iterator = starts.makeAsyncIterator()
        var resume: CheckedContinuation<AppSettings, any Error>?
        var calls = 0
        let model = ScheduledMeetingModel(eventID: "one", store: MeetingWorkspaceStore(defaults: defaults),
            authorize: { true }, loadSettings: {
                try await withCheckedThrowingContinuation { resume = $0; started.yield(()) }
            }, complete: { _, _ in calls += 1; return "Unexpected" })
        let meeting = event("one", start: .now)
        let first = try #require(model.ask("Preserve question", event: meeting, sessions: []))
        await iterator.next()
        #expect(model.running)
        #expect(model.ask("Duplicate", event: meeting, sessions: []) == nil)
        #expect(calls == 0)
        model.cancel()
        try #require(resume).resume(returning: AppSettings())
        await first.value
        #expect(!model.running && calls == 0)
        #expect(model.draft.messages.map(\.content) == ["Preserve question"])
        started.finish()
    }

    @Test("Unavailable credentials preserve the question and retry uses newly verified settings")
    func credentialFailurePreservesQuestionForRetry() async throws {
        let suite = "ScheduledMeetingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var unavailable = true
        var calls = 0
        let model = ScheduledMeetingModel(eventID: "one", store: MeetingWorkspaceStore(defaults: defaults),
            authorize: { true }, loadSettings: {
                if unavailable { throw SettingsCredentialError.unavailable }
                var settings = AppSettings()
                settings.openAIKey = "SYNTHETIC_READY"
                return settings
            }, complete: { _, settings in
                #expect(settings.openAIKey == "SYNTHETIC_READY")
                calls += 1
                return "Ready answer"
            })
        model.draft.notes = "Keep notes"
        let meeting = event("one", start: .now)
        await model.ask("Keep question", event: meeting, sessions: [])?.value
        #expect(calls == 0 && !model.running && model.error != nil)
        #expect(model.draft.notes == "Keep notes")
        #expect(model.draft.messages.map(\.content) == ["Keep question"])
        unavailable = false
        await model.ask("Keep question", event: meeting, sessions: [])?.value
        #expect(calls == 1 && model.error == nil)
        #expect(model.draft.messages.map(\.content) == ["Keep question", "Ready answer"])
    }

    @Test("Briefing credential failure preserves existing output and never invokes AI")
    func briefingCredentialFailurePreservesWork() async throws {
        let suite = "ScheduledMeetingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = MeetingWorkspaceStore(defaults: defaults)
        var calls = 0
        let model = MeetingPreparationModel(workspace: workspace, authorize: { true },
            loadSettings: { throw SettingsCredentialError.unavailable },
            complete: { _, _ in calls += 1; return "Unexpected" })
        model.text = "Keep briefing"
        let ids: Set<UUID> = [UUID()]
        model.generatedIDs = ids
        await model.generate(event: event("one", start: .now), sessions: [], selectedIDs: ids)?.value
        #expect(calls == 0 && !model.running && model.error != nil)
        #expect(model.text == "Keep briefing" && model.generatedIDs == ids)
        #expect(workspace.preparations.isEmpty)
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        return calendar
    }

    private func event(_ id: String, start: Date, duration: TimeInterval = 3600) -> CalendarEvent {
        CalendarEvent(id: id, title: "Test", startDate: start,
                      endDate: start.addingTimeInterval(duration), hasVideoLink: false)
    }

    @Test("Home lists both tests chronologically and excludes tomorrow and ended meetings")
    func allRemainingEventsToday() throws {
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 12)))
        let first = event("first", start: now.addingTimeInterval(45 * 60))
        let second = event("second", start: now.addingTimeInterval(4 * 3600 + 15 * 60))
        let ended = event("ended", start: now.addingTimeInterval(-3600))
        let tomorrow = event("tomorrow", start: try #require(calendar.date(byAdding: .day, value: 1, to: now)))
        let events = [tomorrow, second, ended, first]
        #expect(CalendarEvent.remainingToday(in: events, now: now, calendar: calendar).map(\.id) == ["first", "second"])
        #expect(CalendarEvent.remainingToday(in: [tomorrow], now: now, calendar: calendar).isEmpty)
        #expect(CalendarEvent.remainingToday(in: events, now: first.endDate, calendar: calendar).map(\.id) == ["second"])
    }

    @Test("Today follows local midnight and retains ongoing overnight meetings")
    func localDayBoundary() throws {
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 23, minute: 30)))
        let midnight = try #require(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)))
        let late = event("late", start: now.addingTimeInterval(15 * 60))
        let nextDay = event("next-day", start: midnight)
        #expect(CalendarEvent.remainingToday(in: [nextDay, late], now: now, calendar: calendar).map(\.id) == ["late"])
        #expect(CalendarEvent.remainingToday(in: [nextDay, late], now: midnight, calendar: calendar).map(\.id) == ["late", "next-day"])
    }

    @Test("Opening an event routes to its preparation and supersedes earlier agenda selection")
    func agendaNavigation() {
        let navigation = VoizNavigation()
        let first = event("first", start: .now)
        let second = event("second", start: .now.addingTimeInterval(3600))
        navigation.open(first)
        #expect(navigation.calendarEvent == first)
        #expect(navigation.requestedTab == VoizSearchKind.meeting.tab)
        #expect(navigation.pendingOpen == nil)
        navigation.open(second)
        #expect(navigation.calendarEvent == second)
        navigation.calendarEvent = nil
        #expect(navigation.calendarEvent == nil)
    }

    @Test("Notes and chat survive reopening, remain per occurrence, and preserve existing briefings")
    func draftPersistence() throws {
        let suiteName = "ScheduledMeetingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MeetingWorkspaceStore(defaults: defaults)
        let briefing = MeetingPreparation(eventID: "one", title: "Planning", eventDate: .now,
            selectedSessionIDs: [UUID()], text: "Existing briefing", generatedAt: .now)
        store.savePreparation(briefing)
        let first = ScheduledMeetingModel(eventID: "one", store: store)
        #expect(store.scheduledDrafts.isEmpty) // Merely opening does not create persisted content.
        first.draft.notes = "Discuss the release"
        first.draft.messages = [ScheduledMeetingMessage(role: .user, content: "What should we discuss?"),
                                ScheduledMeetingMessage(role: .assistant, content: "Review the open questions.")]
        let second = ScheduledMeetingModel(eventID: "two", store: store)
        #expect(second.draft.notes.isEmpty)
        second.draft.notes = "A different occurrence"
        let restored = MeetingWorkspaceStore(defaults: defaults)
        #expect(restored.preparations["one"] == briefing)
        #expect(ScheduledMeetingModel(eventID: "one", store: restored).draft == first.draft)
        #expect(restored.scheduledDrafts["two"]?.notes == "A different occurrence")
    }

    @Test("A double submit and synchronous publication callback create one user turn and one request")
    func reentrantSubmit() async throws {
        let suiteName = "ScheduledMeetingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MeetingWorkspaceStore(defaults: defaults)
        var calls = 0
        let model = ScheduledMeetingModel(eventID: "one", store: store, loadSettings: { AppSettings() }) { _, _ in
            calls += 1
            return "An answer"
        }
        let meeting = event("one", start: .now)
        var reentrantSubmissions = 0
        let subscription = model.$draft.dropFirst().sink { _ in
            if model.ask("Question", event: meeting, sessions: []) != nil { reentrantSubmissions += 1 }
        }
        let task = try #require(model.ask("Question", event: meeting, sessions: []))
        #expect(model.ask("Question", event: meeting, sessions: []) == nil)
        await task.value
        withExtendedLifetime(subscription) {}
        #expect(reentrantSubmissions == 0)
        #expect(calls == 1)
        #expect(model.draft.messages.map(\.role) == [.user, .assistant])
        #expect(!model.running)
    }

    @Test("Retrying a failed question reuses its message and sends the question once")
    func retryFailedQuestion() async throws {
        let suiteName = "ScheduledMeetingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var calls = 0
        var retryPrompt = ""
        let model = ScheduledMeetingModel(eventID: "one", store: MeetingWorkspaceStore(defaults: defaults), loadSettings: { AppSettings() }) { prompt, _ in
            calls += 1
            if calls == 1 { throw NSError(domain: "Test", code: 1) }
            retryPrompt = prompt
            return "Ready"
        }
        let meeting = event("one", start: .now)
        await model.ask("Prepare-my-meeting", event: meeting, sessions: [])?.value
        #expect(model.error != nil)
        let messageID = try #require(model.draft.messages.first?.id)
        await model.ask("Prepare-my-meeting", event: meeting, sessions: [])?.value
        #expect(model.error == nil)
        #expect(model.draft.messages.map(\.role) == [.user, .assistant])
        #expect(model.draft.messages.first?.id == messageID)
        #expect(retryPrompt.components(separatedBy: "Prepare-my-meeting").count == 2)
    }

    @Test("Cancellation and immediate retry ignore late replies without unlocking the new request")
    func canceledReplyCannotFinishRetry() async throws {
        let suiteName = "ScheduledMeetingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var completions: [CheckedContinuation<String, any Error>] = []
        let (starts, started) = AsyncStream<Void>.makeStream()
        var iterator = starts.makeAsyncIterator()
        let model = ScheduledMeetingModel(eventID: "one", store: MeetingWorkspaceStore(defaults: defaults), loadSettings: { AppSettings() }) { _, _ in
            try await withCheckedThrowingContinuation { continuation in
                completions.append(continuation)
                started.yield(())
            }
        }
        let meeting = event("one", start: .now)
        let first = try #require(model.ask("Question", event: meeting, sessions: []))
        await iterator.next()
        model.cancel()
        let second = try #require(model.ask("Question", event: meeting, sessions: []))
        await iterator.next()
        completions[0].resume(returning: "Stale answer")
        await first.value
        #expect(model.running)
        #expect(model.draft.messages.count == 1)
        completions[1].resume(returning: "Current answer")
        await second.value
        #expect(!model.running)
        #expect(model.draft.messages.map(\.content) == ["Question", "Current answer"])
        started.finish()
    }

    @Test("Opening an older draft repairs adjacent unanswered duplicates and preserves later repetitions")
    func repairExistingDuplicates() throws {
        let suiteName = "ScheduledMeetingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MeetingWorkspaceStore(defaults: defaults)
        let first = ScheduledMeetingMessage(role: .user, content: "Question")
        let reply = ScheduledMeetingMessage(role: .assistant, content: "Answer")
        let later = ScheduledMeetingMessage(role: .user, content: "Question")
        store.saveScheduledDraft(ScheduledMeetingDraft(eventID: "one", notes: "Keep my notes", messages: [
            first, ScheduledMeetingMessage(role: .user, content: "Question"), reply, later
        ]))
        let model = ScheduledMeetingModel(eventID: "one", store: store)
        #expect(model.draft.messages.map(\.id) == [first.id, reply.id, later.id])
        #expect(model.draft.notes == "Keep my notes")
        #expect(MeetingWorkspaceStore(defaults: defaults).scheduledDrafts["one"] == model.draft)
    }

    @Test("Context saves before generating a briefing and removed sources never enter a new question")
    func contextBeforeBriefing() async throws {
        let suiteName = "ScheduledMeetingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MeetingWorkspaceStore(defaults: defaults)
        let old = MeetingSession(title: "REMOVED-SOURCE")
        let new = MeetingSession(title: "SELECTED-SOURCE")
        store.savePreparation(.init(eventID: "one", title: "Planning", eventDate: .now,
            selectedSessionIDs: [old.id], text: "STALE-BRIEFING", generatedAt: .now))
        var sent = ""
        let model = ScheduledMeetingModel(eventID: "one", store: store, loadSettings: { AppSettings() }) { prompt, _ in sent = prompt; return "Ready" }
        #expect(model.selectedSessionIDs == [old.id])
        model.setContext([new.id])
        #expect(MeetingWorkspaceStore(defaults: defaults).scheduledDrafts["one"]?.contextSessionIDs == [new.id])
        await model.ask("Prepare", event: event("one", start: .now), sessions: [old, new])?.value
        #expect(sent.contains("SELECTED-SOURCE"))
        #expect(!sent.contains("REMOVED-SOURCE"))
        #expect(!sent.contains("STALE-BRIEFING"))
        #expect(model.draft.messages.last?.sourceSessionIDs == [new.id])
        model.setContext([])
        #expect(ScheduledMeetingModel(eventID: "one", store: MeetingWorkspaceStore(defaults: defaults)).selectedSessionIDs.isEmpty)
        model.setContext(Set((0..<9).map { _ in UUID() }))
        #expect(model.selectedSessionIDs.isEmpty)
    }

    @Test("Authorization waiting reserves one request without recording work or changing history")
    func suspendedAuthorizationCannotStartCanceledRequest() async throws {
        let suiteName = "ScheduledMeetingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tracker = VoizWorkTracker()
        var approvals: [CheckedContinuation<Bool, Never>] = []
        let (starts, started) = AsyncStream<Void>.makeStream()
        var iterator = starts.makeAsyncIterator()
        var prompts: [String] = []
        let model = ScheduledMeetingModel(eventID: "one", store: MeetingWorkspaceStore(defaults: defaults),
            workTracker: tracker, authorize: {
                await withCheckedContinuation { continuation in
                    approvals.append(continuation)
                    started.yield(())
                }
            }, loadSettings: { AppSettings() }, complete: { prompt, _ in
                #expect(tracker.hasActiveWork)
                prompts.append(prompt)
                return "Current answer"
            })
        let meeting = event("one", start: .now)
        let first = try #require(model.ask("Canceled question", event: meeting, sessions: []))
        await iterator.next()
        #expect(model.running)
        #expect(!tracker.hasActiveWork)
        #expect(model.draft.messages.isEmpty)
        #expect(model.ask("Duplicate", event: meeting, sessions: []) == nil)
        model.cancel()
        let second = try #require(model.ask("Current question", event: meeting, sessions: []))
        await iterator.next()
        approvals[0].resume(returning: true)
        await first.value
        #expect(model.running)
        #expect(prompts.isEmpty)
        #expect(model.draft.messages.isEmpty)
        #expect(!tracker.hasActiveWork)
        approvals[1].resume(returning: true)
        await second.value
        #expect(prompts.count == 1)
        #expect(model.draft.messages.map(\.content) == ["Current question", "Current answer"])
        #expect(!model.running)
        #expect(!tracker.hasActiveWork)
        started.finish()
    }

    @Test("Denied authorization preserves existing notes and chat without invoking AI")
    func deniedAuthorizationPreservesDraft() async throws {
        let suiteName = "ScheduledMeetingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tracker = VoizWorkTracker()
        var calls = 0
        let model = ScheduledMeetingModel(eventID: "one", store: MeetingWorkspaceStore(defaults: defaults),
            workTracker: tracker, authorize: { false }, loadSettings: { AppSettings() }, complete: { _, _ in calls += 1; return "Unexpected" })
        model.draft.notes = "Keep my notes"
        model.draft.messages = [ScheduledMeetingMessage(role: .assistant, content: "Keep my answer")]
        let before = model.draft
        await model.ask("New question", event: event("one", start: .now), sessions: [])?.value
        #expect(model.draft == before)
        #expect(calls == 0)
        #expect(model.error != nil)
        #expect(!model.running)
        #expect(!tracker.hasActiveWork)
    }

    @Test("Unavailable storage preserves admitted work and blocks the next request")
    func unavailableStorageLetsAdmittedWorkFinish() async throws {
        let suiteName = "ScheduledMeetingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let workspace = MeetingWorkspaceStore(defaults: defaults)
        let tracker = VoizWorkTracker()
        var libraryAvailable = true

        var response: CheckedContinuation<String, Never>?
        let (starts, started) = AsyncStream<Void>.makeStream()
        var iterator = starts.makeAsyncIterator()
        var completions = 0
        let model = ScheduledMeetingModel(eventID: "one", store: workspace, workTracker: tracker,
            authorize: { libraryAvailable }, loadSettings: { AppSettings() }, complete: { _, _ in
                completions += 1
                return await withCheckedContinuation { continuation in
                    response = continuation
                    started.yield(())
                }
            })
        model.draft.notes = "Synthetic notes to preserve"
        let meeting = event("one", start: .now)
        let admitted = try #require(model.ask("First question", event: meeting, sessions: []))
        await iterator.next()
        #expect(model.running && tracker.hasActiveWork)

        libraryAvailable = false
        #expect(model.running && tracker.hasActiveWork)
        try #require(response).resume(returning: "Admitted answer")
        await admitted.value
        #expect(model.draft.messages.map(\.content) == ["First question", "Admitted answer"])
        #expect(model.draft.notes == "Synthetic notes to preserve")
        #expect(!model.running && !tracker.hasActiveWork)

        let completedDraft = model.draft
        await model.ask("Blocked question", event: meeting, sessions: [])?.value
        #expect(completions == 1)
        #expect(model.draft == completedDraft)
        #expect(MeetingWorkspaceStore(defaults: defaults).scheduledDrafts["one"] == completedDraft)
        #expect(model.error != nil)
        #expect(!model.running && !tracker.hasActiveWork)
        started.finish()
    }

}
