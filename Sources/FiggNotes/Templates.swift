import Foundation

/// A meeting-type layout for enhanced notes: which sections the Enhancer
/// asks for between Summary (always first) and Action items (always last,
/// so `ActionItems.parse` and the Jira export keep working).
public struct NoteTemplate: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// Middle sections, in order, as "Heading | what goes in it".
    public let sections: [(heading: String, hint: String)]
    /// Extra style guidance for this meeting type, or empty.
    public let guidance: String

    public init(id: String, name: String, sections: [(heading: String, hint: String)], guidance: String = "") {
        self.id = id
        self.name = name
        self.sections = sections
        self.guidance = guidance
    }

    public static func == (a: NoteTemplate, b: NoteTemplate) -> Bool { a.id == b.id }

    /// General notes: what figg produced before templates existed.
    public static let standard = NoteTemplate(
        id: "notes", name: "Notes",
        sections: [("Notes", "bullets, grouped under ### sub-headings by topic when helpful")])

    public static let oneOnOne = NoteTemplate(
        id: "one-on-one", name: "1:1",
        sections: [
            ("Updates", "what each person reported since last time"),
            ("Discussion", "topics raised, grouped by topic; who said what when it matters"),
            ("Feedback", "feedback given in either direction; write \"None\" if there was none"),
        ],
        guidance: "This is a recurring one-on-one. Keep who-said-what clear.")

    public static let standup = NoteTemplate(
        id: "standup", name: "Standup",
        sections: [
            ("Yesterday", "what each person finished, one bullet per person"),
            ("Today", "what each person plans, one bullet per person"),
            ("Blockers", "anything blocking anyone, with who is blocked; write \"None\" if nothing"),
        ],
        guidance: "Group by person, not by topic.")

    public static let interview = NoteTemplate(
        id: "interview", name: "Interview",
        sections: [
            ("Background", "the candidate's experience as discussed"),
            ("Highlights", "strong answers and signals, with short verbatim quotes where notable"),
            ("Concerns", "weak answers, gaps or flags; write \"None\" if there were none"),
            ("Candidate questions", "what the candidate asked"),
        ],
        guidance: "Quote the candidate verbatim where the exact wording matters.")

    public static let customerCall = NoteTemplate(
        id: "customer-call", name: "Customer call",
        sections: [
            ("Context", "who the customer is and why the call happened"),
            ("Needs and pain points", "what they are trying to do and what hurts today"),
            ("Objections and questions", "pushback and open questions, with how they were answered"),
            ("Next steps", "what was agreed, with dates"),
        ])

    public static let brainstorm = NoteTemplate(
        id: "brainstorm", name: "Brainstorm",
        sections: [
            ("Ideas", "every idea raised, one bullet each, with who raised it"),
            ("Themes", "how the ideas group together"),
            ("Parked", "ideas set aside and why; write \"None\" if nothing was parked"),
        ],
        guidance: "Capture every idea, including ones that were dismissed.")

    public static let planning = NoteTemplate(
        id: "planning", name: "Planning",
        sections: [
            ("Goals", "what the plan is trying to achieve"),
            ("Decisions", "what was decided, with the reasoning"),
            ("Risks", "what could go wrong and any mitigation discussed"),
            ("Timeline", "dates and milestones mentioned"),
        ])

    public static let all: [NoteTemplate] = [.standard, .oneOnOne, .standup, .interview, .customerCall, .brainstorm, .planning]

    /// The template with that id, or the standard one for nil or unknown ids
    /// (an old config or database value never breaks enhancement).
    public static func named(_ id: String?) -> NoteTemplate {
        all.first { $0.id == id } ?? .standard
    }

    /// The "exactly these sections" block of the Enhancer system prompt.
    var sectionSpec: String {
        var lines = ["  ## Summary  (2-4 sentences)"]
        lines += sections.map { "  ## \($0.heading)  (\($0.hint))" }
        lines.append("  ## Action items  (each as \"- [ ] Owner: task\", or \"- [ ] task\" if no owner; write \"None\" if there are none)")
        return lines.joined(separator: "\n")
    }
}
