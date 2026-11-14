import FiggLLM
import FiggStore
import Foundation

/// A short prep note for an upcoming meeting, built from past figg meetings
/// with the same people or topic. Retrieval reuses the chat keyword search;
/// only text goes to the model.
public struct MeetingBrief: Sendable {
    public let store: Store
    public let llm: LLMProvider
    public let model: String
    public var maxMeetings = 4
    public var maxContextChars = 40_000

    public init(store: Store, llm: LLMProvider, model: String) {
        self.store = store
        self.llm = llm
        self.model = model
    }

    static let system = """
    You prepare the user for a meeting that is about to start, from their notes on past \
    meetings. Write a short brief in Markdown:
    ## Last time  (what was last discussed with these people or on this topic, 2-4 bullets)
    ## Open items  (action items from past meetings that look unfinished; write "None found" if none)
    ## Worth raising  (1-3 suggested topics or questions, only if the notes support them)
    Cite the meeting you draw on by title and date, like (Weekly sync, Nov 3). Use only the \
    records given; if they say little, say so in one line instead of padding.
    """

    /// Past-meeting context for the event. Exposed for tests.
    public func context(title: String, attendees: [String]) throws -> (text: String, meetings: [Meeting]) {
        // Attendee first names usually match how people are called in notes.
        let names = attendees.flatMap { $0.split(separator: " ").map(String.init) }
        let words = NotesChat.keywords(from: title) + names.map { $0.lowercased() }
        var seen = Set<String>()
        let keywords = words.filter { $0.count > 1 && seen.insert($0).inserted }
        let ranked = try store.rankMeetings(keywords: keywords, limit: maxMeetings).map(\.meeting)
        var blocks: [String] = []
        var used = 0
        var included: [Meeting] = []
        for meeting in ranked {
            let notes = meeting.enhancedNotes ?? meeting.userNotes
            let block = """
            <meeting title="\(meeting.displayTitle)" date="\(meeting.createdAt.formatted(date: .abbreviated, time: .shortened))">
            \(notes.isEmpty ? "(no notes)" : notes)
            </meeting>
            """
            if !included.isEmpty, used + block.count > maxContextChars { break }
            used += block.count
            blocks.append(block)
            included.append(meeting)
        }
        return (blocks.joined(separator: "\n\n"), included)
    }

    /// Streams the brief, yielding the full text so far. `sources` are the
    /// past meetings the brief draws on (empty = nothing relevant found).
    public func brief(title: String, attendees: [String], start: Date) throws
        -> (text: AsyncThrowingStream<String, Error>, sources: [Meeting])
    {
        let (context, sources) = try context(title: title, attendees: attendees)
        let prompt = """
        Upcoming meeting: \(title)
        Starts: \(start.formatted(date: .abbreviated, time: .shortened))
        \(attendees.isEmpty ? "" : "Attendees: \(attendees.joined(separator: ", "))")

        <meeting_records>
        \(context.isEmpty ? "(No related past meetings were found.)" : context)
        </meeting_records>
        """
        let request = LLMRequest(
            model: model,
            system: Self.system,
            messages: [ChatMessage(role: .user, text: prompt)],
            maxTokens: 4_000)
        return (llm.stream(request), sources)
    }
}
