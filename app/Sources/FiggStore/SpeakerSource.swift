import Foundation

/// Values of `TranscriptLine.speakerSource`.
public enum SpeakerSource {
    /// Picked from the meeting's calendar attendees.
    public static let calendar = "calendar"
    /// Typed by hand in the transcript's rename box.
    public static let typed = "typed"
    private static let appPrefix = "app:"

    /// Shown by a meeting app ("zoom", "meet"); the id is the profile's.
    public static func app(_ id: String) -> String { appPrefix + id }

    /// The meeting app id in an `app:<id>` source, else nil.
    public static func appID(_ source: String?) -> String? {
        guard let source, source.hasPrefix(appPrefix) else { return nil }
        return String(source.dropFirst(appPrefix.count))
    }

    /// Chosen by a person rather than by figg: kept over a later final pass.
    public static func isHuman(_ source: String?) -> Bool { source == typed || source == calendar }

    /// Tooltip for the transcript's marker, or nil for an automatic label.
    /// - Parameter appName: display name for a meeting app id ("Google Meet").
    public static func describe(_ source: String?, appName: (String) -> String?) -> String? {
        if source == calendar { return "Name from the calendar" }
        if source == typed { return "Name typed by you" }
        guard let id = appID(source) else { return nil }
        return "Name from " + (appName(id) ?? "the meeting app")
    }
}

extension TranscriptLine {
    /// The new lines with each name a person chose on the old lines put
    /// back, so a typed name always wins over a later final pass.
    ///
    /// The final pass re-transcribes the same audio, so lines move and
    /// split but stay on the same stream at about the same time. Each new
    /// label on a stream ("Them 1", "Me") takes the chosen name that its
    /// lines overlap for at least half of their length, and every line
    /// with that label gets it.
    public static func keepingHumanNames(from old: [TranscriptLine], in new: [TranscriptLine]) -> [TranscriptLine] {
        let chosen = old.filter { SpeakerSource.isHuman($0.speakerSource) }
        guard !chosen.isEmpty else { return new }
        struct Key: Hashable { var speaker: Speaker; var label: String }
        var length: [Key: Double] = [:]
        var covered: [Key: [String: (seconds: Double, source: String)]] = [:]
        for line in new {
            let key = Key(speaker: line.speaker, label: line.displaySpeaker)
            length[key, default: 0] += max(0, line.end - line.start)
            for c in chosen where c.speaker == line.speaker {
                let overlap = min(line.end, c.end) - max(line.start, c.start)
                guard overlap > 0, let name = c.speakerLabel, let source = c.speakerSource else { continue }
                let prev = covered[key, default: [:]][name]?.seconds ?? 0
                covered[key, default: [:]][name] = (prev + overlap, source)
            }
        }
        var rename: [Key: (name: String, source: String)] = [:]
        for (key, names) in covered {
            guard let total = length[key], total > 0,
                  let best = names.max(by: { $0.value.seconds == $1.value.seconds ? $0.key > $1.key : $0.value.seconds < $1.value.seconds }),
                  best.value.seconds / total >= 0.5 else { continue }
            rename[key] = (best.key, best.value.source)
        }
        guard !rename.isEmpty else { return new }
        return new.map { line in
            guard let r = rename[Key(speaker: line.speaker, label: line.displaySpeaker)] else { return line }
            var line = line
            line.speakerLabel = r.name
            line.speakerSource = r.source
            return line
        }
    }
}
