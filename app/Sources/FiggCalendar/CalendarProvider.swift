import Foundation

/// A calendar meeting, read locally. Only titles and attendee names are used,
/// and only as text context for prompts; nothing calendar-derived is stored
/// outside the figg database.
public struct CalendarEvent: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    /// Human attendees by display name, organizer first; empty for solo events.
    public var attendees: [String]
    public var isAllDay: Bool

    public init(id: String, title: String, start: Date, end: Date, attendees: [String] = [], isAllDay: Bool = false) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.attendees = attendees
        self.isAllDay = isAllDay
    }
}

/// Read-only calendar access. EventKit in the app; fixed lists in tests.
public protocol CalendarProvider: Sendable {
    /// Asks macOS for (full, read) calendar access. False means denied.
    func requestAccess() async -> Bool
    func events(from: Date, to: Date) async -> [CalendarEvent]
}

public extension [CalendarEvent] {
    /// The event most likely to be the meeting happening at `date`: a timed
    /// event overlapping it (with `grace` either side, so joining early or
    /// running long still matches). Ties go to the latest start, so a 1:1
    /// inside a blocked-out morning wins over the block.
    func current(at date: Date, grace: TimeInterval = 5 * 60) -> CalendarEvent? {
        filter { !$0.isAllDay && $0.start.addingTimeInterval(-grace) <= date && date <= $0.end.addingTimeInterval(grace) }
            .max { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    /// The next timed event starting within `window` of `date` (or already
    /// running), for the pre-meeting brief. Nil when the calendar is clear.
    func next(after date: Date, window: TimeInterval = 4 * 3600) -> CalendarEvent? {
        filter { !$0.isAllDay && $0.end >= date && $0.start <= date.addingTimeInterval(window) }
            .min { ($0.start, $0.end) < ($1.start, $1.end) }
    }
}
