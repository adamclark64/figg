import FiggStore
import Foundation
import Testing

@Suite struct StoreTests {
    let store = try! Store.inMemory()

    func meeting(_ title: String, notes: String = "", daysAgo: Double = 0, status: MeetingStatus = .ready) throws -> Meeting {
        let m = Meeting(title: title, createdAt: Date().addingTimeInterval(-daysAgo * 86_400), status: status, userNotes: notes)
        try store.save(m)
        return m
    }

    @Test func savesAndFetchesNewestFirst() throws {
        let old = try meeting("Old", daysAgo: 2)
        let new = try meeting("New")
        #expect(try store.allMeetings().map(\.id) == [new.id, old.id])
        #expect(try store.meeting(id: old.id)?.title == "Old")
    }

    @Test func transcriptOrderedByStart() throws {
        let m = try meeting("Sync")
        try store.append([
            TranscriptLine(meetingId: m.id, speaker: .them, start: 12, end: 14, text: "second"),
            TranscriptLine(meetingId: m.id, speaker: .me, start: 2, end: 4, text: "first"),
        ])
        #expect(try store.transcript(meetingId: m.id).map(\.text) == ["first", "second"])
    }

    @Test func searchFindsNotesAndTranscriptByPrefix() throws {
        let a = try meeting("Budget review", notes: "Q3 forecast")
        let b = try meeting("Standup")
        try store.append([TranscriptLine(meetingId: b.id, speaker: .them, start: 0, end: 1, text: "the migration is blocked")])
        _ = try meeting("Unrelated")

        #expect(try store.searchMeetings("forec").map(\.id) == [a.id])
        #expect(try store.searchMeetings("migrat").map(\.id) == [b.id])
        #expect(try store.searchMeetings("").count == 3)
    }

    @Test func searchSeesNoteUpdates() throws {
        let m = try meeting("Planning")
        try store.updateNotes(meetingId: m.id, userNotes: "kangaroo budget")
        #expect(try store.searchMeetings("kangaroo").map(\.id) == [m.id])
    }

    @Test func rankingPrefersMeetingWithMoreMatches() throws {
        let weak = try meeting("Weekly", notes: "pricing mentioned once")
        let strong = try meeting("Pricing deep dive", notes: "pricing tiers and pricing pages")
        try store.append((0..<5).map { TranscriptLine(meetingId: strong.id, speaker: .them, start: Double($0), end: Double($0) + 1, text: "pricing \($0)") })
        let ranked = try store.rankMeetings(keywords: ["pricing"], limit: 5).map(\.meeting.id)
        #expect(ranked.first == strong.id)
        #expect(ranked.contains(weak.id))
    }

    @Test func templateRoundTrips() throws {
        let m = try meeting("Sync")
        #expect(try store.meeting(id: m.id)?.template == nil)
        try store.update(meetingId: m.id) { $0.template = "standup" }
        #expect(try store.meeting(id: m.id)?.template == "standup")
        try store.update(meetingId: m.id) { $0.template = nil }
        #expect(try store.meeting(id: m.id)?.template == nil)
    }

    @Test func calendarFieldsRoundTrip() throws {
        let m = try meeting("Sync")
        #expect(try store.meeting(id: m.id)?.attendees == [])
        try store.update(meetingId: m.id) {
            $0.attendees = ["Jo Park", "Kai Reed"]
            $0.calendarEventId = "evt-1"
        }
        let loaded = try store.meeting(id: m.id)
        #expect(loaded?.attendees == ["Jo Park", "Kai Reed"])
        #expect(loaded?.calendarEventId == "evt-1")
    }

    @Test func renameSpeakerCoversDefaultAndDiarizedLabels() throws {
        let m = try meeting("Sync")
        try store.append([
            TranscriptLine(meetingId: m.id, speaker: .me, start: 0, end: 1, text: "hi"),
            TranscriptLine(meetingId: m.id, speaker: .them, start: 1, end: 2, text: "hello", speakerLabel: "Them 1"),
            TranscriptLine(meetingId: m.id, speaker: .them, start: 2, end: 3, text: "yo", speakerLabel: "Them 2"),
        ])
        try store.renameSpeaker(meetingId: m.id, from: "Them 1", to: "Ben")
        try store.renameSpeaker(meetingId: m.id, from: "Me", to: "Robin")
        try store.renameSpeaker(meetingId: m.id, from: "Them 2", to: "  ")  // blank: no change
        #expect(try store.transcript(meetingId: m.id).map(\.displaySpeaker) == ["Robin", "Ben", "Them 2"])

        // Renames don't leak into other meetings.
        let other = try meeting("Other")
        try store.append([TranscriptLine(meetingId: other.id, speaker: .me, start: 0, end: 1, text: "x")])
        try store.renameSpeaker(meetingId: m.id, from: "Robin", to: "A2")
        #expect(try store.transcript(meetingId: other.id).map(\.displaySpeaker) == ["Me"])
    }

    @Test func unfinishedMeetingsForRecovery() throws {
        let rec = try meeting("A", status: .recording)
        let tr = try meeting("B", status: .transcribing)
        _ = try meeting("C", status: .ready)
        _ = try meeting("D", status: .needsEnhance)
        #expect(Set(try store.unfinishedMeetings().map(\.id)) == [rec.id, tr.id])
    }

    @Test func deleteCascadesToTranscript() throws {
        let m = try meeting("Gone")
        try store.append([TranscriptLine(meetingId: m.id, speaker: .me, start: 0, end: 1, text: "hi")])
        try store.delete(meetingId: m.id)
        #expect(try store.transcript(meetingId: m.id).isEmpty)
        #expect(try store.meeting(id: m.id) == nil)
    }

    @Test func timestampFormat() {
        #expect(formatTimestamp(65) == "01:05")
        #expect(formatTimestamp(3725) == "1:02:05")
    }
}
