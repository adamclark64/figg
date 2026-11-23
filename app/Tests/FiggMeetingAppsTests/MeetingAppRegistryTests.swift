@testable import FiggMeetingApps
import Testing

/// A web meeting profile for tests: any browser window with a web area on
/// meet.example.
struct FakeWebProfile: MeetingAppProfile {
    let id = "web"
    let displayName = "Web Call"
    let bundleIDs: Set<String> = ["com.google.Chrome", "com.apple.Safari"]
    func accessibilitySwitches(for bundleID: String) -> [String] {
        bundleID == "com.apple.Safari" ? [] : [AccessibilitySwitch.enhancedUserInterface]
    }
    var policy: CapturePolicy { CapturePolicy(findsWebAreas: true) }
    func target(in windows: [AXWindowSummary]) -> AXTarget? {
        for w in windows {
            if let area = w.webAreas.first(where: { $0.url?.hasPrefix("https://meet.example/") == true }), let url = area.url {
                return .webArea(window: w.index, url: url)
            }
        }
        return nil
    }
    func snapshot(from capture: MeetingAppCapture) -> MeetingAppSnapshot? { nil }
}

@Suite struct MeetingAppRegistryTests {
    let registry = MeetingAppRegistry(profiles: [ZoomProfile(), FakeWebProfile()])
    let all: Set<String> = ["zoom", "web"]
    let zoomMeeting = [AXWindowSummary(index: 0, identifier: ZoomProfile.meetingWindowID)]
    let browser = [
        AXWindowSummary(index: 0, webAreas: [.init(url: "https://news.example/today")]),
        AXWindowSummary(index: 1, webAreas: [.init(url: "https://meet.example/abc-defg-hij")]),
    ]

    func windows(_ app: String, _ profile: MeetingAppProfile) -> [AXWindowSummary] {
        switch app {
        case "us.zoom.xos": return zoomMeeting
        case "com.google.Chrome": return profile.policy.findsWebAreas ? browser : browser.map { AXWindowSummary(index: $0.index) }
        default: return []
        }
    }

    @Test func helpersMapToTheirApp() {
        #expect(MeetingAppRegistry.owningApp(of: "com.google.Chrome.helper") == "com.google.Chrome")
        #expect(MeetingAppRegistry.owningApp(of: "com.google.Chrome.helper.Renderer") == "com.google.Chrome")
        #expect(MeetingAppRegistry.owningApp(of: "com.tinyspeck.slackmacgap.helper") == "com.tinyspeck.slackmacgap")
        #expect(MeetingAppRegistry.owningApp(of: "com.example.helperapp") == "com.example.helperapp")
        #expect(MeetingAppRegistry.owningApp(of: "us.zoom.xos") == "us.zoom.xos")
    }

    @Test func micHolderPicksTheApp() {
        let c = registry.choose(micHolders: ["com.google.Chrome.helper"], running: ["us.zoom.xos", "com.google.Chrome"], enabled: all, windows: windows)
        #expect(c?.profile.id == "web")
        #expect(c?.bundleID == "com.google.Chrome")
        // Only the meeting tab is targeted, not the news tab.
        #expect(c?.target == .webArea(window: 1, url: "https://meet.example/abc-defg-hij"))
    }

    @Test func firstMicHolderWins() {
        let c = registry.choose(micHolders: ["us.zoom.xos", "com.google.Chrome"], running: [], enabled: all, windows: windows)
        #expect(c?.profile.id == "zoom")
    }

    @Test func micHolderWithoutAMeetingFallsThrough() {
        // Safari holds the mic but has no meeting tab; Zoom is running with one.
        let c = registry.choose(micHolders: ["com.apple.Safari"], running: ["us.zoom.xos"], enabled: all, windows: windows)
        #expect(c?.profile.id == "zoom")
    }

    @Test func disabledAppsAreSkipped() {
        let c = registry.choose(micHolders: ["com.google.Chrome"], running: ["com.google.Chrome", "us.zoom.xos"], enabled: ["zoom"], windows: windows)
        #expect(c?.profile.id == "zoom")
        #expect(registry.choose(micHolders: ["us.zoom.xos"], running: ["us.zoom.xos"], enabled: [], windows: windows) == nil)
    }

    @Test func nothingOnTheMicUsesProfileOrder() {
        let c = registry.choose(micHolders: [], running: ["com.google.Chrome", "us.zoom.xos"], enabled: all, windows: windows)
        #expect(c?.profile.id == "zoom")
        #expect(registry.choose(micHolders: [], running: ["com.apple.Safari"], enabled: all, windows: windows) == nil)
    }

    @Test func shipsTheProfiles() {
        #expect(MeetingAppRegistry().profile(id: "zoom") is ZoomProfile)
        #expect(MeetingAppRegistry().profile(id: "nope") == nil)
    }
}

@Suite struct AXDumpTests {
    @Test func parsesArguments() {
        let a = AXDump.arguments(["figg", "--ax-dump", "zoom", "--replace", "Bill Ortiz=Person A", "--replace", "bad", "--keep-values"])
        #expect(a?.id == "zoom")
        #expect(a?.replacements.count == 1)
        #expect(a?.replacements.first?.0 == "Bill Ortiz" && a?.replacements.first?.1 == "Person A")
        #expect(a?.keepValues == true)
        #expect(AXDump.arguments(["figg", "--probe-audio"]) == nil)
        #expect(AXDump.arguments(["figg", "--ax-dump"]) == nil)
    }

    @Test func scrubsNamesValuesAndURLs() {
        let tree = AXNode(role: "AXWebArea", description: "Bill Ortiz, muted", value: "secret plan", url: "https://meet.example/abc-defg-hij?authuser=1", children: [
            AXNode(role: "AXStaticText", title: "Bill Ortiz"),
        ])
        let out = AXDump.scrub(MeetingAppCapture(tree: tree, width: 1, height: 1), replacements: [("Bill Ortiz", "Person A")], keepValues: false)
        #expect(out.tree.description == "Person A, muted")
        #expect(out.tree.children[0].title == "Person A")
        #expect(out.tree.value == "xxxxxx xxxx")
        #expect(out.tree.url == "https://meet.example/xxx-xxxx-xxx")
        let text = AXNode(role: "AXStaticText", value: "Bill Ortiz")
        #expect(AXDump.scrub(MeetingAppCapture(tree: text, width: 1, height: 1), replacements: [("Bill Ortiz", "Person A")], keepValues: false).tree.value == "Person A")
        let kept = AXDump.scrub(MeetingAppCapture(tree: tree, width: 1, height: 1), replacements: [], keepValues: true)
        #expect(kept.tree.value == "secret plan")
    }
}
