import Foundation
import GRDB

public enum MeetingStatus: String, Codable, Sendable, DatabaseValueConvertible {
    case recording
    case transcribing
    case enhancing
    case needsEnhance
    case ready
    case failed
}

public struct Meeting: Codable, Sendable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    public var id: String
    public var title: String
    public var createdAt: Date
    public var endedAt: Date?
    public var status: MeetingStatus
    public var userNotes: String
    public var enhancedNotes: String?
    public var errorMessage: String?
    /// People sharing the mic, if the user set it; nil means auto-detect.
    public var roomSpeakers: Int?
    /// Note template id for enhancement; nil means the configured default.
    public var template: String?
    /// Attendee names from the matched calendar event (stored as JSON).
    public var attendees: [String] = []
    /// EventKit identifier of the matched calendar event.
    public var calendarEventId: String?

    public static let databaseTableName = "meeting"

    public init(
        id: String = UUID().uuidString,
        title: String = "",
        createdAt: Date = Date(),
        endedAt: Date? = nil,
        status: MeetingStatus = .recording,
        userNotes: String = "",
        enhancedNotes: String? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.endedAt = endedAt
        self.status = status
        self.userNotes = userNotes
        self.enhancedNotes = enhancedNotes
        self.errorMessage = errorMessage
    }

    /// Title for display; untitled meetings fall back to their start time.
    public var displayTitle: String {
        if !title.isEmpty { return title }
        return "Meeting " + createdAt.formatted(date: .abbreviated, time: .shortened)
    }
}

public enum Speaker: String, Codable, Sendable, DatabaseValueConvertible {
    case me
    case them

    public var label: String { self == .me ? "Me" : "Them" }
}

public struct TranscriptLine: Codable, Sendable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var meetingId: String
    public var speaker: Speaker
    /// Seconds from meeting start.
    public var start: Double
    public var end: Double
    public var text: String
    /// Set when diarization split a stream into several people ("Guest 1",
    /// "Them 2"); nil means the stream's default label.
    public var speakerLabel: String?

    public static let databaseTableName = "transcriptLine"

    public init(id: Int64? = nil, meetingId: String, speaker: Speaker, start: Double, end: Double, text: String, speakerLabel: String? = nil) {
        self.id = id
        self.meetingId = meetingId
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
        self.speakerLabel = speakerLabel
    }

    /// What the transcript, prompts and exports show for this line's speaker.
    public var displaySpeaker: String { speakerLabel ?? speaker.label }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Formats seconds as `mm:ss` (or `h:mm:ss` past an hour).
public func formatTimestamp(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
}
