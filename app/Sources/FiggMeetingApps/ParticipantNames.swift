import Foundation

/// Cleans a display name read from a meeting app's label, shared by the
/// profiles so "Bill Ortiz (Host)" and "Bill Ortiz" are one person.
public enum ParticipantNames {
    public struct Cleaned: Equatable, Sendable {
        public var name: String
        /// The app marked this as you ("(You)", "(me)").
        public var isSelf: Bool
    }

    static let selfTags: Set<String> = ["you", "me"]
    static let roleTags: Set<String> = ["host", "co-host", "cohost", "guest", "external", "unverified",
                                        "organizer", "organiser", "presenter", "presentation"]
    /// Words apps put where a name would be; never a person.
    static let notNames: Set<String> = ["you", "me", "someone", "participant", "participants", "guest", "guests",
                                        "unknown", "muted", "unmuted", "more options", "presenting"]
    static let maxLength = 120

    /// The name in `raw`, or nil when nothing name-like is left.
    public static func clean(_ raw: String) -> Cleaned? {
        var text = raw.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains("\n"), !text.hasSuffix("\u{2026}"), !text.hasSuffix("...") else { return nil }
        var isSelf = false
        // Trailing "(You)", "(Host)" tags, any number of them.
        while text.hasSuffix(")"), let open = text.range(of: "(", options: .backwards) {
            let tag = text[open.upperBound..<text.index(before: text.endIndex)].trimmingCharacters(in: .whitespaces).lowercased()
            guard selfTags.contains(tag) || roleTags.contains(tag) else { break }
            if selfTags.contains(tag) { isSelf = true }
            text = text[..<open.lowerBound].trimmingCharacters(in: .whitespaces)
        }
        let name = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard name.count >= 2, name.count <= maxLength, !notNames.contains(name.lowercased()) else { return nil }
        return Cleaned(name: name, isSelf: isSelf)
    }

    /// Adds `name` to `list` once, keeping first-seen order.
    static func add(_ participant: Participant, to list: inout [Participant]) {
        if let i = list.firstIndex(where: { $0.name == participant.name }) {
            if list[i].muted == nil { list[i].muted = participant.muted }
        } else {
            list.append(participant)
        }
    }

    /// The node's own text: AXStaticText keeps it in the value, other
    /// elements in the description or title.
    static func text(_ node: AXNode) -> String? {
        node.value ?? node.description ?? node.title
    }

    /// The first static text in `node`'s subtree, itself included.
    static func firstText(in node: AXNode) -> String? {
        if let t = text(node), node.role == "AXStaticText" || node.children.isEmpty { return t }
        return node.first { $0.role == "AXStaticText" && $0.value != nil }?.value
    }
}

extension AXNode {
    func hasClass(_ name: String) -> Bool { domClasses?.contains(name) == true }
    func hasClass(where match: (String) -> Bool) -> Bool { domClasses?.contains(where: match) == true }
}
