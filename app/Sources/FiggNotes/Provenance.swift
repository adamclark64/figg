import Foundation

/// One rendered line of enhanced notes, marked with who wrote it.
public struct NoteLine: Sendable, Equatable, Identifiable {
    public var id: Int
    public var text: String
    /// True if this line is one the user typed; false if the AI added it.
    public var isUsers: Bool
}

/// Decides which enhanced lines came from the user's own notes. The model is
/// told to keep user lines verbatim; we match after normalising away bullet
/// markers, case, punctuation and whitespace so small formatting changes
/// still count as the user's.
public enum Provenance {
    public static func normalize(_ line: String) -> String {
        var t = line.trimmingCharacters(in: .whitespaces)
        t = t.replacingOccurrences(of: #"^(#{1,6}\s+|[-*+•]\s+(\[[ xX]\]\s+)?|\d+[.)]\s+)"#, with: "", options: .regularExpression)
        t = t.lowercased()
        t = t.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }.map(String.init).joined()
        return t.split(separator: " ").joined(separator: " ")
    }

    public static func mark(enhanced: String, userNotes: String) -> [NoteLine] {
        let mine = Set(
            userNotes.components(separatedBy: .newlines)
                .map(normalize)
                .filter { !$0.isEmpty })
        return enhanced.components(separatedBy: .newlines).enumerated().map { index, line in
            let key = normalize(line)
            return NoteLine(id: index, text: line, isUsers: !key.isEmpty && mine.contains(key))
        }
    }
}
