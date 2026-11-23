import Foundation

/// Slack huddles in the Slack desktop app (Electron). Markup from vibeconf's
/// and openclaw's huddle selectors (live checks June and September 2026) and
/// transcripted's Accessibility parser; not yet checked against a live dump.
///
/// - Each person is a tile (gridcell, class `p-huddle_peer_tile`) whose
///   label is "View <Name>'s profile".
/// - While someone talks their tile holds an element with class
///   `p-huddle_peer_tile__overlay--active_speaker`: the speaking cue.
/// - A muted person's name overlay has class `p-huddle_peer_tile__name_overlay--muted`.
/// - Your own tile's DOM id contains "-self_".
/// - The mic button reads "Unmute microphone" while you are muted and
///   "Mute microphone" while you are not.
public struct SlackHuddleProfile: MeetingAppProfile {
    public static let bundleID = "com.tinyspeck.slackmacgap"
    static let tileClass = "p-huddle_peer_tile"
    static let speakingClass = "p-huddle_peer_tile__overlay--active_speaker"
    static let mutedClass = "p-huddle_peer_tile__name_overlay--muted"

    public let id = "slack"
    public let displayName = "Slack"
    public let bundleIDs: Set<String> = [SlackHuddleProfile.bundleID]

    public init() {}

    public func accessibilitySwitches(for bundleID: String) -> [String] { [AccessibilitySwitch.manualAccessibility] }

    public var policy: CapturePolicy {
        CapturePolicy(maxNodes: 8000, maxDepth: 45, findsWebAreas: true)
    }

    /// The huddle window when Slack opened one, else the main window, where
    /// the huddle shows as a panel. Only the window's web area is copied.
    public func target(in windows: [AXWindowSummary]) -> AXTarget? {
        let ordered = windows.filter { $0.title?.lowercased().contains("huddle") == true } + windows
        for w in ordered {
            if let url = w.webAreas.first?.url { return .webArea(window: w.index, url: url) }
        }
        return nil
    }

    public func snapshot(from capture: MeetingAppCapture) -> MeetingAppSnapshot? {
        var people: [Participant] = []
        var all: [Participant] = []
        var speakingNames: [String] = []
        var selfName: String?
        var selfTileMuted: Bool?
        for tile in capture.tree.all(where: { $0.hasClass(Self.tileClass) }) {
            guard let name = tile.all().lazy.compactMap({ $0.label.flatMap(Self.profileName) }).first else { continue }
            let muted = tile.first { $0.hasClass(Self.mutedClass) } != nil
            let p = Participant(name: name, muted: muted)
            all.append(p)
            ParticipantNames.add(p, to: &people)
            if tile.first(where: { $0.hasClass(Self.speakingClass) }) != nil { speakingNames.append(name) }
            if tile.domID?.contains("-self_") == true { selfName = name; selfTileMuted = muted }
        }
        guard !people.isEmpty else { return nil }
        let cue = Set(speakingNames).count == 1 ? people.first { $0.name == speakingNames[0] } : nil
        let speaking = SpeakingRules.speaking(cue: cue, people: all, selfName: selfName, oneToOne: true)
        let muted = SpeakingRules.agree(Self.toolbarMuted(capture.tree), selfTileMuted)
        return MeetingAppSnapshot(app: id, participants: people, selfName: selfName, speaking: speaking, selfMuted: muted)
    }

    /// "View <Name>'s profile" (straight or curly apostrophe).
    static func profileName(_ label: String) -> String? {
        guard label.hasPrefix("View ") else { return nil }
        for suffix in ["'s profile", "\u{2019}s profile"] where label.hasSuffix(suffix) {
            return ParticipantNames.clean(String(label.dropFirst(5).dropLast(suffix.count)))?.name
        }
        return nil
    }

    static func toolbarMuted(_ tree: AXNode) -> Bool? {
        var answers = Set<Bool>()
        for b in tree.all(where: { $0.role == "AXButton" }) {
            switch b.label?.lowercased() {
            case "unmute microphone": answers.insert(true)
            case "mute microphone": answers.insert(false)
            default: break
            }
        }
        return answers.count == 1 ? answers.first : nil
    }
}
