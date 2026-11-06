import AppKit
import Combine
import EventKit
import Foundation
import OSLog

@MainActor
protocol MeetingCalendarReading: AnyObject {
    var authorizationStatus: EKAuthorizationStatus { get }
    func requestAccess() async throws -> Bool
    func calendars() -> [MeetingCalendar]
    func events(from start: Date, to end: Date, calendarIDs: Set<String>) -> [MeetingCalendarRecord]
}

/// Reads only calendars already synced by macOS. Account credentials stay with the system.
@MainActor
final class EventKitCalendarReader: MeetingCalendarReading {
    private let store = EKEventStore()
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    var authorizationStatus: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }

    func requestAccess() async throws -> Bool { try await store.requestFullAccessToEvents() }

    func calendars() -> [MeetingCalendar] {
        store.calendars(for: .event).map(Self.calendar)
    }

    func events(from start: Date, to end: Date, calendarIDs: Set<String>) -> [MeetingCalendarRecord] {
        let calendars = store.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
        // EventKit treats an empty calendar list as ALL calendars. Never query in this case.
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        return store.events(matching: predicate).compactMap { event in
            guard let startDate = event.startDate, let endDate = event.endDate,
                  let calendar = event.calendar else { return nil }
            let source = Self.calendar(calendar)
            let title = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let attendees = event.attendees ?? []
            return MeetingCalendarRecord(
                event: CalendarEvent(
                    // Preserve existing preparation references. EventKit's local event identifier
                    // identifies a calendar's copy; the date distinguishes recurrences.
                    id: "\(event.eventIdentifier ?? event.calendarItemIdentifier)-\(startDate.timeIntervalSince1970)",
                    title: title.isEmpty ? String(localized: "Reunião") : title,
                    startDate: startDate, endDate: endDate,
                    hasVideoLink: Self.hasVideoLink(event),
                    calendarID: source.id, calendarTitle: source.title,
                    accountTitle: source.accountTitle, color: source.color
                ),
                isAllDay: event.isAllDay,
                isCanceled: event.status == .canceled,
                isDeclined: attendees.contains { $0.isCurrentUser && $0.participantStatus == .declined },
                hasOtherAttendees: attendees.contains { !$0.isCurrentUser && $0.participantStatus != .declined }
            )
        }
    }

    private static func calendar(_ calendar: EKCalendar) -> MeetingCalendar {
        let color = calendar.color?.usingColorSpace(.sRGB)
        return MeetingCalendar(
            id: calendar.calendarIdentifier, title: calendar.title,
            accountID: calendar.source?.sourceIdentifier ?? "local",
            accountTitle: calendar.source?.title ?? String(localized: "No meu Mac"),
            color: color.map { CalendarColor(red: $0.redComponent, green: $0.greenComponent, blue: $0.blueComponent) }
        )
    }

    private static func hasVideoLink(_ event: EKEvent) -> Bool {
        let text = [event.location, event.notes, event.url?.absoluteString].compactMap { $0 }.joined(separator: " ")
        guard let detector = linkDetector else { return false }
        let hosts = ["zoom.us", "zoom.com", "meet.google.com", "teams.microsoft.com", "teams.live.com",
                     "teams.cloud.microsoft", "webex.com", "whereby.com", "around.co", "chime.aws"]
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).contains { match in
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host?.lowercased() else { return false }
            return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
        }
    }
}

@MainActor
final class MeetingCalendarService: ObservableObject {
    @Published private(set) var detectedMeeting: DetectedMeeting?
    @Published private(set) var upcomingEvents: [CalendarEvent] = []
    @Published private(set) var accounts: [MeetingCalendarAccount] = []
    @Published private(set) var authorizationStatus: EKAuthorizationStatus
    @Published private(set) var lastRefreshedAt: Date?
    @Published private(set) var accessError: String?
    @Published private(set) var isRequestingAccess = false

    private let reader: any MeetingCalendarReading
    private let observesChanges: Bool
    private var enabled = false
    private var selection = MeetingCalendarSelection()
    private var dismissedOccurrences: [String: Date] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: AnyCancellable?
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.rmb.voiz", category: "calendar")

