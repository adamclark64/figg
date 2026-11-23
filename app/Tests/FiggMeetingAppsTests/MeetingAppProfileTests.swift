@testable import FiggMeetingApps
import Testing

/// Fixtures are hand-built from each app's published markup (see the
/// profiles' doc comments), with made-up names.

@Suite struct ParticipantNamesTests {
    @Test func cleansTagsAndSpaces() {
        #expect(ParticipantNames.clean("Bill  Ortiz (Host)") == .init(name: "Bill Ortiz", isSelf: false))
        #expect(ParticipantNames.clean("Sam Lee (You)") == .init(name: "Sam Lee", isSelf: true))
        #expect(ParticipantNames.clean("Sam Lee (me) (Organizer)") == .init(name: "Sam Lee", isSelf: true))
        #expect(ParticipantNames.clean("Jo (Park)")?.name == "Jo (Park)")
        #expect(ParticipantNames.clean("You") == nil)
        #expect(ParticipantNames.clean("Nora H\u{2026}") == nil)
        #expect(ParticipantNames.clean("x") == nil)
    }
}

@Suite struct SlackHuddleProfileTests {
    let slack = SlackHuddleProfile()

    @Test func huddleFixture() throws {
        let s = try #require(slack.snapshot(from: Fixture.capture("slack-huddle")))
        #expect(s.app == "slack")
        #expect(s.participants.map(\.name) == ["Sam Lee", "Bill Ortiz", "Nora Hale"])
        #expect(s.participants.map(\.muted) == [true, false, false])
        #expect(s.selfName == "Sam Lee")
        #expect(s.speaking == "Bill Ortiz")
        #expect(s.selfMuted == true)
    }

    @Test func profileLabels() {
        #expect(SlackHuddleProfile.profileName("View Bill Ortiz's profile") == "Bill Ortiz")
        #expect(SlackHuddleProfile.profileName("View Bill Ortiz\u{2019}s profile") == "Bill Ortiz")
        #expect(SlackHuddleProfile.profileName("View channel details") == nil)
    }

    @Test func twoActiveSpeakersFallBackToRules() throws {
        var c = try Fixture.capture("slack-huddle")
        // Mark Nora speaking too: the cue is unclear, and two others are unmuted.
        c.tree.children[0].children[2].children.append(AXNode(role: "AXGroup", domClasses: [SlackHuddleProfile.speakingClass]))
        #expect(slack.snapshot(from: c)?.speaking == nil)
    }

    @Test func noHuddleIsNil() {
        let channel = AXNode(role: "AXWebArea", children: [AXNode(role: "AXStaticText", value: "xxxx")])
        #expect(slack.snapshot(from: MeetingAppCapture(tree: channel, width: 1, height: 1)) == nil)
    }

    @Test func prefersTheHuddleWindow() {
        let windows = [
            AXWindowSummary(index: 0, title: "Slack", webAreas: [.init(url: "https://app.slack.com/client/T0000")]),
            AXWindowSummary(index: 1, title: "Huddle: design", webAreas: [.init(url: "https://app.slack.com/huddle/T0000")]),
        ]
        #expect(slack.target(in: windows) == .webArea(window: 1, url: "https://app.slack.com/huddle/T0000"))
        #expect(slack.target(in: [windows[0]]) == .webArea(window: 0, url: "https://app.slack.com/client/T0000"))
        #expect(slack.accessibilitySwitches(for: SlackHuddleProfile.bundleID) == [AccessibilitySwitch.manualAccessibility])
    }
}

@Suite struct MeetProfileTests {
    let meet = MeetProfile()

    @Test func captionsFixture() throws {
        let s = try #require(meet.snapshot(from: Fixture.capture("meet-chrome-captions")))
        #expect(s.app == "meet")
        // The meeting code in the toolbar is not a person.
        #expect(s.participants.map(\.name) == ["Bill Ortiz", "Nora Hale", "Sam Lee"])
        #expect(s.selfName == "Sam Lee")
        #expect(s.speaking == "Bill Ortiz")
        #expect(s.selfMuted == true)
    }

    @Test func yourOwnCaptionIsNotARemoteSpeaker() throws {
        var c = try Fixture.capture("meet-chrome-captions")
        c.tree.children[1].children[1].children[1].children[0].value = "You"
        // Captions say you are talking; with three people and no mute state
        // for the others, nobody else can be named.
        #expect(meet.snapshot(from: c)?.speaking == nil)
    }

    @Test func captionTurnsFoundByShapeWhenClassesChange() throws {
        var c = try Fixture.capture("meet-chrome-captions")
        func strip(_ n: inout AXNode) {
            n.domClasses = n.domClasses?.filter { $0 == "notranslate" }
            for i in n.children.indices { strip(&n.children[i]) }
        }
        strip(&c.tree)
        #expect(meet.snapshot(from: c)?.speaking == "Bill Ortiz")
    }

