import Foundation
import GRDB

/// On-disk locations. Everything lives under one base directory so tests can
/// point it at a temp folder.
public struct FiggPaths: Sendable {
    public let base: URL

    public init(base: URL) { self.base = base }

    public static var standard: FiggPaths {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return FiggPaths(base: support.appendingPathComponent("figg", isDirectory: true))
    }

    public var database: URL { base.appendingPathComponent("figg.sqlite") }
    /// Downloaded speech models.
    public var models: URL { base.appendingPathComponent("models", isDirectory: true) }
    public func meetingDir(_ id: String) -> URL { base.appendingPathComponent("meetings/\(id)", isDirectory: true) }
    /// Audio chunks written but not yet transcribed. Survives crashes.
    public func pendingDir(_ id: String) -> URL { meetingDir(id).appendingPathComponent("pending", isDirectory: true) }
    /// Transcribed chunks, only kept when "Keep audio" is on.
    public func doneDir(_ id: String) -> URL { meetingDir(id).appendingPathComponent("done", isDirectory: true) }
}

/// A meeting matched by chat retrieval, with its FTS rank (lower is better).
public struct RankedMeeting: Sendable {
    public var meeting: Meeting
    public var score: Double
}

public final class Store: @unchecked Sendable {
    public let db: DatabaseWriter

    /// Opens (or creates) the database file.
    public convenience init(paths: FiggPaths) throws {
        // Owner-only: notes and transcripts are sensitive. The file itself is
        // not encrypted; FileVault is what encrypts it at rest.
        try FileManager.default.createDirectory(
            at: paths.base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.base.path)
        try self.init(writer: DatabasePool(path: paths.database.path))
    }

    /// In-memory store for tests and previews.
    public static func inMemory() throws -> Store {
        try Store(writer: DatabaseQueue())
    }