    init(reader: (any MeetingCalendarReading)? = nil, observesChanges: Bool = true) {
        let reader = reader ?? EventKitCalendarReader()
        self.reader = reader
        self.observesChanges = observesChanges
        authorizationStatus = reader.authorizationStatus
        if observesChanges {
            NotificationCenter.default.publisher(for: .EKEventStoreChanged)
                .merge(with: NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
                .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
                .sink { [weak self] _ in self?.refresh() }
                .store(in: &cancellables)
        }
    }

    var isAuthorized: Bool { authorizationStatus == .fullAccess }
    var isAccessBlocked: Bool { authorizationStatus == .denied || authorizationStatus == .restricted }

    func configure(enabled: Bool, selection: MeetingCalendarSelection) {
        self.enabled = enabled
        self.selection = selection
        if enabled, observesChanges, refreshTimer == nil {
            refreshTimer = Timer.publish(every: 60, tolerance: 5, on: .main, in: .common).autoconnect()
                .sink { [weak self] _ in self?.refresh() }
        } else if !enabled {
            refreshTimer = nil
        }
        refresh()
    }

    func requestAccess() async -> Bool {
        guard !isRequestingAccess else { return false }
        isRequestingAccess = true
        accessError = nil
        defer { isRequestingAccess = false; refresh() }
        do {
            return try await reader.requestAccess()
        } catch {
            // Do not put event data or account details into logs.
            log.error("Calendar access request failed (code \((error as NSError).code, privacy: .public))")
            accessError = String(localized: "Não foi possível acessar o calendário. Tente novamente.")
            return false
        }
    }

    func openSystemSettings() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
    }

    func openInternetAccounts() {
        openSettings("x-apple.systempreferences:com.apple.preferences.internetaccounts")
    }

    private func openSettings(_ address: String) {
        guard let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }

    func refresh(now: Date = Date()) {
        // Always recheck the system: access can be granted or revoked while Voiz is open.
        authorizationStatus = reader.authorizationStatus
        guard isAuthorized else {
            accounts = []
            lastRefreshedAt = nil
            clearAll()
            return
        }
        let calendars = reader.calendars()
        accounts = MeetingCalendarAccount.grouped(calendars)
        let selectedIDs = Set(calendars.filter(selection.includes).map(\.id))
        guard enabled, !selectedIDs.isEmpty else {
            lastRefreshedAt = nil
            clearAll()
            return
        }
        let end = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now.addingTimeInterval(7 * 86_400)
        let records = reader.events(from: now.addingTimeInterval(-3600), to: end, calendarIDs: selectedIDs)
            .filter { selectedIDs.contains($0.event.calendarID) && $0.isVisible(at: now, meetingsOnly: selection.meetingsOnly) }
            .sorted {
                if $0.event.startDate == $1.event.startDate { return $0.event.id < $1.event.id }
                return $0.event.startDate < $1.event.startDate
            }
        var seen = Set<String>()
        upcomingEvents = records.map(\.event).filter { seen.insert($0.id).inserted }
        dismissedOccurrences = dismissedOccurrences.filter { $0.value > now }
        detectedMeeting = records.first {
            $0.isMeeting && $0.event.startDate <= now.addingTimeInterval(15 * 60)
                && dismissedOccurrences[$0.event.id] == nil
        }.map {
            DetectedMeeting(id: $0.event.id, title: $0.event.title, startDate: $0.event.startDate,
                            endDate: $0.event.endDate, isInProgress: $0.event.startDate <= now)
        }
        lastRefreshedAt = now
    }

    /// Keep a dismissed occurrence hidden until it ends, including across automatic refreshes.
    func dismiss() {
        if let meeting = detectedMeeting { dismissedOccurrences[meeting.id] = meeting.endDate }
        detectedMeeting = nil
    }

    func dismiss(_ event: CalendarEvent) {
        dismissedOccurrences[event.id] = event.endDate
        if detectedMeeting?.id == event.id { detectedMeeting = nil }
    }

    private func clearAll() {
        detectedMeeting = nil
        upcomingEvents = []
    }
}
