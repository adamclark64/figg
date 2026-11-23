import Foundation

/// The new Microsoft Teams app. Markup from teams-for-linux (tile labels,
/// November 2026), vibeconf's Teams selectors (toolbar ids, live check
/// October 2026) and Vexa; not yet checked against a live dump, and the
/// toolbar labels were seen in the web client, not the Mac app.
///
/// - Names: each video tile's label, "Dana Smith, video is on, ...": the
///   name is everything before the first status part.
/// - Speaking: Teams draws the speaking ring with CSS, which Accessibility
///   cannot see, so Teams has no speaking cue; the shared rules (one other
///   person unmuted, one-to-one call) are all it gets.
/// - Your mute state: the button with DOM id `mic-button`, "Unmute mic"
///   while muted, "Mute mic" while not.
/// - In a call at all: the button with DOM id `hangup-button`.
public struct TeamsProfile: MeetingAppProfile {
    public static let bundleID = "com.microsoft.teams2"

    public let id = "teams"
    public let displayName = "Microsoft Teams"
    public let bundleIDs: Set<String> = [TeamsProfile.bundleID]

    public init() {}

    /// Whether new Teams is WebKit or Chromium on the Mac is not settled;
    /// both switches cover either.
    public func accessibilitySwitches(for bundleID: String) -> [String] {
        [AccessibilitySwitch.manualAccessibility, AccessibilitySwitch.enhancedUserInterface]
    }

    public var policy: CapturePolicy { CapturePolicy(maxNodes: 8000, maxDepth: 45, findsWebAreas: true) }

    /// The meeting window (its title names a meeting or call), else the
    /// first window with web content; the snapshot is nil unless it has
    /// the hang-up button.
    public func target(in windows: [AXWindowSummary]) -> AXTarget? {
        let isCall = { (w: AXWindowSummary) in
            let t = w.title?.lowercased() ?? ""
            return t.contains("meeting") || t.contains("call")
        }
        for w in windows.filter(isCall) + windows {
            if let url = w.webAreas.first?.url { return .webArea(window: w.index, url: url) }
            if w.webAreas.isEmpty, isCall(w) { return .window(w.index) }
        }
        return nil
    }

    public func snapshot(from capture: MeetingAppCapture) -> MeetingAppSnapshot? {
        let tree = capture.tree
        guard tree.first(where: { $0.domID == "hangup-button" }) != nil else { return nil }
        var people: [Participant] = []
        var all: [Participant] = []
        var selfName: String?
        for node in tree.all(where: { $0.label.map(Self.isTileLabel) == true }) {
            guard let (p, isSelf) = Self.participant(fromTileLabel: node.label!) else { continue }
            all.append(p)
            ParticipantNames.add(p, to: &people)
            if isSelf { selfName = p.name }
        }
        guard !people.isEmpty else { return nil }
        let speaking = SpeakingRules.speaking(cue: nil, people: all, selfName: selfName, oneToOne: true)
        let selfTile = selfName.flatMap { me in all.filter { $0.name == me }.count == 1 ? all.first { $0.name == me }?.muted : nil }
        return MeetingAppSnapshot(app: id, participants: people, selfName: selfName, speaking: speaking,
                                  selfMuted: SpeakingRules.agree(Self.micMuted(tree), selfTile))
    }

    static func isTileLabel(_ label: String) -> Bool {
        label.lowercased().contains(", video is ")
    }

    /// "Dana Smith, video is on, muted" or "Smith, Dana (You), video is off".
    static func participant(fromTileLabel label: String) -> (Participant, Bool)? {
        let parts = label.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let status = parts.firstIndex(where: { $0.lowercased().hasPrefix("video is ") }), status > 0 else { return nil }
        guard let cleaned = ParticipantNames.clean(parts[..<status].joined(separator: ", ")) else { return nil }
        let rest = parts[status...].map { $0.lowercased() }
        let muted: Bool? = rest.contains("muted") ? true : rest.contains("unmuted") ? false : nil
        return (Participant(name: cleaned.name, muted: muted), cleaned.isSelf)
    }

    static func micMuted(_ tree: AXNode) -> Bool? {
        guard let label = tree.first(where: { $0.domID == "mic-button" })?.label?.lowercased() else { return nil }
        if label.hasPrefix("unmute") { return true }
        if label.hasPrefix("mute") { return false }
        return nil
    }
}
