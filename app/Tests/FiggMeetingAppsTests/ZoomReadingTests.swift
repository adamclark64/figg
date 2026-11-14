@testable import FiggMeetingApps
import Foundation
import Testing

@Suite struct ZoomReadingTests {
    @Test func tileLabelsGiveNameAndMute() {
        // Labels as Zoom 7.1.9 writes them.
        #expect(ZoomReading.participant(fromTileLabel: "Bill Ortiz, Computer audio muted, Video off") == Participant(name: "Bill Ortiz", muted: true))
        #expect(ZoomReading.participant(fromTileLabel: "Bill Ortiz, Computer audio unmuted") == Participant(name: "Bill Ortiz", muted: false))
        #expect(ZoomReading.participant(fromTileLabel: "Bill Ortiz, No audio connected, Video off") == Participant(name: "Bill Ortiz", muted: nil))
        #expect(ZoomReading.participant(fromTileLabel: "Ortiz, Bill, Computer audio unmuted")?.name == "Ortiz, Bill")
        #expect(ZoomReading.participant(fromTileLabel: "") == nil)
    }

    @Test func accountButtonGivesSelfName() {
        #expect(ZoomReading.selfName(fromAccountButton: "Zoom, Sam Lee, In a Zoom Meeting, Basic account") == "Sam Lee")
        #expect(ZoomReading.selfName(fromAccountButton: "Settings") == nil)
    }

    @Test func speakerViewMainTileIsSpeaking() {
        let tiles = [
            ZoomReading.Tile(label: "Bill Ortiz, Computer audio unmuted", width: 1710, height: 961),
            ZoomReading.Tile(label: "Sam Lee, Computer audio unmuted", width: 240, height: 135),
            ZoomReading.Tile(label: "Nora Hale, Computer audio unmuted", width: 240, height: 135),
        ]
        let s = ZoomReading.snapshot(tiles: tiles, windowWidth: 1710, windowHeight: 1080, selfName: "Sam Lee")
        #expect(s.speaking == "Bill Ortiz")
        #expect(s.participants.map(\.name) == ["Bill Ortiz", "Sam Lee", "Nora Hale"])
    }

    @Test func mainTileThatIsYouOrMutedIsNotSpeaking() {
        let me = [ZoomReading.Tile(label: "Sam Lee, Computer audio unmuted", width: 1710, height: 961)]
        #expect(ZoomReading.snapshot(tiles: me, windowWidth: 1710, windowHeight: 1080, selfName: "Sam Lee").speaking == nil)
        let muted = [ZoomReading.Tile(label: "Bill Ortiz, Computer audio muted", width: 1710, height: 961)]
        #expect(ZoomReading.snapshot(tiles: muted, windowWidth: 1710, windowHeight: 1080, selfName: "Sam Lee").speaking == nil)
    }

    @Test func galleryWithOneOtherUnmutedNamesThem() {
        let tiles = [
            ZoomReading.Tile(label: "Sam Lee, Computer audio unmuted", width: 850, height: 480),
            ZoomReading.Tile(label: "Bill Ortiz, Computer audio unmuted", width: 850, height: 480),
            ZoomReading.Tile(label: "Nora Hale, Computer audio muted", width: 850, height: 480),
        ]
        #expect(ZoomReading.snapshot(tiles: tiles, windowWidth: 1710, windowHeight: 1080, selfName: "Sam Lee").speaking == "Bill Ortiz")
        // Without knowing who you are, an unmuted tile could be you.
        #expect(ZoomReading.snapshot(tiles: tiles, windowWidth: 1710, windowHeight: 1080, selfName: nil).speaking == nil)
    }

    @Test func galleryWithTwoOthersUnmutedIsUnclear() {
        let tiles = [
            ZoomReading.Tile(label: "Sam Lee, Computer audio unmuted", width: 850, height: 480),
            ZoomReading.Tile(label: "Bill Ortiz, Computer audio unmuted", width: 850, height: 480),
            ZoomReading.Tile(label: "Nora Hale, Computer audio unmuted", width: 850, height: 480),
        ]
        #expect(ZoomReading.snapshot(tiles: tiles, windowWidth: 1710, windowHeight: 1080, selfName: "Sam Lee").speaking == nil)
    }
}

@Suite struct SpeakerTimelineTests {
    func snap(_ speaking: String?) -> MeetingAppSnapshot {
        MeetingAppSnapshot(app: "zoom", participants: [.init(name: "Bill"), .init(name: "Nora")], selfName: "Sam", speaking: speaking)
    }

    @Test func readingsJoinIntoSpans() {
        var t = SpeakerTimeline(app: "zoom")
        for (i, who) in ["Bill", "Bill", "Bill", nil, "Nora", "Nora"].enumerated() {
            t.record(snap(who), at: Double(i) * 0.5, interval: 0.5)
        }
        t.record(nil, at: 3, interval: 0.5)   // unreadable: ignored
        #expect(t.spans == [.init(start: 0, end: 1.5, name: "Bill"), .init(start: 2, end: 3, name: "Nora")])
        #expect(t.participants == ["Bill", "Nora"])
        #expect(t.selfName == "Sam")
    }

    @Test func longGapStartsANewSpan() {
        var t = SpeakerTimeline(app: "zoom")
        t.record(snap("Bill"), at: 0, interval: 0.5)
        t.record(snap("Bill"), at: 10, interval: 0.5)
        #expect(t.spans.count == 2)
    }

    @Test func nameNeedsMostOfTheStretch() {
        let t = SpeakerTimeline(app: "zoom", spans: [.init(start: 0, end: 7, name: "Bill"), .init(start: 7, end: 10, name: "Nora")])
        #expect(t.name(start: 0, end: 10) == "Bill")     // 70%
        #expect(t.name(start: 4, end: 10) == nil)        // 50/50
        #expect(t.name(start: 20, end: 25) == nil)
    }

    @Test func savesAndLoads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        let t = SpeakerTimeline(app: "zoom", spans: [.init(start: 1, end: 2, name: "Bill")], participants: ["Bill"], selfName: "Sam")
        try t.save(to: url)
        #expect(SpeakerTimeline.load(from: url) == t)
        try? FileManager.default.removeItem(at: url)
    }
}

/// Plays back a fixed list of readings.
final class FakeReader: MeetingAppReader, @unchecked Sendable {
    private let lock = NSLock()
    private var readings: [MeetingAppSnapshot?]
    init(_ readings: [MeetingAppSnapshot?]) { self.readings = readings }
    func read() -> MeetingAppSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return readings.isEmpty ? nil : readings.removeFirst()
    }
}

final class Ticker: @unchecked Sendable {
    var time = 0.0
}

@Suite struct SpeakerWatcherTests {
    @Test func pollsBuildAndSaveTheTimeline() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        let bill = MeetingAppSnapshot(app: "zoom", participants: [.init(name: "Bill")], speaking: "Bill")
        let ticker = Ticker()
        let w = SpeakerWatcher(meetingId: "m", app: "zoom", reader: FakeReader([bill, bill, nil, bill]), file: url, clock: { ticker.time })
        for i in 0..<4 { ticker.time = Double(i) * 0.5; w.poll() }
        w.stop()
        #expect(w.current.spans == [.init(start: 0, end: 2, name: "Bill")])
        #expect(SpeakerTimeline.load(from: url) == w.current)

        let slot = SpeakerWatcherSlot()
        slot.set(w)
        #expect(slot.name(meetingId: "m", start: 0, end: 2) == "Bill")
        #expect(slot.name(meetingId: "other", start: 0, end: 2) == nil)
        try? FileManager.default.removeItem(at: url)
    }
}
