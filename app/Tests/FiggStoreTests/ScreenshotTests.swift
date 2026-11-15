@testable import FiggStore
import Foundation
import Testing

@Suite struct ScreenshotTests {
    @Test func namesRoundTripAndOthersAreIgnored() {
        let name = MeetingScreenshot.fileName(offset: 83.25)
        #expect(name == "shot_0000083250.png")
        #expect(MeetingScreenshot(url: URL(fileURLWithPath: "/tmp/\(name)"))?.offset == 83.25)
        #expect(MeetingScreenshot(url: URL(fileURLWithPath: "/tmp/mic_0000083250.caf")) == nil)
        #expect(MeetingScreenshot(url: URL(fileURLWithPath: "/tmp/shot_x.png")) == nil)
    }

    @Test func listsOldestFirstAndNeverOverwrites() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let first = MeetingScreenshot.newURL(in: dir, offset: 40)
        FileManager.default.createFile(atPath: first.path, contents: Data([1]))
        let same = MeetingScreenshot.newURL(in: dir, offset: 40)
        #expect(same != first)
        FileManager.default.createFile(atPath: same.path, contents: Data([2]))
        let early = MeetingScreenshot.newURL(in: dir, offset: 5)
        FileManager.default.createFile(atPath: early.path, contents: Data([3]))
        #expect(MeetingScreenshot.list(in: dir).map(\.offset) == [5, 40, 40.001])
    }

    @Test func screenshotsLiveInTheMeetingFolder() {
        let paths = FiggPaths(base: URL(fileURLWithPath: "/tmp/figg"))
        #expect(paths.screenshotsDir("m1").path.hasPrefix(paths.meetingDir("m1").path))
    }

    @Test func transcriptShowsScreenshotsAtTheirMomentWithoutSplittingALine() {
        let lines = [
            TranscriptLine(meetingId: "m", speaker: .me, start: 1, end: 5, text: "a"),
            TranscriptLine(meetingId: "m", speaker: .them, start: 10, end: 12, text: "b"),
        ]
        let shots = [3.0, 8.0, 30.0].map { MeetingScreenshot(url: URL(fileURLWithPath: "/s/\(MeetingScreenshot.fileName(offset: $0))"), offset: $0) }
        let order = TranscriptItem.merge(lines, shots).map { item -> String in
            switch item {
            case let .line(l): return l.text
            case let .screenshot(s): return "shot \(Int(s.offset))"
            }
        }
        #expect(order == ["a", "shot 3", "shot 8", "b", "shot 30"])
    }
}
