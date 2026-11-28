import FiggStore
import Foundation

/// The tools Claude sees. Each returns plain Markdown text, which Claude
/// reads best and a person can read when they expand the tool call.
public struct MCPTools: Sendable {
    public struct Result: Equatable, Sendable {
        public var text: String
        public var isError: Bool
    }

    static let maxBatch = 20
    var dates: MCPDates

    public init(dates: MCPDates = MCPDates()) {
        self.dates = dates
    }

    public func call(_ name: String, _ args: [String: Any], library: MeetingLibrary) -> Result {
        do {
            switch name {
            case "list_meetings": return Result(text: try listMeetings(args, library), isError: false)
            case "search_meetings": return Result(text: try searchMeetings(args, library), isError: false)
            case "get_meeting":
                let id = try string(args, "id")
                guard let m = try library.meeting(id: id) else { throw MCPError.message("No meeting with id \(id).") }
                return Result(text: notes(m), isError: false)
            case "get_meetings": return Result(text: try getMeetings(args, library), isError: false)
            case "get_transcript": return Result(text: try transcript(args, library), isError: false)
            default: return Result(text: "Unknown tool: \(name)", isError: true)
            }
        } catch {
            return Result(text: "\(error)", isError: true)
        }
    }

    // MARK: Tools

    private func listMeetings(_ args: [String: Any], _ library: MeetingLibrary) throws -> String {
        let offset = max(0, int(args, "offset") ?? 0)
        let since = try optionalString(args, "since").map { try dates.bound($0, end: false) }
        let until = try optionalString(args, "until").map { try dates.bound($0, end: true) }
        let (meetings, total) = try library.list(limit: limit(args), offset: offset, since: since, until: until)
        if total == 0 { return "No meetings found." }
        if meetings.isEmpty { return "(offset \(offset) is past the end: \(total) meetings match)" }
        let end = offset + meetings.count
        let footer = end < total ? "(meetings \(offset + 1) to \(end) of \(total); call again with offset \(end) for more)"
            : offset > 0 ? "(meetings \(offset + 1) to \(end) of \(total))"
            : total == 1 ? "(1 meeting)" : "(all \(total) meetings)"
        return meetings.map(listItem).joined(separator: "\n") + "\n\n" + footer
    }

    private func searchMeetings(_ args: [String: Any], _ library: MeetingLibrary) throws -> String {
        let query = try string(args, "query")
        let meetings = try library.search(query, limit: limit(args))
        if meetings.isEmpty { return "No meetings match." }
        return try meetings.map { m in
            guard let hit = try library.match(meetingId: m.id, query: query) else { return listItem(m) }
            let at = hit.at.map { " at \(formatTimestamp($0))" } ?? ""
            return "\(listItem(m))\n  matched in \(hit.place.rawValue)\(at): \(hit.excerpt)"
        }.joined(separator: "\n")
    }

    private func getMeetings(_ args: [String: Any], _ library: MeetingLibrary) throws -> String {
        guard let ids = args["ids"] as? [Any], !ids.isEmpty else {
            throw MCPError.message("\"ids\" must be a list of meeting ids.")
        }
        guard ids.count <= Self.maxBatch else {
            throw MCPError.message("At most \(Self.maxBatch) ids at a time; got \(ids.count).")
        }
        return try ids.map { raw in
            let id = "\(raw)".trimmingCharacters(in: .whitespaces)
            return try library.meeting(id: id).map(notes) ?? "# Not found\n\nNo meeting with id \(id)."
        }.joined(separator: "\n\n---\n\n")
    }

    private func transcript(_ args: [String: Any], _ library: MeetingLibrary) throws -> String {
        let id = try string(args, "id")
        guard let m = try library.meeting(id: id) else { throw MCPError.message("No meeting with id \(id).") }
        let offset = max(0, int(args, "offset") ?? 0)
        let limit = min(5000, max(1, int(args, "limit") ?? 2000))
        // m.id, not the argument: it may differ in case.
        let (lines, total) = try library.transcript(meetingId: m.id, offset: offset, limit: limit)
        if total == 0 { return header(m) + "\n\n(no transcript)" }
        if lines.isEmpty { return header(m) + "\n\n(offset \(offset) is past the end: the transcript has \(total) lines)" }
        let body = lines.map { "[\(formatTimestamp($0.start))] \($0.displaySpeaker): \($0.text)" }.joined(separator: "\n")
        let end = offset + lines.count
        let footer = end < total ? "(lines \(offset + 1) to \(end) of \(total); call again with offset \(end) for more)"
            : offset > 0 ? "(end of transcript: lines \(offset + 1) to \(end) of \(total))"
            : "(end of transcript: all \(total) lines)"
        return "\(header(m))\n\n\(body)\n\n\(footer)"
    }

    // MARK: Formatting

    private func minutes(_ m: Meeting) -> Int? {
        m.endedAt.map { Int(($0.timeIntervalSince(m.createdAt) / 60).rounded()) }
    }

    func header(_ m: Meeting) -> String {
        var lines = ["# \(m.title.isEmpty ? "Untitled meeting" : m.title)", "", "- id: \(m.id)",
                     "- started: \(dates.show(m.createdAt))"]
        if let n = minutes(m) { lines.append("- length: \(n) min") }
        if m.status != .ready { lines.append("- status: \(m.status.rawValue)") }
        if !m.attendees.isEmpty { lines.append("- attendees: \(m.attendees.joined(separator: ", "))") }
        return lines.joined(separator: "\n")
    }

    func notes(_ m: Meeting) -> String {
        let mine = m.userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let enhanced = (m.enhancedNotes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return [header(m), "", "## My notes", "", mine.isEmpty ? "(none)" : mine, "",
                "## Enhanced notes", "", enhanced.isEmpty ? "(not enhanced yet)" : enhanced].joined(separator: "\n")
    }

    func listItem(_ m: Meeting) -> String {
        var parts = [dates.show(m.createdAt), m.title.isEmpty ? "Untitled meeting" : m.title]
        if let n = minutes(m) { parts.append("\(n) min") }
        if m.status != .ready { parts.append(m.status.rawValue) }
        if !m.attendees.isEmpty { parts.append("with \(m.attendees.joined(separator: ", "))") }
        return "- \(m.id): \(parts.joined(separator: " · "))"
    }

    // MARK: Arguments

    private func string(_ args: [String: Any], _ key: String) throws -> String {
        guard let s = optionalString(args, key) else { throw MCPError.message("\"\(key)\" is required.") }
        return s
    }

    private func optionalString(_ args: [String: Any], _ key: String) -> String? {
        guard let s = args[key] as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    private func int(_ args: [String: Any], _ key: String) -> Int? {
        (args[key] as? NSNumber)?.intValue
    }

    private func limit(_ args: [String: Any]) -> Int {
        min(200, max(1, int(args, "limit") ?? 20))
    }
}
