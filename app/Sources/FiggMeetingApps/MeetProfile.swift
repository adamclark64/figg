import Foundation

/// Google Meet in Chrome, Arc, Edge or Safari. Markup from vibeconf's Meet
/// selectors (live checks September to November 2026), Vexa, mova-flow and
/// recall.ai's caption extension; not yet checked against a live dump.
///
/// Accessibility shows Meet's aria-labels, text, DOM ids and classes, but
/// not its `data-*` or `jsname` attributes, and not the speaking ring
/// (drawn with CSS). So:
///
/// - Names: each tile's "More options for <Name>" button, the tile name text
///   (class `notranslate`), and the People panel's rows (labelled with the
///   name, inside the region "In call").
/// - You: the People panel row holding "(You)".
/// - Speaking: the newest turn in the Captions region (when captions are
///   on), whose name sits above the words. Turns are found by Meet's
///   classes (`nMcdL`, name `NWpY1d`) or, since those change between Meet
///   builds, by shape: a group with an image (the avatar) and texts.
/// - Your mute state: the mic button, "Turn on microphone..." while muted,
///   "Turn off microphone..." while not (a shortcut hint may follow).
/// - In a call at all: the "Leave call" button. The lobby has none.
public struct MeetProfile: MeetingAppProfile {
    public static let chromium: Set<String> = ["com.google.Chrome", "company.thebrowser.Browser", "com.microsoft.edgemac"]
    public static let safari = "com.apple.Safari"

    public let id = "meet"
    public let displayName = "Google Meet"
    public let bundleIDs: Set<String> = MeetProfile.chromium.union([MeetProfile.safari])

    public init() {}

    public func accessibilitySwitches(for bundleID: String) -> [String] {
        bundleID.caseInsensitiveCompare(Self.safari) == .orderedSame ? [] : [AccessibilitySwitch.enhancedUserInterface]
    }

    public var policy: CapturePolicy { CapturePolicy(maxNodes: 8000, maxDepth: 45, findsWebAreas: true) }

    /// The tab whose URL is a Meet meeting ("meet.google.com/abc-defg-hij").
    /// No other tab, and nothing outside it, is copied.
    public func target(in windows: [AXWindowSummary]) -> AXTarget? {
        for w in windows {
            for area in w.webAreas {
                if let url = area.url, Self.isMeeting(url) { return .webArea(window: w.index, url: url) }
            }
        }
        return nil
    }

    static func isMeeting(_ url: String) -> Bool {
        guard let c = URLComponents(string: url), c.host == "meet.google.com" else { return false }
        let code = c.path.split(separator: "/").first.map(String.init) ?? ""
        let parts = code.split(separator: "-")
        return parts.map(\.count) == [3, 4, 3] && code.allSatisfy { $0.isLetter || $0 == "-" }
    }

    public func snapshot(from capture: MeetingAppCapture) -> MeetingAppSnapshot? {
        let tree = capture.tree
        guard tree.first(where: { $0.role == "AXButton" && $0.label?.hasPrefix("Leave call") == true }) != nil else { return nil }
        var people: [Participant] = []
        var selfName: String?
        for b in tree.all(where: { $0.label?.hasPrefix("More options for ") == true }) {
            if let n = ParticipantNames.clean(String(b.label!.dropFirst("More options for ".count))) {
                ParticipantNames.add(Participant(name: n.name), to: &people)
            }
        }
        for t in tree.all(where: { $0.hasClass("notranslate") }) {
            // The meeting code ("abc-defg-hij") is shown untranslated too.
            if let raw = ParticipantNames.firstText(in: t), !Self.isMeeting("https://meet.google.com/" + raw),
               let n = ParticipantNames.clean(raw) {
                ParticipantNames.add(Participant(name: n.name), to: &people)
            }
        }
        if let panel = tree.first(where: { $0.description?.caseInsensitiveCompare("In call") == .orderedSame }) {
            let rowRoles: Set<String> = ["AXGroup", "AXRow", "AXCell"]
            for row in panel.all(where: { $0 != panel && $0.description != nil && rowRoles.contains($0.role ?? "") }) {
                guard let n = ParticipantNames.clean(row.description!) else { continue }
                ParticipantNames.add(Participant(name: n.name), to: &people)
                let marked = n.isSelf || row.first { ParticipantNames.text($0)?.trimmingCharacters(in: .whitespaces) == "(You)" } != nil
                if marked { selfName = n.name }
            }
        }
        let cue = captionSpeaker(tree).map { Participant(name: $0) }
        guard !people.isEmpty || cue != nil else { return nil }
        if let cue { ParticipantNames.add(cue, to: &people) }
        let speaking = SpeakingRules.speaking(cue: cue, people: people, selfName: selfName, oneToOne: true)
        return MeetingAppSnapshot(app: id, participants: people, selfName: selfName, speaking: speaking, selfMuted: Self.micMuted(tree))
    }

    /// The name on the newest caption turn; nil when captions are off or
    /// the turn is yours ("You").
    func captionSpeaker(_ tree: AXNode) -> String? {
        guard let region = tree.first(where: { $0.description == "Captions" }) else { return nil }
        var turns = region.all { $0.hasClass("nMcdL") }
        if turns.isEmpty {
            turns = region.all { n in
                n != region && n.children.contains { $0.role == "AXImage" } && n.all { $0.role == "AXStaticText" }.count >= 2
            }
        }
        guard let last = turns.last else { return nil }
        let raw = last.first { $0.hasClass("NWpY1d") }.flatMap(ParticipantNames.firstText)
            ?? last.first { $0.role == "AXStaticText" && $0.value != nil }?.value
        guard let raw, raw.trimmingCharacters(in: .whitespaces).lowercased() != "you",
              let n = ParticipantNames.clean(raw), !n.isSelf else { return nil }
        return n.name
    }

    static func micMuted(_ tree: AXNode) -> Bool? {
        var answers = Set<Bool>()
        for b in tree.all(where: { $0.role == "AXButton" }) {
            guard let l = b.label?.lowercased() else { continue }
            if l.hasPrefix("turn on microphone") { answers.insert(true) }
            if l.hasPrefix("turn off microphone") { answers.insert(false) }
        }
        return answers.count == 1 ? answers.first : nil
    }
}
