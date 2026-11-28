import FiggMCP
import FiggStore
import Foundation
import Testing

/// Made-up meetings in an in-memory store, read through the MCP tools.
/// Dates are checked in Denver time so "local day" is the same everywhere.
struct Fixture {
    static let planning = "AAAAAAAA-1111-4111-8111-111111111111"
    static let standup = "22222222-2222-2222-2222-222222222222"
    static let empty = "33333333-3333-3333-3333-333333333333"
    /// 20:30 on 2 March in Denver, which is already 3 March in UTC.
    static let evening = "44444444-4444-4444-4444-444444444444"

    let library: MeetingLibrary
    let tools = MCPTools(dates: MCPDates(timeZone: TimeZone(identifier: "America/Denver")!))

    init() throws {
        let store = try Store.inMemory()
        func at(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
        var planning = Meeting(id: Self.planning, title: "Garden planning", createdAt: at("2026-03-02T15:00:00Z"),
                               endedAt: at("2026-03-02T15:45:30Z"), status: .ready,
                               userNotes: "tomatoes by the fence", enhancedNotes: "## Summary\nPlant tomatoes in May.")
        planning.attendees = ["Nora", "Kai Reed"]
        try store.save(planning)
        try store.save(Meeting(id: Self.standup, createdAt: at("2026-03-04T09:00:00Z"), status: .recording))
        try store.save(Meeting(id: Self.empty, title: "Quiet one", createdAt: at("2026-02-20T12:00:00Z"),
                               endedAt: at("2026-02-20T12:05:00Z"), status: .ready))
        try store.save(Meeting(id: Self.evening, title: "Evening review", createdAt: at("2026-03-03T03:30:00Z"),
                               endedAt: at("2026-03-03T04:00:00Z"), status: .ready))
        _ = try store.append([
            TranscriptLine(meetingId: Self.planning, speaker: .them, start: 75, end: 80,
                           text: "The compost bins arrive Friday.", speakerLabel: "Them 2"),
            TranscriptLine(meetingId: Self.planning, speaker: .me, start: 3, end: 6, text: "Morning, shall we start with seeds?"),
            TranscriptLine(meetingId: Self.planning, speaker: .them, start: 10, end: 14, text: "Yes, seeds first."),
            TranscriptLine(meetingId: Self.standup, speaker: .me, start: 3700, end: 3705, text: "Wrapping up the hour."),
        ])
        library = MeetingLibrary(reader: store.db)
    }

    func call(_ name: String, _ args: [String: Any] = [:]) -> MCPTools.Result {
        tools.call(name, args, library: library)
    }

    func text(_ name: String, _ args: [String: Any] = [:]) -> String {
        call(name, args).text
    }
}

@Suite struct MCPDatesTests {
    let dates = MCPDates(timeZone: TimeZone(identifier: "America/Denver")!)

    @Test func bareDateIsTheWholeLocalDay() throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(iso.string(from: try dates.bound("2026-03-02", end: false)) == "2026-03-02T07:00:00.000Z")
        #expect(iso.string(from: try dates.bound("2026-03-02", end: true)) == "2026-03-03T06:59:59.999Z")
        #expect(iso.string(from: try dates.bound("2026-03-02T12:00:00Z", end: true)) == "2026-03-02T12:00:00.000Z")
        #expect(iso.string(from: try dates.bound("2026-03-02T12:00", end: true)) == "2026-03-02T19:00:00.000Z")
        #expect(throws: MCPError.self) { try dates.bound("soon", end: false) }
    }

    @Test func showsLocalTimeWithOffset() {
        let f = ISO8601DateFormatter()
        #expect(dates.show(f.date(from: "2026-03-03T03:30:00Z")!) == "2026-03-02 20:30 -07:00")
        #expect(dates.show(f.date(from: "2026-07-01T18:05:00Z")!) == "2026-07-01 12:05 -06:00")
    }
}

@Suite struct MCPToolsTests {
    @Test func listsNewestFirstWithLocalTimesAndPages() throws {
        let f = try Fixture()
        let all = f.text("list_meetings")
        let order = [Fixture.standup, Fixture.evening, Fixture.planning, Fixture.empty]
        let positions = order.map { all.range(of: $0)!.lowerBound }
        #expect(positions == positions.sorted())
        #expect(all.contains("2026-03-02 20:30 -07:00 · Evening review"))
        #expect(all.contains("Garden planning · 46 min · with Nora, Kai Reed"))
        #expect(all.contains("Untitled meeting · recording"))
        #expect(all.hasSuffix("(all 4 meetings)"))
        #expect(f.text("list_meetings", ["limit": 1]).contains("meetings 1 to 1 of 4; call again with offset 1"))
        #expect(f.text("list_meetings", ["offset": 3]).hasSuffix("(meetings 4 to 4 of 4)"))
        #expect(f.text("list_meetings", ["offset": 9]).contains("offset 9 is past the end: 4 meetings match"))
    }

