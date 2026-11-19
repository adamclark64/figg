import Foundation
import GRDB

/// What happened to a dictation's text after it was transcribed.
public enum DictationOutcome: String, Codable, Sendable, DatabaseValueConvertible {
    /// Put into the focused field through Accessibility.
    case inserted
    /// Typed into the focused app as keystrokes.
    case typed
    /// Not put anywhere (no text field, a password field, no permission).
    /// The history is the only copy.
    case notInserted
}

/// One past dictation, kept so its text can be copied later when it did not
/// land where the user wanted. Text only; the audio is never stored.
public struct Dictation: Codable, Sendable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var createdAt: Date
    /// What was typed: the cleaned text when cleanup ran.
    public var text: String
    /// The transcript before cleanup, or nil when the text was typed as
    /// transcribed. Kept so the raw words can be typed or copied instead.
    public var rawText: String?
    /// The app that was in front, e.g. "Slack".
    public var appName: String
    public var outcome: DictationOutcome

    public static let databaseTableName = "dictation"

    public init(id: Int64? = nil, createdAt: Date = Date(), text: String, rawText: String? = nil, appName: String, outcome: DictationOutcome) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.rawText = rawText
        self.appName = appName
        self.outcome = outcome
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension Store {
    static func registerDictationMigrations(_ m: inout DatabaseMigrator) {
        m.registerMigration("v6-dictation") { db in
            try db.create(table: "dictation") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("createdAt", .datetime).notNull().indexed()
                t.column("text", .text).notNull()
                t.column("appName", .text).notNull().defaults(to: "")
                t.column("outcome", .text).notNull()
            }
        }
        m.registerMigration("v7-dictation-raw-text") { db in
            try db.alter(table: "dictation") { t in t.add(column: "rawText", .text) }
        }
    }

    /// Saves a dictation and drops the oldest beyond `keep`.
    @discardableResult
    public func addDictation(_ dictation: Dictation, keep: Int) throws -> Dictation {
        try db.write { db in
            var d = dictation
            try d.insert(db)
            try db.execute(sql: """
                DELETE FROM dictation WHERE id NOT IN (
                    SELECT id FROM dictation ORDER BY createdAt DESC, id DESC LIMIT ?
                )
                """, arguments: [max(keep, 1)])
            return d
        }
    }

    /// Newest first.
    public func recentDictations(limit: Int) throws -> [Dictation] {
        try db.read {
            try Dictation.order(Column("createdAt").desc, Column("id").desc).limit(limit).fetchAll($0)
        }
    }

    /// Replaces what a past dictation says was typed, after Use Raw Text
    /// or Process Again changed it. A raw text already kept is never
    /// overwritten; `rawText` fills it in for a dictation typed uncleaned.
    public func updateDictationText(id: Int64, text: String, rawText: String? = nil) throws {
        try db.write {
            try $0.execute(
                sql: "UPDATE dictation SET text = ?, rawText = COALESCE(rawText, ?) WHERE id = ?",
                arguments: [text, rawText, id])
        }
    }

    public func deleteDictation(id: Int64) throws {
        _ = try db.write { try Dictation.deleteOne($0, key: id) }
    }

    public func clearDictations() throws {
        _ = try db.write { try Dictation.deleteAll($0) }
    }
}
