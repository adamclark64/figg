import FiggStore
import Foundation

/// Builds the text of a saved Markdown file: the meeting's notes exactly as
/// "Copy as Markdown" copies them, then the transcript when there is one.
/// It reuses `Formatters.markdown` rather than changing it, so the copied
/// text and the start of the saved file can never drift apart.
public enum MarkdownExport {
    /// The whole document. With no lines it equals `Formatters.markdown`
    /// byte for byte; the notes part is never trimmed or edited.
    public static func document(_ meeting: Meeting, lines: [TranscriptLine]) -> String {
        let notes = Formatters.markdown(meeting)
        if lines.isEmpty { return notes }
        let items = sorted(lines).map(item)
        return notes + "\n\n## Transcript\n\n" + items.joined(separator: "\n") + "\n"
    }

    /// One list item, with the same timestamp and speaker name the
    /// transcript view shows.
    static func item(_ line: TranscriptLine) -> String {
        "- **[\(formatTimestamp(line.start))] \(line.displaySpeaker):** \(flat(line.text))"
    }

    /// Replaces each newline character with a space so a line stays one
    /// list item. Working on `Character` turns `\r\n` (one grapheme) into a
    /// single space.
    static func flat(_ text: String) -> String {
        String(text.map { $0.isNewline ? " " : $0 })
    }

    /// Lines in order of start time; ties keep their input order without
    /// relying on `sorted` being stable.
    static func sorted(_ lines: [TranscriptLine]) -> [TranscriptLine] {
        lines.enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)
    }
}
