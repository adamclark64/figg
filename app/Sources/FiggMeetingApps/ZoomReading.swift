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

    /// Who is on the call and who Zoom shows as speaking.
    ///
    /// Speaking is the main tile in Speaker view, unless that is you or is
    /// muted. Otherwise, when you are known and exactly one other person is
    /// unmuted, any sound on the call can only be theirs.
    public static func snapshot(tiles: [Tile], windowWidth: Double, windowHeight: Double, selfName: String?) -> MeetingAppSnapshot {
        let people = tiles.compactMap { participant(fromTileLabel: $0.label) }
        var seen = Set<String>()
        let participants = people.filter { seen.insert($0.name).inserted }
        let windowArea = windowWidth * windowHeight
        var speaking: String?
        let main = tiles.filter { windowArea > 0 && $0.width * $0.height >= windowArea * mainTileShare }
        if main.count == 1, let p = participant(fromTileLabel: main[0].label), p.name != selfName, p.muted != true {
            speaking = p.name
        } else if let selfName {
            let others = participants.filter { $0.name != selfName && $0.muted == false }
            // Two people with your name (a second device of yours) make "others" unclear.
            if others.count == 1, people.filter({ $0.name == selfName }).count <= 1 { speaking = others[0].name }
        }
        return MeetingAppSnapshot(app: "zoom", participants: participants, selfName: selfName, speaking: speaking)
    }
}
