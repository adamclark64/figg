import FiggStore
import Foundation
import GRDB

/// Read-only queries over figg's database for the MCP server. It never
/// migrates or writes: the app owns the schema, and the server opens the
/// file read-only so no tool can change a meeting, even by mistake.
public final class MeetingLibrary: @unchecked Sendable {
    let db: DatabaseReader

    /// Opens an existing database read-only. Throws if there is none yet.
    public static func openReadOnly(path: String) throws -> MeetingLibrary {
        guard FileManager.default.fileExists(atPath: path) else {
            throw MCPError.message("There is no figg database at \(path) yet. Record a meeting in figg first.")
        }
        var config = Configuration()
        config.readonly = true
        return MeetingLibrary(reader: try DatabaseQueue(path: path, configuration: config))
    }

    /// For tests: any reader, such as an in-memory `Store`'s.
    public init(reader: DatabaseReader) {
        db = reader
    }

    /// Newest first between two dates (both included), with the total so
    /// callers can page.
    public func list(limit: Int, offset: Int, since: Date?, until: Date?) throws -> (meetings: [Meeting], total: Int) {
        try db.read { db in
            var request = Meeting.all()
            if let since { request = request.filter(Column("createdAt") >= since) }
            if let until { request = request.filter(Column("createdAt") <= until) }
            let total = try request.fetchCount(db)
            let meetings = try request.order(Column("createdAt").desc).limit(limit, offset: offset).fetchAll(db)
            return (meetings, total)
        }
    }

    /// Meetings whose title, notes or transcript match every word as a
    /// prefix: the same query as `Store.searchMeetings`. Newest first.
    public func search(_ text: String, limit: Int) throws -> [Meeting] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: text) else {
            return try list(limit: limit, offset: 0, since: nil, until: nil).meetings
        }
        return try db.read { db in
            try Meeting.fetchAll(db, sql: """
                SELECT * FROM meeting WHERE rowid IN (
                    SELECT rowid FROM meetingFts WHERE meetingFts MATCH ?
                ) OR id IN (
                    SELECT l.meetingId FROM transcriptLine l
                    JOIN transcriptLineFts f ON f.rowid = l.id
                    WHERE transcriptLineFts MATCH ?
                )
                ORDER BY createdAt DESC LIMIT ?
                """, arguments: [pattern, pattern, limit])
        }
    }

    /// Where a search hit is in one meeting.
    public struct Match: Equatable, Sendable {
        public enum Place: String, Sendable { case notes = "title or notes", transcript }
        public var place: Place
        /// Matching words are wrapped in **bold**.
        public var excerpt: String
        /// Seconds into the meeting, for a transcript match.
        public var at: Double?
    }

    /// An excerpt of the title or notes if they match, otherwise the best
    /// matching transcript line.
    public func match(meetingId: String, query: String) throws -> Match? {
        guard let all = FTS5Pattern(matchingAllPrefixesIn: query),
              let any = FTS5Pattern(matchingAnyTokenIn: query) else { return nil }
        return try db.read { db in
            if let s = try String.fetchOne(db, sql: """
                SELECT snippet(meetingFts, -1, '**', '**', '…', 16) FROM meetingFts
                WHERE meetingFts MATCH ? AND rowid = (SELECT rowid FROM meeting WHERE id = ?)
                """, arguments: [all, meetingId]) {
                return Match(place: .notes, excerpt: Self.oneLine(s))
            }
            if let row = try Row.fetchOne(db, sql: """
                SELECT l.start AS start, snippet(transcriptLineFts, 0, '**', '**', '…', 16) AS s
                FROM transcriptLineFts CROSS JOIN transcriptLine l ON l.id = transcriptLineFts.rowid
                WHERE transcriptLineFts MATCH ? AND l.meetingId = ?
                ORDER BY bm25(transcriptLineFts) LIMIT 1
                """, arguments: [any, meetingId]) {
                return Match(place: .transcript, excerpt: Self.oneLine(row["s"]), at: row["start"])
            }
            return nil
        }
    }

    /// Ids are UUIDs, which figg stores in upper case; any case finds them.
    public func meeting(id: String) throws -> Meeting? {
        try db.read { db in
            try Meeting.filter(sql: "id = ? COLLATE NOCASE", arguments: [id]).fetchOne(db)
        }
    }

    /// Lines in spoken order, plus the total so callers can page.
    public func transcript(meetingId: String, offset: Int, limit: Int) throws -> (lines: [TranscriptLine], total: Int) {
        try db.read { db in
            let request = TranscriptLine.filter(Column("meetingId") == meetingId)
            let total = try request.fetchCount(db)
            let lines = try request.order(Column("start"), Column("id")).limit(limit, offset: offset).fetchAll(db)
            return (lines, total)
        }
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

public enum MCPError: Error, CustomStringConvertible {
    case message(String)
    public var description: String {
        switch self { case let .message(m): m }
    }
}
