import Foundation

/// Shared by update postponement and Dev quit protection; it never starts Sparkle or changes quit policy.
/// Weak checks/scopes stay registered when a window closes without keeping view models alive.
@MainActor
final class VoizWorkTracker {
    static let shared = VoizWorkTracker()
    private var activityChecks: [UUID: () -> Bool?] = [:]

    func registerActivity(id: UUID, check: @escaping () -> Bool?) {
        activityChecks[id] = check
    }

    /// The task owns this scope until its completion/cancellation has actually unwound.
    func beginActivity() -> VoizWorkActivity {
        let id = UUID()
        let activity = VoizWorkActivity { [weak self] in self?.activityChecks.removeValue(forKey: id) }
        registerActivity(id: id) { [weak activity] in activity?.isActive }
        return activity
    }

    var hasActiveWork: Bool {
        var expiredIDs: [UUID] = []
        var active = false
        for (id, check) in activityChecks {
            guard let isActive = check() else {
                expiredIDs.append(id)
                continue
            }
            active = active || isActive
        }
        for id in expiredIDs { activityChecks.removeValue(forKey: id) }
        return active
    }
}

@MainActor
final class VoizWorkActivity {
    fileprivate private(set) var isActive = true
    private let onFinish: () -> Void

    fileprivate init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

    func finish() {
        guard isActive else { return }
        isActive = false
        onFinish()
    }
}

/// The official app keeps its normal quit behavior; only the Dev delegate consults this policy.
@MainActor
final class VoizDevelopmentLifecycle {
    static let shared = VoizDevelopmentLifecycle(workTracker: .shared)
    private let environment: AppEnvironment
    private let workTracker: VoizWorkTracker

    init(environment: AppEnvironment = .current, workTracker: VoizWorkTracker? = nil) {
        self.environment = environment
        self.workTracker = workTracker ?? VoizWorkTracker()
    }

    func registerActivity(id: UUID, check: @escaping () -> Bool?) {
        guard environment.isDevelopment else { return }
        workTracker.registerActivity(id: id, check: check)
    }

    var hasActiveWork: Bool { environment.isDevelopment && workTracker.hasActiveWork }
}