    @Test func dateFiltersUseLocalDaysAndIncludeTheUntilDay() throws {
        let f = try Fixture()
        // 2 March local holds the planning meeting and the evening one,
        // which is 3 March in UTC.
        let day = f.text("list_meetings", ["since": "2026-03-02", "until": "2026-03-02"])
        #expect(day.contains(Fixture.evening) && day.contains(Fixture.planning))
        #expect(day.hasSuffix("(all 2 meetings)"))
        #expect(f.text("list_meetings", ["until": "2026-02-20"]).hasSuffix("(1 meeting)"))
        #expect(f.call("list_meetings", ["since": "whenever"]).isError)
    }

    @Test func searchSaysWhereEachMeetingMatched() throws {
        let f = try Fixture()
        let notes = f.text("search_meetings", ["query": "tomato"])
        #expect(notes.contains("matched in title or notes: **tomatoes** by the fence"))
        let spoken = f.text("search_meetings", ["query": "compost friday"])
        #expect(spoken.contains(Fixture.planning))
        #expect(spoken.contains("matched in transcript at 01:15: The **compost** bins arrive **Friday**."))
        #expect(f.text("search_meetings", ["query": "compost hour"]) == "No meetings match.")
        #expect(f.call("search_meetings").isError)
    }

    @Test func getMeetingShowsNotesInAnyIdCase() throws {
        let f = try Fixture()
        let out = f.text("get_meeting", ["id": Fixture.planning.lowercased()])
        #expect(out.hasPrefix("# Garden planning"))
        #expect(out.contains("- started: 2026-03-02 08:00 -07:00"))
        #expect(out.contains("- length: 46 min"))
        #expect(out.contains("tomatoes by the fence"))
        #expect(out.contains("Plant tomatoes in May."))
        let standup = f.text("get_meeting", ["id": Fixture.standup])
        #expect(standup.hasPrefix("# Untitled meeting"))
        #expect(standup.contains("(not enhanced yet)"))
        let missing = f.call("get_meeting", ["id": "nope"])
        #expect(missing.isError && missing.text == "No meeting with id nope.")
    }

    @Test func getMeetingsReadsSeveralInOrder() throws {
        let f = try Fixture()
        let parts = f.text("get_meetings", ["ids": [Fixture.evening, "nope", Fixture.planning]])
            .components(separatedBy: "\n\n---\n\n")
        #expect(parts.count == 3)
        #expect(parts[0].hasPrefix("# Evening review"))
        #expect(parts[1].contains("No meeting with id nope"))
        #expect(parts[2].hasPrefix("# Garden planning"))
        #expect(f.call("get_meetings", ["ids": [String]()]).isError)
        #expect(f.call("get_meetings", ["ids": Array(repeating: Fixture.planning, count: 21)]).isError)
    }

    @Test func transcriptPagesAndMarksTheEnd() throws {
        let f = try Fixture()
        let full = f.text("get_transcript", ["id": Fixture.planning.lowercased()])
        #expect(full.contains("[00:03] Me: Morning, shall we start with seeds?\n[00:10] Them: Yes, seeds first.\n[01:15] Them 2: The compost"))
        #expect(full.hasSuffix("(end of transcript: all 3 lines)"))
        #expect(f.text("get_transcript", ["id": Fixture.planning, "limit": 2]).contains("lines 1 to 2 of 3; call again with offset 2"))
        #expect(f.text("get_transcript", ["id": Fixture.planning, "offset": 2]).hasSuffix("(end of transcript: lines 3 to 3 of 3)"))
        #expect(f.text("get_transcript", ["id": Fixture.planning, "offset": 3]).contains("offset 3 is past the end: the transcript has 3 lines"))
        #expect(f.text("get_transcript", ["id": Fixture.empty]).hasSuffix("(no transcript)"))
        #expect(f.text("get_transcript", ["id": Fixture.standup]).contains("[1:01:40] Me: Wrapping up the hour."))
        #expect(f.call("delete_meeting").isError)
    }
}
