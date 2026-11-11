import Foundation

/// Markdown task-list lines ("- [ ] task" / "- [x] task") in notes.
///
/// The checked state lives in the notes markdown itself, not in a separate
/// table, so ticking a box in the app, `ActionItems.parse`, the exporters
/// and a hand edit all read and write the same thing.
public enum Checkboxes {
    /// The checkbox on one line of notes, or nil if the line is not one.
    /// Leading indentation is allowed. The view and `toggle` both go through
    /// this so a box that is drawn is always a box that can be flipped.
    public static func match(_ line: String) -> (done: Bool, label: String)? {
        guard let m = line.firstMatch(of: #/^\s*[-*+]\s+\[([ xX])\]\s+(\S.*)$/#) else { return nil }
        return (m.1 != " ", String(m.2).trimmingCharacters(in: .whitespaces))
    }

    /// Returns `markdown` with the checkbox on line `line` flipped. Lines are
    /// counted the way `Provenance.mark` numbers them (`NoteLine.id`). Any
    /// other line, or an index out of range, returns the text unchanged.
    ///
    /// Only the one character between the brackets is replaced, so line
    /// endings and everything else in the notes survive byte for byte.
    public static func toggle(_ markdown: String, line: Int) -> String {
        guard line >= 0 else { return markdown }
        let scalars = markdown.unicodeScalars
        let isNewline: (Unicode.Scalar) -> Bool = { CharacterSet.newlines.contains($0) }

        // Walk scalars, not Characters: "\r\n" is one Character but two
        // separators to `components(separatedBy: .newlines)`, which is what
        // numbered the lines.
        var start = scalars.startIndex
        for _ in 0..<line {
            guard let newline = scalars[start...].firstIndex(where: isNewline) else { return markdown }
            start = scalars.index(after: newline)
        }
        let end = scalars[start...].firstIndex(where: isNewline) ?? scalars.endIndex

        let text = String(scalars[start..<end])
        guard let done = match(text)?.done, let open = text.unicodeScalars.firstIndex(of: "[") else { return markdown }
        let mark = scalars.index(start, offsetBy: text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: open) + 1)

        let flipped: Unicode.Scalar = done ? " " : "x"
        var result = markdown
        result.unicodeScalars.replaceSubrange(mark..<scalars.index(after: mark), with: CollectionOfOne(flipped))
        return result
    }
}
