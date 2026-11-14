import FiggLLM
import FiggStore
import Foundation

public struct ModelChoice: Sendable {
    /// Enhanced notes and chat.
    public var notesModel: String
    /// Short, cheap calls such as meeting titles.
    public var fastModel: String

    public init(notesModel: String, fastModel: String) {
        self.notesModel = notesModel
        self.fastModel = fastModel
    }
}

/// Turns the user's rough notes plus the transcript into finished notes.
public struct Enhancer: Sendable {
    public let llm: LLMProvider
    public let models: ModelChoice

    public init(llm: LLMProvider, models: ModelChoice) {
        self.llm = llm
        self.models = models
    }

    static func system(template: NoteTemplate) -> String {
        var prompt = """
        You turn a person's rough meeting notes and the meeting transcript into clear, \
        accurate meeting notes.

        Rules:
        - Keep every line the person wrote, word for word, in a sensible place. You may \
        add detail underneath their lines, but never reword or delete them.
        - Add what they missed that matters: decisions, numbers, dates, owners, open questions.
        - Use only facts from the transcript or their notes. If something is unclear in \
        the transcript, leave it out rather than guess.
        - "Me" in the transcript is the person taking notes. "Them" is everyone else on the call; \
        "Them 1", "Them 2" are different people on the call, and "Guest 1", "Guest 2" are other \
        people in the room. Speaker names are automatic and can be wrong; if the transcript makes \
        someone's real name clear, use it. When an attendee list is given, prefer those names, \
        but only where the conversation makes the match clear.
        - Output Markdown only, with exactly these sections:
        \(template.sectionSpec)
        - Do not include a title line; the app shows the title separately.
        """
        if !template.guidance.isEmpty { prompt += "\n- \(template.guidance)" }
        return prompt
    }

    public static func formatTranscript(_ lines: [TranscriptLine]) -> String {
        lines.map { "[\(formatTimestamp($0.start))] \($0.displaySpeaker): \($0.text)" }.joined(separator: "\n")
    }

    public func request(meeting: Meeting, transcript: [TranscriptLine], template: NoteTemplate = .standard) -> LLMRequest {
        let notes = meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let attendees = meeting.attendees.isEmpty ? ""
            : "\nAttendees (from the calendar): \(meeting.attendees.joined(separator: ", "))"
        let body = """
        Meeting: \(meeting.displayTitle)
        Date: \(meeting.createdAt.formatted(date: .complete, time: .shortened))\(attendees)

        <my_notes>
        \(notes.isEmpty ? "(I took no notes.)" : notes)
        </my_notes>

        <transcript>
        \(transcript.isEmpty ? "(No transcript was captured.)" : Self.formatTranscript(transcript))
        </transcript>
        """
        return LLMRequest(
            model: models.notesModel,
            system: Self.system(template: template),
            messages: [ChatMessage(role: .user, text: body)],
            maxTokens: 16_000)
    }

    /// Streams the enhanced notes, yielding the full text so far on each update.
    public func enhance(meeting: Meeting, transcript: [TranscriptLine], template: NoteTemplate = .standard) -> AsyncThrowingStream<String, Error> {
        let stream = llm.stream(request(meeting: meeting, transcript: transcript, template: template))
        return AsyncThrowingStream { continuation in
            let task = Task {
                var text = ""
                do {
                    for try await delta in stream {
                        text += delta
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A short title from the first part of the meeting.
    public func suggestTitle(meeting: Meeting, transcript: [TranscriptLine]) async throws -> String {
        let excerpt = String(Self.formatTranscript(transcript).prefix(12_000))
        let request = LLMRequest(
            model: models.fastModel,
            system: "You name meetings. Reply with only a title of 2-6 words, no quotes, no trailing punctuation.",
            messages: [ChatMessage(role: .user, text: "Notes:\n\(meeting.userNotes)\n\nTranscript excerpt:\n\(excerpt)")],
            // Haiku 5.5 thinks before answering and thinking counts toward
            // maxTokens; a tight limit returns an empty title.
            maxTokens: 2_000)
        let raw = try await llm.complete(request)
        return Self.cleanTitle(raw)
    }

    static func cleanTitle(_ raw: String) -> String {
        let firstLine = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return firstLine
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'#*.").union(.whitespaces))
    }
}
