@testable import FiggMeetingApps
import Foundation
import Testing

@Suite struct SpeakerTimelineMuteTests {
    typealias Stretch = SpeakerTimeline.Stretch

    func snap(muted: Bool?, speaking: String? = nil) -> MeetingAppSnapshot {
        MeetingAppSnapshot(app: "zoom", participants: [.init(name: "Bill")], selfName: "Sam", speaking: speaking, selfMuted: muted)
    }

    /// Records `readings` (time, snapshot) at a 0.5 s interval into a fresh timeline.
    func timeline(_ readings: [(Double, MeetingAppSnapshot?)], names: Bool = true) -> SpeakerTimeline {
        var t = SpeakerTimeline(app: "zoom")
        var tracker = MuteTracker()
        for (time, s) in readings { t.record(s, at: time, interval: 0.5, names: names, tracker: &tracker) }
        return t
    }

    @Test func consecutiveMutedReadingsJoin() {
        let t = timeline([(0, snap(muted: true)), (0.5, snap(muted: true)), (1.0, snap(muted: true))])
        #expect(t.muted == [Stretch(start: 0, end: 1.5)])
    }

    @Test func unevenSpacingNeverSpansAnUnmutedReading() {
        let t = timeline([(0.1, snap(muted: true)), (0.5, snap(muted: false)), (0.8, snap(muted: true))])
        #expect(t.muted == [Stretch(start: 0.1, end: 0.5), Stretch(start: 0.8, end: 1.3)])
    }

    @Test func slowPollJoinsAndMissedPollSplits() {
        let slow = timeline([(0, snap(muted: true)), (0.8, snap(muted: true))])
        #expect(slow.muted == [Stretch(start: 0, end: 1.3)])
        let missed = timeline([(0, snap(muted: true)), (1.5, snap(muted: true))])
        #expect(missed.muted == [Stretch(start: 0, end: 0.5), Stretch(start: 1.5, end: 2.0)])
    }

    @Test func nilUnmutedOrUnknownReadingEndsAStretchAtItsTime() {
        for ending in [nil, snap(muted: false), snap(muted: nil)] as [MeetingAppSnapshot?] {
            let t = timeline([(0, snap(muted: true)), (0.5, snap(muted: true)), (0.7, ending), (1.0, ending)])
            #expect(t.muted == [Stretch(start: 0, end: 0.7)])
        }
    }

    @Test func noMuteReadingsGiveNoStretches() {
        let t = timeline([(0, snap(muted: false)), (0.5, snap(muted: nil)), (1.0, nil)])
        #expect(t.muted.isEmpty)
    }

    @Test func mutedShareCountsOverlap() {
        let t = SpeakerTimeline(app: "zoom", muted: [Stretch(start: 2, end: 4), Stretch(start: 6, end: 7)])
        #expect(t.mutedShare(start: 0, end: 10) == 0.3)
        #expect(t.mutedShare(start: 3, end: 5) == 0.5)
        #expect(t.mutedShare(start: 2, end: 4) == 1)
        #expect(t.mutedShare(start: 4, end: 6) == 0)
        #expect(t.mutedShare(start: 3, end: 3) == 0)
        #expect(t.mutedShare(start: 5, end: 3) == 0)
        #expect(SpeakerTimeline(app: "zoom").mutedShare(start: 0, end: 10) == 0)
    }

    @Test func namesOffRecordsOnlyMute() {
        let t = timeline([(0, snap(muted: true, speaking: "Bill")), (0.5, snap(muted: true, speaking: "Bill"))], names: false)
        #expect(t.muted == [Stretch(start: 0, end: 1.0)])
        #expect(t.spans.isEmpty)
        #expect(t.participants.isEmpty)
        #expect(t.selfName == nil)
    }

    @Test func namesOnStillRecordsSpans() {
        let t = timeline([(0, snap(muted: true, speaking: "Bill")), (0.5, snap(muted: false, speaking: "Bill"))])
        #expect(t.spans == [.init(start: 0, end: 1.0, name: "Bill")])
        #expect(t.participants == ["Bill"])
        #expect(t.selfName == "Sam")
        #expect(t.muted == [Stretch(start: 0, end: 0.5)])
    }

    @Test func savesAndLoadsStretches() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        let t = SpeakerTimeline(app: "zoom", spans: [.init(start: 1, end: 2, name: "Bill")], participants: ["Bill"], selfName: "Sam",
                                muted: [Stretch(start: 3, end: 4.5)])
        try t.save(to: url)
        #expect(SpeakerTimeline.load(from: url) == t)
        try? FileManager.default.removeItem(at: url)
    }

    @Test func todaysFormatLoadsWithNoStretches() throws {
        let json = #"{"app":"zoom","spans":[{"start":1,"end":2.5,"name":"Bill"}],"participants":["Bill","Nora"],"selfName":"Sam"}"#
        let t = try JSONDecoder().decode(SpeakerTimeline.self, from: Data(json.utf8))
        #expect(t.muted == [])
        #expect(t.spans == [.init(start: 1, end: 2.5, name: "Bill")])
        #expect(t.participants == ["Bill", "Nora"])
        #expect(t.selfName == "Sam")
    }

    @Test func watcherWithOnlyStretchesStillSaves() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        let muted = snap(muted: true, speaking: "Bill")
        let ticker = Ticker()
        let w = SpeakerWatcher(meetingId: "m", app: "zoom", reader: FakeReader([muted, muted, muted]), file: url, names: false, clock: { ticker.time })
        for i in 0..<3 { ticker.time = Double(i) * 0.5; w.poll() }
        w.stop()
        #expect(w.current.spans.isEmpty)
        #expect(w.current.participants.isEmpty)
        #expect(w.current.muted == [Stretch(start: 0, end: 1.5)])
        #expect(SpeakerTimeline.load(from: url) == w.current)
        try? FileManager.default.removeItem(at: url)
    }

    @Test func slotMutedShareNeedsThatMeetingsWatcher() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        let slot = SpeakerWatcherSlot()
        #expect(slot.mutedShare(meetingId: "m", start: 0, end: 1) == nil)

        let muted = snap(muted: true)
        let ticker = Ticker()
        let w = SpeakerWatcher(meetingId: "m", app: "zoom", reader: FakeReader([muted, muted]), file: url, clock: { ticker.time })
        for i in 0..<2 { ticker.time = Double(i) * 0.5; w.poll() }
        slot.set(w)
        #expect(slot.mutedShare(meetingId: "m", start: 0, end: 1) == 1)
        #expect(slot.mutedShare(meetingId: "m", start: 1, end: 2) == 0)
        #expect(slot.mutedShare(meetingId: "other", start: 0, end: 1) == nil)
        w.stop()
        try? FileManager.default.removeItem(at: url)
    }
}
