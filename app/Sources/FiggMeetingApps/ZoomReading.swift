import Foundation

/// Turns what the Zoom desktop app exposes to Accessibility into a
/// `MeetingAppSnapshot`. Pure, so it can be tested without Zoom.
///
/// Checked against Zoom 7.1.9 on macOS (November 2026): every video tile is
/// an element whose role description starts with "Video" and whose
/// description reads "<name>, Computer audio muted, Video off" (the parts
/// after the name vary). In Speaker view one tile fills the window: that is
/// the person Zoom picked as the active speaker. Zoom never puts you in the
/// big tile for your own speech, so it is always a remote person or the
/// last one who spoke. Gallery view shows no speaking cue at all.
public enum ZoomReading {
    /// One video tile as read from the window.
    public struct Tile: Sendable, Equatable {
        public var label: String
        public var width: Double
        public var height: Double
        public init(label: String, width: Double, height: Double) {
            self.label = label
            self.width = width
            self.height = height
        }
    }

    /// One button as read from the meeting window, kept to find your own
    /// mute state from the toolbar's audio button.
    public struct Button: Sendable, Equatable {
        /// The button's description, or its title when it has none.
        public var label: String
        /// Top edge, in points from the top of the meeting window.
        public var y: Double
        /// Inside the Participants panel, where a host sees a Mute or Unmute
        /// button on every row.
        public var inParticipantsPanel: Bool
        public init(label: String, y: Double, inParticipantsPanel: Bool = false) {
            self.label = label
            self.y = y
            self.inParticipantsPanel = inParticipantsPanel
        }
    }

    /// Share of the window a tile must cover to count as Speaker view's main tile.
    static let mainTileShare = 0.5

    /// The name and mute state in a tile's label, or nil when it has no name.
    public static func participant(fromTileLabel label: String) -> Participant? {
        let parts = label.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = parts.first, !first.isEmpty else { return nil }
        // Labels split on commas, so a name with a comma in it ("Ortiz, Bill")
        // keeps its pieces until the first part that is a state.
        var nameParts: [String] = []
        var muted: Bool?
        var reachedState = false
        for part in parts {
            let lower = part.lowercased()
            if lower.contains("audio muted") { muted = true; reachedState = true }
            else if lower.contains("audio unmuted") { muted = false; reachedState = true }
            else if lower.hasPrefix("video ") || lower.contains("audio connected") || lower.hasPrefix("no audio") { reachedState = true }
            else if !reachedState { nameParts.append(part) }
        }
        let name = nameParts.joined(separator: ", ")
        return name.isEmpty ? nil : Participant(name: name, muted: muted)
    }

    /// The self name in the Zoom Workplace window's account button, which
    /// reads "Zoom, <name>, In a Zoom Meeting, Basic account".
    public static func selfName(fromAccountButton description: String) -> String? {
        let parts = description.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, parts[0] == "Zoom", !parts[1].isEmpty else { return nil }
        return parts[1]
    }

    /// Toolbar candidates must start this far down the window (Zoom's
    /// toolbar runs along the bottom edge).
    static let toolbarTop = 0.75

    /// Whether a label's first word is "mute" or "unmute", ignoring case and
    /// punctuation. Cheap, so the reader can call it before asking Zoom for
    /// a button's position.
    public static func isMuteLabel(_ label: String) -> Bool {
        let first = words(label).first
        return first == "mute" || first == "unmute"
    }

    static func words(_ label: String) -> [String] {
        label.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Your mute state from the toolbar's audio button, whose label is the
    /// action it offers: "Unmute..." while you are muted, "Mute..." while
    /// you are not.
    ///
    /// Only buttons outside the Participants panel and in the bottom quarter
    /// of the window count, and never one naming video, everyone ("all") or
    /// a participant. Identical labels (Zoom nests a button inside itself)
    /// count once. Answers only when exactly one label is left, so a host's
    /// panel rows or a layout we do not know give nil, never a false muted.
    public static func selfMuted(fromButtons buttons: [Button], participants: [String], windowHeight: Double) -> Bool? {
        guard windowHeight > 0 else { return nil }
        let names = participants.map { words($0).joined(separator: " ") }.filter { !$0.isEmpty }
        var labels = Set<String>()
        for button in buttons where !button.inParticipantsPanel && button.y >= windowHeight * toolbarTop {
            let w = words(button.label)
            guard let first = w.first, first == "mute" || first == "unmute",
                  !w.contains("video"), !w.contains("all") else { continue }
            let joined = " " + w.joined(separator: " ") + " "
            if names.contains(where: { joined.contains(" " + $0 + " ") }) { continue }
            labels.insert(w.joined(separator: " "))
        }
        guard labels.count == 1, let only = labels.first else { return nil }
        return only.hasPrefix("unmute")
    }

    /// Your mute state: the toolbar button first, your own tile second
    /// (only when exactly one tile has your name). When both answer and
    /// disagree the answer is nil, so one stray label can never be enough
    /// to leave out what the mic heard.
    public static func selfMuted(buttons: [Button], tiles: [Tile], selfName: String?, windowHeight: Double) -> Bool? {
        let people = tiles.compactMap { participant(fromTileLabel: $0.label) }
        let toolbar = selfMuted(fromButtons: buttons, participants: people.map(\.name), windowHeight: windowHeight)
        var tile: Bool?
        if let selfName {
            let mine = people.filter { $0.name == selfName }
            if mine.count == 1 { tile = mine[0].muted }
        }
        return SpeakingRules.agree(toolbar, tile)
    }

    /// Who is on the call, who Zoom shows as speaking, and whether you are muted.
    ///
    /// Speaking is the main tile in Speaker view, unless that is you or is
    /// muted. Otherwise, when you are known and exactly one other person is
    /// unmuted, any sound on the call can only be theirs.
    public static func snapshot(tiles: [Tile], windowWidth: Double, windowHeight: Double, selfName: String?, buttons: [Button] = []) -> MeetingAppSnapshot {
        let people = tiles.compactMap { participant(fromTileLabel: $0.label) }
        var seen = Set<String>()
        let participants = people.filter { seen.insert($0.name).inserted }
        let windowArea = windowWidth * windowHeight
        let main = tiles.filter { windowArea > 0 && $0.width * $0.height >= windowArea * mainTileShare }
        let cue = main.count == 1 ? participant(fromTileLabel: main[0].label) : nil
        let speaking = SpeakingRules.speaking(cue: cue, people: people, selfName: selfName)
        let muted = selfMuted(buttons: buttons, tiles: tiles, selfName: selfName, windowHeight: windowHeight)
        return MeetingAppSnapshot(app: "zoom", participants: participants, selfName: selfName, speaking: speaking, selfMuted: muted)
    }
}
