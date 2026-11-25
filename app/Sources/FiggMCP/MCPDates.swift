import Foundation

/// Dates as the MCP tools read and show them: in the Mac's own time zone,
/// because "yesterday's meeting" means the user's day, not UTC's.
public struct MCPDates: Sendable {
    public var timeZone: TimeZone

    public init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }

    /// A `since`/`until` argument. A bare date ("2026-11-13") is that whole
    /// local day: its first moment for `since`, its last for `until`, so
    /// `until` a date includes the date. Otherwise an ISO 8601 time; one
    /// without an offset is read as local time.
    public func bound(_ text: String, end: Bool) throws -> Date {
        let t = text.trimmingCharacters(in: .whitespaces)
        let day = t.split(separator: "-").compactMap { Int($0) }
        if t.count == 10, day.count == 3,
           let start = calendar.date(from: DateComponents(year: day[0], month: day[1], day: day[2])) {
            guard end else { return start }
            return calendar.date(byAdding: .day, value: 1, to: start)!.addingTimeInterval(-0.001)
        }
        for options: ISO8601DateFormatter.Options in [
            [.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime],
        ] {
            let f = ISO8601DateFormatter()
            f.formatOptions = options
            if let d = f.date(from: t) { return d }
        }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = timeZone
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            local.dateFormat = format
            if let d = local.date(from: t) { return d }
        }
        throw MCPError.message("Not a date: \(text). Use a date like 2026-11-13 or an ISO 8601 time.")
    }

    /// "2026-11-13 17:32 -07:00": local time with its offset.
    public func show(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm xxx"
        return f.string(from: date)
    }
}
