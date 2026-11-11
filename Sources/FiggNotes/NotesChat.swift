import FiggLLM
import FiggStore
import Foundation

/// "Ask figg": answers questions across past meetings. Retrieval is keyword
/// search (FTS5) over notes and transcripts; the best meetings go into the
/// prompt as context. No embeddings.
public struct NotesChat: Sendable {
    public let store: Store
    public let llm: LLMProvider
    public let model: String
    public var maxMeetings = 6
    public var maxContextChars = 60_000
    public var linesPerMeeting = 40

    public init(store: Store, llm: LLMProvider, model: String) {
        self.store = store
        self.llm = llm
        self.model = model
    }

    static let stopwords: Set<String> = [
        "a", "about", "all", "an", "and", "any", "are", "as", "at", "be", "been", "but", "by", "can",
        "could", "did", "do", "does", "for", "from", "had", "has", "have", "how", "i", "if", "in", "into",
        "is", "it", "its", "last", "me", "meeting", "meetings", "my", "of", "on", "or", "our", "said",
        "say", "should", "so", "that", "the", "their", "them", "there", "they", "this", "to", "us", "was",
        "we", "were", "what", "when", "where", "which", "who", "why", "will", "with", "would", "you", "your",
        "tell", "anything", "discuss", "discussed", "talk", "talked", "week", "today", "yesterday",
    ]

    public static func keywords(from question: String) -> [String] {
        var seen = Set<String>()
        return question.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !stopwords.contains($0) && seen.insert($0).inserted }
    }

    static let system = """
    You answer questions about the user's past meetings using only the meeting \
    records provided. Cite the meeting you draw on by its title and date, like \
    (Weekly sync, Nov 3). If the records do not contain the answer, say so plainly. \
    Be concise. "Me" in transcripts is the user.
    """

    /// Builds the context block for the question. Exposed for tests.
    public func context(for question: String) throws -> (text: String, meetings: [Meeting]) {
        let words = Self.keywords(from: question)
        var meetings = try store.rankMeetings(keywords: words, limit: maxMeetings).map(\.meeting)
        if meetings.isEmpty {
            meetings = try store.recentMeetings(limit: maxMeetings)
        }
        var blocks: [String] = []
        var used = 0
        var included: [Meeting] = []
        for meeting in meetings {
            let notes = meeting.enhancedNotes ?? meeting.userNotes
            let lines = words.isEmpty ? [] : try store.matchingLines(meetingId: meeting.id, keywords: words, limit: linesPerMeeting)
            let excerpt = lines.sorted { $0.start < $1.start }
                .map { "[\(formatTimestamp($0.start))] \($0.displaySpeaker): \($0.text)" }
                .joined(separator: "\n")
            var block = """
            <meeting title="\(meeting.displayTitle)" date="\(meeting.createdAt.formatted(date: .abbreviated, time: .shortened))">
            \(notes.isEmpty ? "(no notes)" : notes)
            """
            if !excerpt.isEmpty { block += "\n\nRelevant transcript lines:\n\(excerpt)" }
            block += "\n</meeting>"
            if used + block.count > maxContextChars {
                if included.isEmpty { block = String(block.prefix(maxContextChars)) } else { break }
            }
            used += block.count
            blocks.append(block)
            included.append(meeting)
        }
        return (blocks.joined(separator: "\n\n"), included)
    }

    /// Streams the answer. `history` is earlier turns of this chat.
    public func ask(_ question: String, history: [ChatMessage] = []) throws -> (answer: AsyncThrowingStream<String, Error>, sources: [Meeting]) {
        let (context, sources) = try context(for: question)
        let prompt = """
        <meeting_records>
        \(context.isEmpty ? "(There are no meetings yet.)" : context)
        </meeting_records>

        Question: \(question)
        """
        let request = LLMRequest(
            model: model,
            system: Self.system,
            messages: history + [ChatMessage(role: .user, text: prompt)],
            maxTokens: 8_000)
        return (llm.stream(request), sources)
    }
}
