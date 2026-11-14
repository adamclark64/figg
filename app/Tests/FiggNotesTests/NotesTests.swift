@testable import FiggNotes
import FiggLLM
import FiggStore
import Foundation
import Testing

/// Replies with canned text and records what it was asked.
final class FakeLLM: LLMProvider, @unchecked Sendable {
    var reply: String
    var requests: [LLMRequest] = []
    init(reply: String) { self.reply = reply }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        requests.append(request)
        let words = reply.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        return AsyncThrowingStream { c in
            for (i, w) in words.enumerated() { c.yield(i == 0 ? w : " " + w) }
            c.finish()
        }
    }
}

let models = ModelChoice(notesModel: "notes-model", fastModel: "fast-model")

@Suite struct EnhancerTests {
    @Test func promptContainsNotesAndLabelledTranscript() {
        let m = Meeting(title: "Sync", userNotes: "- ship friday")
        let lines = [
            TranscriptLine(meetingId: m.id, speaker: .me, start: 5, end: 6, text: "Can we ship Friday?"),
            TranscriptLine(meetingId: m.id, speaker: .them, start: 65, end: 66, text: "Yes."),
        ]
        let req = Enhancer(llm: FakeLLM(reply: ""), models: models).request(meeting: m, transcript: lines)
        #expect(req.model == "notes-model")
        let text = req.messages[0].text
        #expect(text.contains("<my_notes>\n- ship friday\n</my_notes>"))
        #expect(text.contains("[00:05] Me: Can we ship Friday?\n[01:05] Them: Yes."))
    }

    @Test func streamsAccumulatedText() async throws {
        let e = Enhancer(llm: FakeLLM(reply: "## Summary all good"), models: models)
        var last = ""
        for try await t in e.enhance(meeting: Meeting(), transcript: []) { last = t }
        #expect(last == "## Summary all good")
    }

    @Test func attendeesAppearInThePromptWhenKnown() {
        var m = Meeting(title: "Sync")
        m.attendees = ["Jo Park", "Kai Reed"]
        let e = Enhancer(llm: FakeLLM(reply: ""), models: models)
        let req = e.request(meeting: m, transcript: [])
        #expect(req.messages[0].text.contains("Attendees (from the calendar): Jo Park, Kai Reed"))
        #expect(req.system.contains("attendee list"))
        let bare = e.request(meeting: Meeting(), transcript: [])
        #expect(!bare.messages[0].text.contains("Attendees"))
    }

    @Test func templateShapesTheSystemPrompt() {
        let req = Enhancer(llm: FakeLLM(reply: ""), models: models)
            .request(meeting: Meeting(), transcript: [], template: .standup)
        let system = req.system
        #expect(system.contains("## Yesterday"))
        #expect(system.contains("## Today"))
        #expect(system.contains("## Blockers"))
        #expect(system.contains("Group by person, not by topic."))
        // Every template keeps the sections exports and parsing rely on.
        #expect(system.contains("## Summary"))
        #expect(system.contains("## Action items"))
        #expect(!system.contains("### sub-headings"))
    }

    @Test func defaultTemplateKeepsTheOriginalSections() {
        let system = Enhancer.system(template: .standard)
        #expect(system.contains("## Notes"))
        #expect(system.contains("### sub-headings"))
        #expect(NoteTemplate.named(nil) == .standard)
        #expect(NoteTemplate.named("no-such-template") == .standard)
        #expect(NoteTemplate.named("one-on-one") == .oneOnOne)
    }

    @Test func titleIsCleanedAndUsesFastModel() async throws {
        let llm = FakeLLM(reply: "\"Q3 Budget Review.\"\nextra")
        let title = try await Enhancer(llm: llm, models: models).suggestTitle(meeting: Meeting(), transcript: [])
        #expect(title == "Q3 Budget Review")
        #expect(llm.requests[0].model == "fast-model")
    }
}

@Suite struct QuickActionTests {
    @Test func requestCarriesTranscriptAndInstructions() {
        let m = Meeting(title: "Kickoff", userNotes: "- budget 10k")
        let lines = [TranscriptLine(meetingId: m.id, speaker: .them, start: 1, end: 2, text: "Launch is March 3.")]
        let e = Enhancer(llm: FakeLLM(reply: ""), models: models)
        let req = e.quickActionRequest(.followUpEmail, meeting: m, transcript: lines)
        #expect(req.model == "notes-model")
        #expect(req.messages[0].text.contains("Launch is March 3."))
        #expect(req.messages[0].text.contains("Subject"))
        #expect(req.system.contains("no preamble"))
    }

