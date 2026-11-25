import Foundation

/// Explicit exclusions preserve existing calendars when upgrading and allow new accounts to appear.
nonisolated struct MeetingCalendarSelection: Codable, Equatable {
    var disabledAccountIDs: Set<String> = []
    var disabledCalendarIDs: Set<String> = []
    var meetingsOnly = false

    func includes(_ calendar: MeetingCalendar) -> Bool {
        !disabledAccountIDs.contains(calendar.accountID) && !disabledCalendarIDs.contains(calendar.id)
    }
}

struct MeetingCalendar: Identifiable, Equatable {
    let id: String
    let title: String
    let accountID: String
    let accountTitle: String
    var color: CalendarColor? = nil
}

struct CalendarColor: Equatable {
    let red: Double
    let green: Double
    let blue: Double
}

struct MeetingCalendarAccount: Identifiable, Equatable {
    let id: String
    let title: String
    let calendars: [MeetingCalendar]

    static func grouped(_ calendars: [MeetingCalendar]) -> [Self] {
        Dictionary(grouping: calendars, by: \.accountID).map { id, calendars in
            Self(id: id, title: calendars[0].accountTitle, calendars: calendars.sorted {
                if $0.title == $1.title { return $0.id < $1.id }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            })
        }.sorted {
            if $0.title == $1.title { return $0.id < $1.id }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
}

nonisolated struct CalendarAttendee: Equatable, Hashable, Codable, Sendable {
    var name: String
    var isCurrentUser: Bool = false
    var isOrganizer: Bool = false
}

struct DetectedMeeting: Equatable, Identifiable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isInProgress: Bool
    var attendees: [CalendarAttendee] = []

    var minutesUntilStart: Int { max(0, Int(startDate.timeIntervalSinceNow / 60)) }
}

struct CalendarEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let hasVideoLink: Bool
    var calendarID: String = ""
    var calendarTitle: String = ""
    var accountTitle: String = ""
    var color: CalendarColor? = nil
    var attendees: [CalendarAttendee] = []

    var sourceLabel: String {
        [accountTitle, calendarTitle].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var otherAttendeeNames: [String] {
        var seen: Set<String> = []
        var names: [String] = []
        for attendee in attendees where !attendee.isCurrentUser {
            let trimmed = attendee.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            if seen.insert(key).inserted {
                names.append(trimmed)
            }
        }
        return names
    }

    /// Uses local day boundaries, including an ongoing event that crosses midnight.
    static func remainingToday(in events: [Self], now: Date, calendar: Calendar = .current) -> [Self] {
        guard let day = calendar.dateInterval(of: .day, for: now) else { return [] }
        return events.filter { $0.startDate < day.end && $0.endDate > now }
            .sorted {
                if $0.startDate == $1.startDate { return $0.id < $1.id }
                return $0.startDate < $1.startDate
            }
    }
}

/// EventKit objects remain in the reader; filtering uses immutable values and a fixed clock.
struct MeetingCalendarRecord {
    let event: CalendarEvent
    var isAllDay = false
    var isCanceled = false
    var isDeclined = false
    var hasOtherAttendees = false

    var isMeeting: Bool { event.hasVideoLink || hasOtherAttendees }

    func isVisible(at now: Date, meetingsOnly: Bool) -> Bool {
        !isAllDay && !isCanceled && !isDeclined && event.endDate > now
            && event.endDate > event.startDate && (!meetingsOnly || isMeeting)
    }
}