    @Test func oneToOneWithoutCaptions() {
        let tree = AXNode(role: "AXWebArea", children: [
            AXNode(role: "AXButton", description: "More options for Bill Ortiz"),
            AXNode(role: "AXGroup", description: "In call", children: [
                AXNode(role: "AXGroup", description: "Sam Lee (You)"),
                AXNode(role: "AXGroup", description: "Bill Ortiz"),
            ]),
            AXNode(role: "AXButton", description: "Turn off microphone (ctrl + d)"),
            AXNode(role: "AXButton", description: "Leave call"),
        ])
        let s = meet.snapshot(from: MeetingAppCapture(tree: tree, width: 1, height: 1))
        #expect(s?.selfName == "Sam Lee")
        #expect(s?.speaking == "Bill Ortiz")
        #expect(s?.selfMuted == false)
    }

    @Test func lobbyIsNil() {
        let lobby = AXNode(role: "AXWebArea", children: [
            AXNode(role: "AXButton", description: "Turn off microphone"),
            AXNode(role: "AXButton", description: "Join now"),
        ])
        #expect(meet.snapshot(from: MeetingAppCapture(tree: lobby, width: 1, height: 1)) == nil)
    }

    @Test func targetsOnlyTheMeetingTab() {
        let windows = [
            AXWindowSummary(index: 0, webAreas: [.init(url: "https://meet.google.com/landing")]),
            AXWindowSummary(index: 1, webAreas: [.init(url: "https://news.example/"), .init(url: "https://meet.google.com/abc-defg-hij?authuser=0")]),
        ]
        #expect(meet.target(in: windows) == .webArea(window: 1, url: "https://meet.google.com/abc-defg-hij?authuser=0"))
        #expect(meet.target(in: [windows[0]]) == nil)
        #expect(!MeetProfile.isMeeting("https://meet.google.com.example/abc-defg-hij"))
    }

    @Test func switchesPerBrowser() {
        #expect(meet.accessibilitySwitches(for: "com.google.Chrome") == [AccessibilitySwitch.enhancedUserInterface])
        #expect(meet.accessibilitySwitches(for: "company.thebrowser.Browser") == [AccessibilitySwitch.enhancedUserInterface])
        #expect(meet.accessibilitySwitches(for: "com.apple.Safari").isEmpty)
    }
}

@Suite struct TeamsProfileTests {
    let teams = TeamsProfile()

    @Test func meetingFixture() throws {
        let s = try #require(teams.snapshot(from: Fixture.capture("teams-meeting")))
        #expect(s.app == "teams")
        #expect(s.participants.map(\.name) == ["Sam Lee", "Bill Ortiz", "Hale, Nora"])
        #expect(s.selfName == "Sam Lee")
        // No speaking cue in Teams; Bill is the only other person unmuted.
        #expect(s.speaking == "Bill Ortiz")
        #expect(s.selfMuted == true)
    }

    @Test func tileLabels() {
        #expect(TeamsProfile.participant(fromTileLabel: "Dana Smith, video is on, unmuted")?.0 == Participant(name: "Dana Smith", muted: false))
        #expect(TeamsProfile.participant(fromTileLabel: "Smith, Dana, video is off")?.0 == Participant(name: "Smith, Dana", muted: nil))
        #expect(TeamsProfile.participant(fromTileLabel: "Sam Lee (You), video is off, muted")?.1 == true)
        #expect(TeamsProfile.participant(fromTileLabel: "video is on") == nil)
    }

    @Test func chatWindowIsNil() {
        let chat = AXNode(role: "AXWebArea", children: [AXNode(role: "AXButton", description: "New chat")])
        #expect(teams.snapshot(from: MeetingAppCapture(tree: chat, width: 1, height: 1)) == nil)
    }

    @Test func prefersTheMeetingWindow() {
        let windows = [
            AXWindowSummary(index: 0, title: "Chat | Microsoft Teams", webAreas: [.init(url: "https://teams.microsoft.com/v2/")]),
            AXWindowSummary(index: 1, title: "Meeting with Bill | Microsoft Teams", webAreas: [.init(url: "https://teams.microsoft.com/v2/?meeting")]),
        ]
        #expect(teams.target(in: windows) == .webArea(window: 1, url: "https://teams.microsoft.com/v2/?meeting"))
    }
}

@Suite struct RegistryShipsAllProfilesTests {
    @Test func allFourInFallbackOrder() {
        #expect(MeetingAppRegistry.all.map(\.id) == ["zoom", "teams", "meet", "slack"])
        let ids = MeetingAppRegistry.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func chromeHelperOnTheMicPicksMeet() {
        let registry = MeetingAppRegistry()
        let c = registry.choose(micHolders: ["com.google.Chrome.helper.renderer"], running: ["com.google.Chrome", "com.tinyspeck.slackmacgap"],
                                enabled: ["zoom", "teams", "meet", "slack"]) { app, _ in
            app == "com.google.Chrome" ? [AXWindowSummary(index: 0, webAreas: [.init(url: "https://meet.google.com/abc-defg-hij")])] : []
        }
        #expect(c?.profile.id == "meet")
        #expect(c?.bundleID == "com.google.Chrome")
    }
}