    @Test func prefersEnhancedNotesOverRoughOnes() {
        var m = Meeting(userNotes: "rough scribble")
        m.enhancedNotes = "## Summary\nPolished."
        let req = Enhancer(llm: FakeLLM(reply: ""), models: models).quickActionRequest(.actionList, meeting: m, transcript: [])
        #expect(req.messages[0].text.contains("Polished."))
        #expect(!req.messages[0].text.contains("rough scribble"))
    }

    @Test func streamsAccumulatedDocument() async throws {
        let e = Enhancer(llm: FakeLLM(reply: "- [ ] Ben: send deck"), models: models)
        var last = ""
        for try await t in e.run(.actionList, meeting: Meeting(), transcript: []) { last = t }
        #expect(last == "- [ ] Ben: send deck")
    }

    @Test func everyActionHasNameAndIcon() {
        for action in QuickAction.allCases {
            #expect(!action.name.isEmpty)
            #expect(!action.icon.isEmpty)
        }
    }
}

@Suite struct BriefTests {
    @Test func findsPastMeetingsByTitleAndAttendeeNames() throws {
        let store = try Store.inMemory()
        var past = Meeting(title: "Budget sync", userNotes: "")
        past.enhancedNotes = "## Summary\nBen agreed to cut the forecast."
        try store.save(past)
        try store.save(Meeting(title: "Unrelated", userNotes: "gardening"))

        let brief = MeetingBrief(store: store, llm: FakeLLM(reply: ""), model: "notes-model")
        let (text, meetings) = try brief.context(title: "Budget follow-up", attendees: ["Kai Reed"])
        #expect(meetings.map(\.id) == [past.id])
        #expect(text.contains("cut the forecast"))
    }

    @Test func promptCarriesEventAndRecords() throws {
        let store = try Store.inMemory()
        try store.save(Meeting(title: "Budget sync", userNotes: "forecast is tight"))
        let llm = FakeLLM(reply: "## Last time\n- budget")
        let brief = MeetingBrief(store: store, llm: llm, model: "notes-model")
        let (_, sources) = try brief.brief(title: "Budget follow-up", attendees: ["Ben"], start: Date())
        #expect(sources.count == 1)
        #expect(llm.requests[0].messages[0].text.contains("Upcoming meeting: Budget follow-up"))
        #expect(llm.requests[0].messages[0].text.contains("Attendees: Ben"))
        #expect(llm.requests[0].system.contains("## Last time"))
    }
}

@Suite struct ProvenanceTests {
    @Test func marksUserLinesIgnoringFormatting() {
        let enhanced = """
        ## Notes
        - Ship Friday!
          - QA signs off Thursday
        * budget ok
        """
        let lines = Provenance.mark(enhanced: enhanced, userNotes: "ship friday\n- Budget OK")
        #expect(lines.map(\.isUsers) == [false, true, false, true])
    }

    @Test func blankLinesAreNeverUsers() {
        #expect(Provenance.mark(enhanced: "\n", userNotes: "\n").allSatisfy { !$0.isUsers })
    }
}

@Suite struct ActionItemTests {
    @Test func parsesOwnersAndCheckboxes() {
        let md = """
        ## Summary
        - [ ] not an action
        ## Action items
        - [ ] Ben: send the deck
        - [x] **Nora**: book room
        - [ ] Follow up on the vendor contract and also the renewal: due soon after we hear back
        ## Other
        - [ ] ignored
        """
        let items = ActionItems.parse(md)
        #expect(items.count == 3)
        #expect(items[0].owner == "Ben" && items[0].task == "send the deck" && !items[0].done)
        #expect(items[1].owner == "Nora" && items[1].done)
        #expect(items[2].owner == nil)
        #expect(items[0].summary == "Ben: send the deck")
    }

    @Test func noneMeansEmpty() {
        #expect(ActionItems.parse("## Action items\n- None").isEmpty)
    }
}

@Suite struct CheckboxTests {
    let md = "## Action items\n- [ ] Ben: send the deck\n- [x] Nora: book room\n  * [X] nested\n+ [ ] plus\n- plain bullet"

