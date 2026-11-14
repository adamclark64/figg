import Foundation

public struct ActionItem: Sendable, Equatable, Identifiable {
    public var id: Int
    public var owner: String?
    public var task: String
    public var done: Bool

    /// Jira summary line: "Owner: task" reads well in a backlog.
    public var summary: String {
        owner.map { "\($0): \(task)" } ?? task
    }
}

/// Reads the `## Action items` section the enhance prompt asks for.
public enum ActionItems {
    public static func parse(_ markdown: String) -> [ActionItem] {
        var inSection = false
        var items: [ActionItem] = []
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                let heading = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces).lowercased()
                inSection = heading.hasPrefix("action item")
                continue
            }
            guard inSection else { continue }
            guard let match = line.firstMatch(of: #/^[-*]\s+(?:\[([ xX])\]\s+)?(.+)$/#) else { continue }
            let done = (match.1.map { $0 != " " }) ?? false
            let body = String(match.2).trimmingCharacters(in: .whitespaces)
            if body.lowercased() == "none" { continue }
            let (owner, task) = splitOwner(body)
            items.append(ActionItem(id: items.count, owner: owner, task: task, done: done))
        }
        return items
    }

    /// "Ben: send deck" → ("Ben", "send deck"). Only treats a short leading
    /// phrase as an owner, so "Note: x" in a long sentence is not misread.
    static func splitOwner(_ body: String) -> (String?, String) {
        let stripped = body.replacingOccurrences(of: "**", with: "")
        guard let colon = stripped.firstIndex(of: ":") else { return (nil, stripped) }
        let owner = stripped[..<colon].trimmingCharacters(in: .whitespaces)
        let task = stripped[stripped.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !owner.isEmpty, !task.isEmpty, owner.split(separator: " ").count <= 3 else { return (nil, stripped) }
        return (owner, task)
    }
}