    public init(writer: DatabaseWriter) throws {
        db = writer
        try Self.migrator.migrate(db)
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "meeting") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull().defaults(to: "")
                t.column("createdAt", .datetime).notNull().indexed()
                t.column("endedAt", .datetime)
                t.column("status", .text).notNull()
                t.column("userNotes", .text).notNull().defaults(to: "")
                t.column("enhancedNotes", .text)
                t.column("errorMessage", .text)
            }
            try db.create(table: "transcriptLine") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meetingId", .text).notNull().indexed()
                    .references("meeting", onDelete: .cascade)
                t.column("speaker", .text).notNull()
                t.column("start", .double).notNull()
                t.column("end", .double).notNull()
                t.column("text", .text).notNull()
            }
            try db.create(virtualTable: "meetingFts", using: FTS5()) { t in
                t.synchronize(withTable: "meeting")
                t.tokenizer = .porter(wrapping: .unicode61())
                t.column("title")
                t.column("userNotes")
                t.column("enhancedNotes")
            }
            try db.create(virtualTable: "transcriptLineFts", using: FTS5()) { t in
                t.synchronize(withTable: "transcriptLine")
                t.tokenizer = .porter(wrapping: .unicode61())
                t.column("text")
            }
        }
        m.registerMigration("v2-speaker-labels") { db in
            try db.alter(table: "transcriptLine") { t in t.add(column: "speakerLabel", .text) }
        }
        m.registerMigration("v3-room-speakers") { db in
            try db.alter(table: "meeting") { t in t.add(column: "roomSpeakers", .integer) }
        }
        m.registerMigration("v4-template") { db in
            try db.alter(table: "meeting") { t in t.add(column: "template", .text) }
        }
        m.registerMigration("v5-calendar") { db in
            try db.alter(table: "meeting") { t in
                t.add(column: "attendees", .text).notNull().defaults(to: "[]")
                t.add(column: "calendarEventId", .text)
            }
        }
        return m
    }

    // MARK: Meetings

    public func save(_ meeting: Meeting) throws {
        try db.write { try meeting.save($0) }
    }

    public func meeting(id: String) throws -> Meeting? {
        try db.read { try Meeting.fetchOne($0, key: id) }
    }

    public func allMeetings() throws -> [Meeting] {
        try db.read { try Meeting.order(Column("createdAt").desc).fetchAll($0) }
    }

    public func recentMeetings(limit: Int) throws -> [Meeting] {
        try db.read { try Meeting.order(Column("createdAt").desc).limit(limit).fetchAll($0) }
    }

    /// Meetings left mid-pipeline by a crash or quit.
    public func unfinishedMeetings() throws -> [Meeting] {
        try db.read {
            try Meeting
                .filter([MeetingStatus.recording, .transcribing, .enhancing].contains(Column("status")))
                .fetchAll($0)
        }
    }

    /// Read-modify-write of one meeting in a single transaction, so a change
    /// to one field never clobbers a concurrent change to another.
    @discardableResult
    public func update(meetingId: String, _ change: (inout Meeting) -> Void) throws -> Meeting? {
        try db.write { db in
            guard var meeting = try Meeting.fetchOne(db, key: meetingId) else { return nil }
            change(&meeting)
            try meeting.update(db)
            return meeting
        }
    }

    public func updateNotes(meetingId: String, userNotes: String) throws {
        try db.write {
            try $0.execute(sql: "UPDATE meeting SET userNotes = ? WHERE id = ?", arguments: [userNotes, meetingId])
        }
    }

    public func updateStatus(meetingId: String, _ status: MeetingStatus, error: String? = nil) throws {
        try db.write {
            try $0.execute(
                sql: "UPDATE meeting SET status = ?, errorMessage = ? WHERE id = ?",
                arguments: [status, error, meetingId])
        }
    }

    public func delete(meetingId: String) throws {
        _ = try db.write { try Meeting.deleteOne($0, key: meetingId) }
    }

    // MARK: Transcript

    @discardableResult
    public func append(_ lines: [TranscriptLine]) throws -> [TranscriptLine] {
        try db.write { db in
            try lines.map { line in
                var line = line
                try line.insert(db)
                return line
            }
        }
    }

    /// Swaps a meeting's lines for a new set in one transaction (final pass).
    @discardableResult
    public func replaceTranscript(meetingId: String, with lines: [TranscriptLine]) throws -> [TranscriptLine] {
        try db.write { db in
            try TranscriptLine.filter(Column("meetingId") == meetingId).deleteAll(db)
            return try lines.map { line in
                var line = line
                try line.insert(db)
                return line
            }
        }
    }

    /// Renames one displayed speaker ("Guest 1", "Me", a previous rename)
    /// across a meeting's transcript, e.g. to a calendar attendee's name.
    public func renameSpeaker(meetingId: String, from: String, to: String) throws {
        let to = to.trimmingCharacters(in: .whitespaces)
        guard !to.isEmpty, to != from else { return }
        try db.write {
            try $0.execute(sql: """
                UPDATE transcriptLine SET speakerLabel = ?
                WHERE meetingId = ?
                  AND COALESCE(speakerLabel, CASE speaker WHEN 'me' THEN 'Me' ELSE 'Them' END) = ?
                """, arguments: [to, meetingId, from])
        }
    }

    public func transcript(meetingId: String) throws -> [TranscriptLine] {
        try db.read {
            try TranscriptLine
                .filter(Column("meetingId") == meetingId)
                .order(Column("start"), Column("id"))
                .fetchAll($0)
        }
    }

    // MARK: Search

    /// Sidebar search: meetings whose notes, title or transcript match every
    /// typed word as a prefix. Newest first.
    public func searchMeetings(_ text: String) throws -> [Meeting] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: text) else { return try allMeetings() }
        return try db.read { db in
            try Meeting.fetchAll(db, sql: """
                SELECT * FROM meeting WHERE rowid IN (
                    SELECT rowid FROM meetingFts WHERE meetingFts MATCH ?
                ) OR id IN (
                    SELECT l.meetingId FROM transcriptLine l
                    JOIN transcriptLineFts f ON f.rowid = l.id
                    WHERE transcriptLineFts MATCH ?
                )
                ORDER BY createdAt DESC
                """, arguments: [pattern, pattern])
        }
    }

    /// Chat retrieval: meetings ranked by their best bm25 match across notes
    /// and transcript, plus a small bonus for many matching lines.
    public func rankMeetings(keywords: [String], limit: Int) throws -> [RankedMeeting] {
        guard let pattern = FTS5Pattern(matchingAnyTokenIn: keywords.joined(separator: " ")) else { return [] }
        return try db.read { db in
            var scores: [String: Double] = [:]
            let noteRows = try Row.fetchAll(db, sql: """
                SELECT m.id AS id, bm25(meetingFts) AS score
                FROM meetingFts CROSS JOIN meeting m ON m.rowid = meetingFts.rowid
                WHERE meetingFts MATCH ?
                """, arguments: [pattern])
            for row in noteRows {
                let id: String = row["id"], score: Double = row["score"]
                scores[id] = min(scores[id] ?? 0, score)
            }
            let lineRows = try Row.fetchAll(db, sql: """
                SELECT l.meetingId AS id, bm25(transcriptLineFts) AS score
                FROM transcriptLineFts CROSS JOIN transcriptLine l ON l.id = transcriptLineFts.rowid
                WHERE transcriptLineFts MATCH ?
                """, arguments: [pattern])
            var lineBest: [String: (score: Double, hits: Int)] = [:]
            for row in lineRows {
                let id: String = row["id"], score: Double = row["score"]
                let prev = lineBest[id]
                lineBest[id] = (min(prev?.score ?? 0, score), (prev?.hits ?? 0) + 1)
            }
            for (id, best) in lineBest {
                // bm25 is negative; more hits pushes the meeting further up.
                let combined = best.score - log(Double(best.hits))
                scores[id] = min(scores[id] ?? 0, combined)
            }
            let top = scores.sorted { $0.value < $1.value }.prefix(limit)
            return try top.compactMap { id, score in
                try Meeting.fetchOne(db, key: id).map { RankedMeeting(meeting: $0, score: score) }
            }
        }
    }

    public func matchingLines(meetingId: String, keywords: [String], limit: Int) throws -> [TranscriptLine] {
        guard let pattern = FTS5Pattern(matchingAnyTokenIn: keywords.joined(separator: " ")) else { return [] }
        return try db.read { db in
            try TranscriptLine.fetchAll(db, sql: """
                SELECT l.* FROM transcriptLineFts CROSS JOIN transcriptLine l ON l.id = transcriptLineFts.rowid
                WHERE transcriptLineFts MATCH ? AND l.meetingId = ?
                ORDER BY bm25(transcriptLineFts) LIMIT ?
                """, arguments: [pattern, meetingId, limit])
        }
    }
}
