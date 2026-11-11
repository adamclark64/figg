import FiggStore
import Foundation

/// Converts figg's Markdown notes into other formats. Only the subset the
/// enhance prompt produces is handled: headings, bullets (nested by indent),
/// checkboxes, numbered lists, **bold**, *italic*, `code`, paragraphs.
public enum Formatters {
    public static func markdown(_ meeting: Meeting) -> String {
        let body = meeting.enhancedNotes ?? meeting.userNotes
        let date = meeting.createdAt.formatted(date: .abbreviated, time: .shortened)
        return "# \(meeting.displayTitle)\n_\(date)_\n\n\(body)"
    }

    // MARK: Slack

    /// Slack mrkdwn: *bold*, _italic_, • bullets, no headings.
    public static func slack(_ meeting: Meeting) -> String {
        let date = meeting.createdAt.formatted(date: .abbreviated, time: .shortened)
        let body = (meeting.enhancedNotes ?? meeting.userNotes)
            .components(separatedBy: .newlines)
            .map(slackLine)
            .joined(separator: "\n")
        return "*\(meeting.displayTitle)* · \(date)\n\n\(body)"
    }

    static func slackLine(_ line: String) -> String {
        let indent = line.prefix(while: { $0 == " " }).count
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let heading = trimmed.firstMatch(of: #/^#{1,6}\s+(.+)$/#) {
            return "*\(slackInline(String(heading.1)).replacingOccurrences(of: "*", with: ""))*"
        }
        let pad = String(repeating: "    ", count: indent / 2)
        if let box = trimmed.firstMatch(of: #/^[-*+]\s+\[([ xX])\]\s+(.+)$/#) {
            return pad + (box.1 == " " ? "☐ " : "☑ ") + slackInline(String(box.2))
        }
        if let bullet = trimmed.firstMatch(of: #/^[-*+]\s+(.+)$/#) {
            return pad + "• " + slackInline(String(bullet.1))
        }
        return pad + slackInline(trimmed)
    }

    static func slackInline(_ text: String) -> String {
        // Italic first (single *x*), via a placeholder so bold's output is not re-read as italic.
        var t = text.replacingOccurrences(of: #"(?<!\*)\*(?!\*)([^*]+)(?<!\*)\*(?!\*)"#, with: "\u{1}$1\u{1}", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "*$1*", options: .regularExpression)
        t = t.replacingOccurrences(of: #"__(.+?)__"#, with: "*$1*", options: .regularExpression)
        return t.replacingOccurrences(of: "\u{1}", with: "_")
    }

    // MARK: Confluence storage format

    /// Confluence "storage" XHTML for the page body.
    public static func confluenceStorage(_ meeting: Meeting) -> String {
        let markdown = meeting.enhancedNotes ?? meeting.userNotes
        var html = "<p><em>\(escape(meeting.createdAt.formatted(date: .complete, time: .shortened)))</em></p>"
        var listStack: [String] = []
        var taskId = 1

        func closeLists(to depth: Int) {
            while listStack.count > depth { html += "</li></\(listStack.removeLast())>" }
        }

        for raw in markdown.components(separatedBy: .newlines) {
            let indent = raw.prefix(while: { $0 == " " }).count / 2
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let h = line.firstMatch(of: #/^(#{1,6})\s+(.+)$/#) {
                closeLists(to: 0)
                let level = min(h.1.count + 1, 6)
                html += "<h\(level)>\(inlineHTML(String(h.2)))</h\(level)>"
            } else if let box = line.firstMatch(of: #/^[-*+]\s+\[([ xX])\]\s+(.+)$/#) {
                closeLists(to: 0)
                let status = box.1 == " " ? "incomplete" : "complete"
                html += "<ac:task-list><ac:task><ac:task-id>\(taskId)</ac:task-id><ac:task-status>\(status)</ac:task-status><ac:task-body>\(inlineHTML(String(box.2)))</ac:task-body></ac:task></ac:task-list>"
                taskId += 1
            } else if let item = line.firstMatch(of: #/^([-*+]|\d+[.)])\s+(.+)$/#) {
                let tag = item.1.first?.isNumber == true ? "ol" : "ul"
                let depth = indent + 1
                if listStack.count < depth {
                    while listStack.count < depth {
                        html += "<\(tag)><li>"
                        listStack.append(tag)
                    }
                } else {
                    closeLists(to: depth)
                    html += "</li><li>"
                }
                html += inlineHTML(String(item.2))
            } else {
                closeLists(to: 0)
                html += "<p>\(inlineHTML(line))</p>"
            }
        }
        closeLists(to: 0)
        return html
    }

    static func inlineHTML(_ text: String) -> String {
        var t = escape(text)
        t = t.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "<strong>$1</strong>", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?<!\*)\*(?!\*)([^*]+)\*"#, with: "<em>$1</em>", options: .regularExpression)
        t = t.replacingOccurrences(of: #"`([^`]+)`"#, with: "<code>$1</code>", options: .regularExpression)
        return t
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
