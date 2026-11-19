import FiggStore
import Foundation

/// File naming and writing for exports saved to disk. Kept apart from the
/// formatters because the same name and write rules serve every file format
/// (Markdown now, plain text and JSON later).
public enum ExportFile {
    /// Longest file name stem, in characters, before the extension.
    static let maxStemLength = 100

    /// A safe file name for `meeting`: its display title with `/`, `:`, `\`
    /// and control characters replaced by `-`, leading and trailing spaces
    /// and dots trimmed, cut to `maxStemLength` characters, then `.` plus
    /// `pathExtension`. A title that cleans to nothing gives `Meeting`.
    /// Untitled meetings use their start time, whose `:` becomes `-`.
    public static func suggestedName(for meeting: Meeting, pathExtension: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in meeting.displayTitle.unicodeScalars {
            if scalar == "/" || scalar == ":" || scalar == "\\" || scalar.properties.generalCategory == .control {
                scalars.append("-")
            } else {
                scalars.append(scalar)
            }
        }
        var stem = trimmed(String(scalars))
        if stem.count > maxStemLength {
            // The cut can leave a space or dot at the end, so trim again.
            stem = trimmed(String(stem.prefix(maxStemLength)))
        }
        if stem.isEmpty { stem = "Meeting" }
        return stem + "." + pathExtension
    }

    /// Writes `text` to `url` as UTF-8. The write is atomic, so it replaces
    /// a file already there and never leaves a half-written one.
    public static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// Drops leading and trailing U+0020 spaces and dots. Hidden files start
    /// with a dot and Finder hides or rejects names ending in one.
    static func trimmed(_ s: String) -> String {
        let isEdge: (Character) -> Bool = { $0 == " " || $0 == "." }
        guard let start = s.firstIndex(where: { !isEdge($0) }),
              let end = s.lastIndex(where: { !isEdge($0) }) else { return "" }
        return String(s[start...end])
    }
}
