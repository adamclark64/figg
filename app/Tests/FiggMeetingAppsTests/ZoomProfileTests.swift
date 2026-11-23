@testable import FiggMeetingApps
import Testing

@Suite struct ZoomProfileTests {
    let zoom = ZoomProfile()

    @Test func speakerViewFixture() throws {
        let s = try #require(zoom.snapshot(from: Fixture.capture("zoom-speaker-view")))
        #expect(s.app == "zoom")
        #expect(s.participants.map(\.name) == ["Bill Ortiz", "Sam Lee", "Nora Hale"])
        #expect(s.speaking == "Bill Ortiz")
        #expect(s.selfName == "Sam Lee")
        // The toolbar says Unmute (you are muted) and your tile agrees; the
        // Participants panel's Mute button is left out.
        #expect(s.selfMuted == true)
    }

    @Test func sameAnswerAsZoomReading() throws {
        let c = try Fixture.capture("zoom-speaker-view")
        let tiles = [
            ZoomReading.Tile(label: "Bill Ortiz, Computer audio unmuted", width: 1710, height: 961),
            ZoomReading.Tile(label: "Sam Lee, Computer audio muted, Video off", width: 240, height: 135),
            ZoomReading.Tile(label: "Nora Hale, Computer audio muted", width: 240, height: 135),
        ]
        let buttons = [
            ZoomReading.Button(label: "Mute", y: 1040, inParticipantsPanel: true),
            ZoomReading.Button(label: "Unmute audio", y: 1030),
        ]
        let direct = ZoomReading.snapshot(tiles: tiles, windowWidth: 1710, windowHeight: 1080, selfName: "Sam Lee", buttons: buttons)
        #expect(zoom.snapshot(from: c) == direct)
    }

    @Test func galleryViewNamesTheOnlyUnmutedOther() {
        let tile = { (label: String) in
            AXNode(role: "AXGroup", roleDescription: "Video render", description: label, frame: .init(x: 0, y: 0, width: 850, height: 480))
        }
        let tree = AXNode(role: "AXWindow", identifier: ZoomProfile.meetingWindowID, children: [
            tile("Sam Lee, Computer audio unmuted"), tile("Bill Ortiz, Computer audio unmuted"), tile("Nora Hale, Computer audio muted"),
        ])
        let account = AXNode(role: "AXWindow", children: [AXNode(role: "AXButton", description: "Zoom, Sam Lee, In a Zoom Meeting, Basic account")])
        let s = zoom.snapshot(from: MeetingAppCapture(tree: tree, width: 1710, height: 1080, otherWindows: [account]))
        #expect(s?.speaking == "Bill Ortiz")
        #expect(s?.selfMuted == false)
        // Without the main window, figg does not know who you are.
        #expect(zoom.snapshot(from: MeetingAppCapture(tree: tree, width: 1710, height: 1080))?.speaking == nil)
    }

    @Test func targetIsTheMeetingWindow() {
        let windows = [
            AXWindowSummary(index: 0, title: "Zoom Workplace"),
            AXWindowSummary(index: 1, title: "Zoom Meeting  40-minutes", identifier: ZoomProfile.meetingWindowID),
        ]
        #expect(zoom.target(in: windows) == .window(1))
        #expect(zoom.target(in: [windows[0]]) == nil)
    }

    @Test func policyKeepsTheOldWalk() {
        let p = zoom.policy
        let tile = AXNode(role: "AXGroup", roleDescription: "Video render", description: "Bill")
        let mute = AXNode(role: "AXButton", description: "Unmute audio")
        let video = AXNode(role: "AXButton", description: "Start video")
        let group = AXNode(role: "AXGroup")
        #expect(p.maxDepth == 8 && p.maxNodes == 4000 && p.otherWindowsDepth == 1)
        #expect(!p.descend(tile) && !p.descend(mute) && !p.descend(video) && p.descend(group))
        #expect(p.wantsFrame(tile) && p.wantsFrame(mute) && !p.wantsFrame(video) && !p.wantsFrame(group))
        #expect(zoom.accessibilitySwitches(for: ZoomProfile.bundleID).isEmpty)
    }
}
