import FiggLLM
import FiggStore
import Foundation

/// One-click outputs generated from a finished meeting: things people write
/// by hand right after a call. Results are shown to copy, not stored; they
/// can always be regenerated from the transcript.
public enum QuickAction: String, CaseIterable, Sendable, Identifiable {
    case followUpEmail
    case actionList
    case projectPlan

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .followUpEmail: return "Follow-up email"
        case .actionList: return "Action list"
        case .projectPlan: return "Project plan"
        }
    }

    public var icon: String {
        switch self {
        case .followUpEmail: return "envelope"
        case .actionList: return "checklist"
        case .projectPlan: return "list.number"
        }
    }

    var instructions: String {
        switch self {
        case .followUpEmail:
            return """
            Write a follow-up email from "Me" to the other attendees about this meeting.
            - Subject line first, as "Subject: ...".
            - Short and plain: what was decided, what happens next and who owns it, any open questions.
            - Only facts from the meeting. Use [name] where a name is needed but unknown.
            - No signature block.
            """
        case .actionList:
            return """
            List every action item, commitment or follow-up from this meeting as one flat
            Markdown checklist, ready to paste into a task tracker.
            - One "- [ ] Owner: task" line each ("- [ ] task" if no owner), with any deadline mentioned.
            - Include items implied by the conversation, not just ones stated as tasks.
            - Nothing but the checklist. Write "None" if there are none.
            """
        case .projectPlan:
            return """
            Turn this meeting into a short project plan in Markdown with exactly these sections:
            ## Goal (1-2 sentences), ## Workstreams (bullets, with owners where known),
            ## Milestones (bullets, with dates where mentioned), ## Risks (bullets).
            Only facts from the meeting; leave out a section's detail rather than invent it.
            """
        }
    }
}

extension Enhancer {
    static let quickActionSystem = """
    You produce one specific document from a meeting's notes and transcript, exactly as \
    instructed. Use only facts from the notes and transcript. "Me" in the transcript is \
    the person asking; speaker names are automatic and can be wrong, so use real names \
    only when the conversation makes them clear. Output the document only: no preamble, \
    no commentary.
    """

    public func quickActionRequest(_ action: QuickAction, meeting: Meeting, transcript: [TranscriptLine]) -> LLMRequest {
        let notes = meeting.userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = """
        Meeting: \(meeting.displayTitle)
        Date: \(meeting.createdAt.formatted(date: .complete, time: .shortened))

        <notes>
        \(meeting.enhancedNotes ?? (notes.isEmpty ? "(No notes.)" : notes))
        </notes>

        <transcript>
        \(transcript.isEmpty ? "(No transcript was captured.)" : Self.formatTranscript(transcript))
        </transcript>

        \(action.instructions)
        """
        return LLMRequest(
            model: models.notesModel,
            system: Self.quickActionSystem,
            messages: [ChatMessage(role: .user, text: body)],
            maxTokens: 8_000)
    }

    /// Streams the generated document, yielding the full text so far.
    public func run(_ action: QuickAction, meeting: Meeting, transcript: [TranscriptLine]) -> AsyncThrowingStream<String, Error> {
        let stream = llm.stream(quickActionRequest(action, meeting: meeting, transcript: transcript))
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
}
