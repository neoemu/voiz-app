import EventKit
import Foundation
import Testing

@MainActor
@Suite("Calendário — múltiplas contas, filtros e permissões")
struct MeetingCalendarServiceTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let personal = MeetingCalendar(id: "personal-main", title: "Calendar", accountID: "personal", accountTitle: "Google")
    private let work = MeetingCalendar(id: "work-main", title: "Calendar", accountID: "work", accountTitle: "Google")
    private let shared = MeetingCalendar(id: "work-shared", title: "Team", accountID: "work", accountTitle: "Google")

    private func record(_ id: String, calendar: MeetingCalendar, offset: TimeInterval = 300) -> MeetingCalendarRecord {
        MeetingCalendarRecord(event: CalendarEvent(id: id, title: "Planning",
            startDate: now.addingTimeInterval(offset), endDate: now.addingTimeInterval(offset + 1800),
            hasVideoLink: true, calendarID: calendar.id, calendarTitle: calendar.title, accountTitle: calendar.accountTitle))
    }

    private func fixture() -> (MeetingCalendarService, CalendarReaderStub) {
        let reader = CalendarReaderStub()
        reader.availableCalendars = [shared, personal, work]
        reader.records = [record("work-event", calendar: work), record("personal-event", calendar: personal, offset: 60),
                          record("shared-event", calendar: shared, offset: 600)]
        return (MeetingCalendarService(reader: reader, observesChanges: false), reader)
    }

    @Test("Identical account and calendar names stay separate; the agenda combines selected accounts")
    func multipleAccounts() {
        let (service, reader) = fixture()
        service.configure(enabled: true, selection: .init())
        service.refresh(now: now)
        #expect(service.accounts.count == 2)
        #expect(service.accounts.first { $0.id == "work" }?.calendars.map(\.id) == [work.id, shared.id])
        #expect(reader.lastCalendarIDs == Set([personal.id, work.id, shared.id]))
        #expect(service.upcomingEvents.map(\.id) == ["personal-event", "work-event", "shared-event"])
        #expect(service.upcomingEvents.first?.sourceLabel == "Google · Calendar")
    }

    @Test("Calendar and account exclusions compose, persist, and retain per-calendar choices")
    func selectionPersists() throws {
        var selection = MeetingCalendarSelection(disabledAccountIDs: ["work"], disabledCalendarIDs: [shared.id])
        let restored = try JSONDecoder().decode(MeetingCalendarSelection.self, from: JSONEncoder().encode(selection))
        #expect(restored == selection)
        let (service, _) = fixture()
        service.configure(enabled: true, selection: restored)
        service.refresh(now: now)
        #expect(service.upcomingEvents.map(\.id) == ["personal-event"])
        selection.disabledAccountIDs.remove("work")
        service.configure(enabled: true, selection: selection)
        service.refresh(now: now)
        #expect(service.upcomingEvents.map(\.id) == ["personal-event", "work-event"])
    }

    @Test("Disabling every calendar or the integration clears events without issuing an all-calendar query")
    func emptySelectionNeverQueriesEvents() {
        let (service, reader) = fixture()
        service.configure(enabled: true, selection: .init())
        service.refresh(now: now)
        let calls = reader.eventReadCount
        service.configure(enabled: true, selection: .init(disabledAccountIDs: ["personal", "work"]))
        #expect(service.upcomingEvents.isEmpty)
        #expect(service.detectedMeeting == nil)
        #expect(reader.eventReadCount == calls)
        service.configure(enabled: true, selection: .init(disabledCalendarIDs: [personal.id, work.id, shared.id]))
        #expect(reader.eventReadCount == calls)
        service.configure(enabled: false, selection: .init())
        #expect(reader.eventReadCount == calls)
        #expect(service.lastRefreshedAt == nil)
    }

    @Test("Permission revoked and restored outside the app clears and reloads account data")
    func permissionChanges() {
        let (service, reader) = fixture()
        service.configure(enabled: true, selection: .init())
        service.refresh(now: now)
        #expect(!service.upcomingEvents.isEmpty)
        let calls = reader.eventReadCount
        for status in [EKAuthorizationStatus.denied, .restricted, .writeOnly, .notDetermined] {
            reader.authorizationStatus = status
            service.refresh(now: now)
            #expect(!service.isAuthorized)
            #expect(service.accounts.isEmpty)
            #expect(service.upcomingEvents.isEmpty)
            #expect(service.detectedMeeting == nil)
            #expect(reader.eventReadCount == calls)
        }
        reader.authorizationStatus = .fullAccess
        service.refresh(now: now)
        #expect(service.isAuthorized)
        #expect(service.upcomingEvents.count == 3)
    }

    @Test("Declined, cancelled, all-day, ended and invalid events never appear")
    func excludedEvents() {
        let (service, reader) = fixture()
        var declined = record("declined", calendar: personal)
        declined.isDeclined = true
        var canceled = record("canceled", calendar: personal)
        canceled.isCanceled = true
        var allDay = record("all-day", calendar: personal)
        allDay.isAllDay = true
        let ended = record("ended", calendar: personal, offset: -3600)
        let invalid = MeetingCalendarRecord(event: CalendarEvent(id: "invalid", title: "Invalid",
            startDate: now.addingTimeInterval(100), endDate: now.addingTimeInterval(50),
            hasVideoLink: true, calendarID: personal.id))
        reader.records = [declined, canceled, allDay, ended, invalid, record("valid", calendar: personal)]
        service.configure(enabled: true, selection: .init())
        service.refresh(now: now)
        #expect(service.upcomingEvents.map(\.id) == ["valid"])
        #expect(service.detectedMeeting?.id == "valid")
    }

    @Test("Meeting-only mode keeps invited meetings and video calls while hiding personal time blocks")
    func meetingFilter() {
        let (service, reader) = fixture()
        let focusEvent = CalendarEvent(id: "focus", title: "Focus",
            startDate: now.addingTimeInterval(60), endDate: now.addingTimeInterval(1800),
            hasVideoLink: false, calendarID: personal.id)
        let inPersonEvent = CalendarEvent(id: "in-person", title: "Office",
            startDate: now.addingTimeInterval(120), endDate: now.addingTimeInterval(1800),
            hasVideoLink: false, calendarID: personal.id)
        reader.records = [.init(event: focusEvent), .init(event: inPersonEvent, hasOtherAttendees: true),
                          record("video", calendar: work)]
        service.configure(enabled: true, selection: .init(meetingsOnly: true))
        service.refresh(now: now)
        #expect(service.upcomingEvents.map(\.id) == ["in-person", "video"])
        service.configure(enabled: true, selection: .init())
        service.refresh(now: now)
        #expect(service.upcomingEvents.count == 3)
        #expect(service.detectedMeeting?.id == "in-person")
    }

    @Test("Dismissal survives refresh and does not dismiss a later occurrence")
    func dismissedOccurrence() {
        let (service, reader) = fixture()
        reader.records = [record("series-occurrence-1", calendar: personal)]
        service.configure(enabled: true, selection: .init())
        service.refresh(now: now)
        service.dismiss()
        service.refresh(now: now.addingTimeInterval(60))
        #expect(service.detectedMeeting == nil)
        #expect(service.upcomingEvents.count == 1)
        reader.records = [record("series-occurrence-2", calendar: personal, offset: 3600)]
        service.refresh(now: now.addingTimeInterval(3500))
        #expect(service.detectedMeeting?.id == "series-occurrence-2")
    }

    @Test("Removed accounts disappear; new accounts appear without losing stored exclusions")
    func accountChanges() {
        let (service, reader) = fixture()
        service.configure(enabled: true, selection: .init(disabledAccountIDs: ["work"]))
        reader.availableCalendars = [personal]
        service.refresh(now: now)
        #expect(service.accounts.map(\.id) == ["personal"])
        reader.availableCalendars = [personal, work, shared]
        service.refresh(now: now)
        #expect(service.accounts.count == 2)
        #expect(service.upcomingEvents.map(\.id) == ["personal-event"])
    }

    @Test("Access errors are recoverable and never leave the request busy")
    func accessFailureAndRetry() async {
        let (service, reader) = fixture()
        reader.authorizationStatus = .notDetermined
        reader.accessFails = true
        #expect(await service.requestAccess() == false)
        #expect(service.accessError != nil)
        #expect(!service.isRequestingAccess)
        reader.accessFails = false
        #expect(await service.requestAccess())
        #expect(service.isAuthorized)
        #expect(service.accessError == nil)
    }

    @Test("The seven-day agenda is not silently truncated at forty events")
    func fullAgendaAndDuplicates() {
        let (service, reader) = fixture()
        reader.records = (0..<55).map { record("event-\($0)", calendar: personal, offset: Double($0) * 120) }
        reader.records.append(reader.records[0])
        service.configure(enabled: true, selection: .init())
        service.refresh(now: now)
        #expect(service.upcomingEvents.count == 55)
        #expect(Set(service.upcomingEvents.map(\.id)).count == 55)
    }

    @Test("Legacy settings retain calendar opt-in and receive an unrestricted selection")
    func legacySettings() throws {
        let json = Data(#"{"calendarSuggestionsEnabled":true,"openAIKey":"keep-me"}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: json)
        #expect(settings.calendarSuggestionsEnabled)
        #expect(settings.calendarSelection == MeetingCalendarSelection())
        #expect(settings.openAIKey == "keep-me")
    }
}

@MainActor
private final class CalendarReaderStub: MeetingCalendarReading {
    var authorizationStatus: EKAuthorizationStatus = .fullAccess
    var availableCalendars: [MeetingCalendar] = []
    var records: [MeetingCalendarRecord] = []
    var lastCalendarIDs = Set<String>()
    var eventReadCount = 0
    var accessFails = false

    func requestAccess() async throws -> Bool {
        if accessFails { throw NSError(domain: "CalendarTest", code: 1) }
        authorizationStatus = .fullAccess
        return true
    }

    func calendars() -> [MeetingCalendar] { availableCalendars }

    func events(from start: Date, to end: Date, calendarIDs: Set<String>) -> [MeetingCalendarRecord] {
        lastCalendarIDs = calendarIDs
        eventReadCount += 1
        // Deliberately return other calendars too, to exercise the service's defensive filter.
        return records
    }
}
