import FiggStore
import Foundation

/// Drops mic lines that are only the call audio picked up from the speakers.
///
/// Without headphones the mic hears the remote side, so one utterance is
/// transcribed twice at the same time: once from system audio ("Them") and
/// once from the mic ("Me"). The system-audio copy is the clean one, so the
/// mic copy goes. A mic line counts as an echo only when nearly all its words
/// appear, in order, in system-audio lines at the same moment; real speech
/// over the top of someone (different words) is kept.
public enum EchoFilter {
    /// Seconds of slack around a mic line when looking for its system copy.
    /// Speaker-to-mic latency is tens of ms, but the two streams are
    /// transcribed separately so segment edges can drift.
    static let window = 1.5
    /// Share of the mic line's words that must appear, in order, in the
    /// nearby system lines.
    static let minShared = 0.7
    /// Lines shorter than this ("yeah", "okay") need every word to match,
    /// since a short real reply can easily share a word with the other side.
    static let shortLine = 3

    public static func removeEchoes(from lines: [TranscriptLine]) -> [TranscriptLine] {
        let system = lines.filter { $0.speaker == .them }
        guard !system.isEmpty else { return lines }
        return lines.filter { $0.speaker != .me || !isEcho($0, system: system) }
    }

    static func isEcho(_ mic: TranscriptLine, system: [TranscriptLine], window: Double = EchoFilter.window, minShared: Double = EchoFilter.minShared) -> Bool {
        let micWords = words(mic.text)
        guard !micWords.isEmpty else { return false }
        let nearby = system
            .filter { $0.end >= mic.start - window && $0.start <= mic.end + window }
            .sorted { $0.start < $1.start }
        guard !nearby.isEmpty else { return false }
        let systemWords = nearby.flatMap { words($0.text) }
        let shared = Double(commonSubsequence(micWords, systemWords)) / Double(micWords.count)
        return shared >= (micWords.count < shortLine ? 1 : minShared)
    }

    /// Share of mic lines (0 to 1) that look like a copy of the call audio,
    /// for measuring how much echo a transcript still has. Looser than the
    /// filter (half the words, 3 s of slack), so the near misses it lets
    /// through still count.
    public static func duplicateRate(_ lines: [TranscriptLine]) -> Double {
        let mic = lines.filter { $0.speaker == .me }
        guard !mic.isEmpty else { return 0 }
        let system = lines.filter { $0.speaker == .them }
        let copies = mic.filter { isEcho($0, system: system, window: 3, minShared: 0.5) }
        return Double(copies.count) / Double(mic.count)
    }

    /// Lowercased words with punctuation stripped, so "Okay," matches "okay".
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
    }

    /// Length of the longest common subsequence of two word lists.
    static func commonSubsequence(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var row = [Int](repeating: 0, count: b.count + 1)
            for (j, y) in b.enumerated() {
                row[j + 1] = x == y ? previous[j] + 1 : max(previous[j + 1], row[j])
            }
            previous = row
        }
        return previous[b.count]
    }
}
