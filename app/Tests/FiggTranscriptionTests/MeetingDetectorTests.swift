import FiggAudio
import Foundation
import Testing

@Suite struct MeetingDetectorTests {
    let t0 = Date(timeIntervalSince1970: 1_000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    @Test func promptsAfterStartDelayOnce() {
        var d = MeetingDetector(startDelay: 3)
        #expect(d.update(apps: ["us.zoom.xos"], isRecording: false, now: at(0)) == nil)
        #expect(d.update(apps: ["us.zoom.xos"], isRecording: false, now: at(2)) == nil)
        #expect(d.update(apps: ["us.zoom.xos"], isRecording: false, now: at(3)) == .started(app: "us.zoom.xos"))
        #expect(d.update(apps: ["us.zoom.xos"], isRecording: false, now: at(10)) == nil)  // "not now" sticks
    }

    @Test func blipsDoNotPrompt() {
        var d = MeetingDetector(startDelay: 3)
        _ = d.update(apps: ["us.zoom.xos"], isRecording: false, now: at(0))
        _ = d.update(apps: [], isRecording: false, now: at(2))
        #expect(d.update(apps: ["us.zoom.xos"], isRecording: false, now: at(4)) == nil)  // timer restarted
    }

    @Test func offersAgainAfterAppReleasesMic() {
        var d = MeetingDetector(startDelay: 3)
        _ = d.update(apps: ["us.zoom.xos"], isRecording: false, now: at(0))
        #expect(d.update(apps: ["us.zoom.xos"], isRecording: false, now: at(3)) != nil)
        _ = d.update(apps: [], isRecording: false, now: at(5))
        _ = d.update(apps: ["us.zoom.xos"], isRecording: false, now: at(60))
        #expect(d.update(apps: ["us.zoom.xos"], isRecording: false, now: at(63)) == .started(app: "us.zoom.xos"))
    }

    @Test func ignoresDictationAndFigg() {
        var d = MeetingDetector(startDelay: 3)
        let noise: Set<String> = ["com.FluidApp.app", "com.apple.CoreSpeech", "dev.adamclark.figg"]
        _ = d.update(apps: noise, isRecording: false, now: at(0))
        #expect(d.update(apps: noise, isRecording: false, now: at(30)) == nil)
    }

    @Test func noPromptWhileRecording() {
        var d = MeetingDetector(startDelay: 3)
        _ = d.update(apps: ["com.microsoft.teams2"], isRecording: true, now: at(0))
        #expect(d.update(apps: ["com.microsoft.teams2"], isRecording: true, now: at(10)) == nil)
    }

    @Test func endsWhenMeetingAppReleasesMic() {
        var d = MeetingDetector(startDelay: 3, endDelay: 10)
        _ = d.update(apps: ["us.zoom.xos"], isRecording: true, now: at(0))
        _ = d.update(apps: ["us.zoom.xos"], isRecording: true, now: at(30))
        #expect(d.update(apps: [], isRecording: true, now: at(35)) == nil)
        #expect(d.update(apps: [], isRecording: true, now: at(40)) == .ended(app: "us.zoom.xos"))
        #expect(d.update(apps: [], isRecording: true, now: at(50)) == nil)  // once
    }

    @Test func briefMicDropDoesNotEnd() {
        var d = MeetingDetector(endDelay: 10)
        _ = d.update(apps: ["us.zoom.xos"], isRecording: true, now: at(0))
        _ = d.update(apps: [], isRecording: true, now: at(5))
        _ = d.update(apps: ["us.zoom.xos"], isRecording: true, now: at(8))
        #expect(d.update(apps: [], isRecording: true, now: at(15)) == nil)
    }

    @Test func browserHelpersMapToBrowser() {
        #expect(MeetingDetector.parentBundleID("com.google.Chrome.helper") == "com.google.Chrome")
        #expect(MeetingDetector.parentBundleID("com.microsoft.edgemac.helper.renderer") == "com.microsoft.edgemac")
        #expect(MeetingDetector.parentBundleID("us.zoom.xos") == "us.zoom.xos")
    }
}