    @Test func matchesCheckboxLinesOnly() {
        #expect(Checkboxes.match("- [ ] Ben: send the deck")?.done == false)
        #expect(Checkboxes.match("  * [X] nested")?.done == true)
        #expect(Checkboxes.match("+ [x] plus ")?.label == "plus")
        #expect(Checkboxes.match("- plain bullet") == nil)
        #expect(Checkboxes.match("- [ ]") == nil)
        #expect(Checkboxes.match("## [ ] heading") == nil)
    }

    @Test func togglesOnlyTheGivenLine() {
        #expect(Checkboxes.toggle(md, line: 1) == md.replacingOccurrences(of: "- [ ] Ben", with: "- [x] Ben"))
        #expect(Checkboxes.toggle(md, line: 2) == md.replacingOccurrences(of: "- [x] Nora", with: "- [ ] Nora"))
        #expect(Checkboxes.toggle(md, line: 3) == md.replacingOccurrences(of: "* [X] nested", with: "* [ ] nested"))
        #expect(Checkboxes.toggle(md, line: 4) == md.replacingOccurrences(of: "+ [ ] plus", with: "+ [x] plus"))
    }

    @Test func togglingTwiceRestoresTheOriginal() {
        #expect(Checkboxes.toggle(Checkboxes.toggle(md, line: 1), line: 1) == md)
    }

    @Test func leavesOtherLinesAndBadIndexesAlone() {
        #expect(Checkboxes.toggle(md, line: 0) == md)   // heading
        #expect(Checkboxes.toggle(md, line: 5) == md)   // plain bullet
        #expect(Checkboxes.toggle(md, line: 6) == md)   // past the end
        #expect(Checkboxes.toggle(md, line: -1) == md)
        #expect(Checkboxes.toggle("", line: 0) == "")
    }

    /// The index the view passes is `NoteLine.id`, so the two must count
    /// lines the same way, including CRLF notes pasted in by hand.
    @Test func lineNumbersAgreeWithProvenance() {
        let crlf = "## Action items\r\n- [ ] one\r\n- [ ] two [link](x)\r\n"
        let lines = Provenance.mark(enhanced: crlf, userNotes: "")
        let two = lines.first { $0.text.contains("two") }!
        let toggled = Checkboxes.toggle(crlf, line: two.id)
        #expect(toggled == "## Action items\r\n- [ ] one\r\n- [x] two [link](x)\r\n")
        #expect(ActionItems.parse(toggled).map(\.done) == [false, true])
    }
}

@Suite struct ChatTests {
    @Test func keywordsDropStopwords() {
        #expect(NotesChat.keywords(from: "What did we decide about the Q3 pricing?") == ["decide", "q3", "pricing"])
    }

    @Test func contextUsesMatchingMeetingsAndLines() throws {
        let store = try Store.inMemory()
        let hit = Meeting(title: "Pricing review", status: .ready, userNotes: "tiers", enhancedNotes: "## Summary\nNew pricing tiers")
        let miss = Meeting(title: "Offsite", status: .ready, userNotes: "venue")
        try store.save(hit)
        try store.save(miss)
        try store.append([TranscriptLine(meetingId: hit.id, speaker: .them, start: 30, end: 31, text: "pricing goes up in March")])

        let chat = NotesChat(store: store, llm: FakeLLM(reply: ""), model: "m")
        let (text, meetings) = try chat.context(for: "what about pricing")
        #expect(meetings.map(\.id) == [hit.id])
        #expect(text.contains("New pricing tiers"))
        #expect(text.contains("[00:30] Them: pricing goes up in March"))
    }

    @Test func fallsBackToRecentMeetings() throws {
        let store = try Store.inMemory()
        try store.save(Meeting(title: "Only one", status: .ready))
        let chat = NotesChat(store: store, llm: FakeLLM(reply: ""), model: "m")
        #expect(try chat.context(for: "zebra").meetings.count == 1)
    }

    @Test func respectsContextBudget() throws {
        let store = try Store.inMemory()
        for i in 0..<5 {
            try store.save(Meeting(title: "Pricing \(i)", status: .ready, userNotes: "pricing " + String(repeating: "x", count: 5_000)))
        }
        var chat = NotesChat(store: store, llm: FakeLLM(reply: ""), model: "m")
        chat.maxContextChars = 12_000
        let (text, meetings) = try chat.context(for: "pricing")
        #expect(meetings.count == 2)
        #expect(text.count <= 12_100)
    }
}
