import Foundation

/// A screenshot taken from the recording widget, kept in the meeting's own
/// folder so it is deleted with the meeting. Like audio chunks, the file
/// name holds when in the meeting it was taken, so the folder listing is
/// the whole record: no database rows to keep in step. Screenshots stay on
/// this Mac; nothing sends them to the model provider.
public struct MeetingScreenshot: Sendable, Equatable, Identifiable {
    public let url: URL
    /// Seconds from meeting start, on the same clock as transcript lines.
    public let offset: Double

    public var id: URL { url }

    public static let fileExtension = "png"

    public init(url: URL, offset: Double) {
        self.url = url
        self.offset = offset
    }

    /// `shot_0000012345.png`: the offset in milliseconds.
    public static func fileName(offset: Double) -> String {
        String(format: "shot_%010d.%@", Int((max(0, offset) * 1000).rounded()), fileExtension)
    }

    /// Parses a name from `fileName(offset:)`; nil for anything else.
    public init?(url: URL) {
        guard url.pathExtension == Self.fileExtension else { return nil }
        let parts = url.deletingPathExtension().lastPathComponent.split(separator: "_")
        guard parts.count == 2, parts[0] == "shot", let millis = Int(parts[1]) else { return nil }
        self.init(url: url, offset: Double(millis) / 1000)
    }

    /// The meeting's screenshots, oldest first.
    public static func list(in dir: URL) -> [MeetingScreenshot] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap(MeetingScreenshot.init(url:)).sorted { $0.offset < $1.offset }
    }

    /// Where a screenshot taken `offset` seconds in goes. Two in the same
    /// millisecond (or a name already taken) get the next free millisecond,
    /// so one never overwrites another.
    public static func newURL(in dir: URL, offset: Double) -> URL {
        var millis = Int((max(0, offset) * 1000).rounded())
        while true {
            let url = dir.appendingPathComponent(fileName(offset: Double(millis) / 1000))
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            millis += 1
        }
    }
}

extension FiggPaths {
    /// Screenshots taken during the meeting. Kept whatever "keep audio" says.
    public func screenshotsDir(_ id: String) -> URL {
        meetingDir(id).appendingPathComponent("screenshots", isDirectory: true)
    }
}

/// One row of the transcript pane: a line, or a screenshot at its moment.
public enum TranscriptItem: Sendable, Equatable, Identifiable {
    case line(TranscriptLine)
    case screenshot(MeetingScreenshot)

    public var id: String {
        switch self {
        case let .line(l): return "line-\(l.id ?? 0)-\(l.start)"
        case let .screenshot(s): return "shot-\(s.url.lastPathComponent)"
        }
    }

    public var time: Double {
        switch self {
        case let .line(l): return l.start
        case let .screenshot(s): return s.offset
        }
    }

    /// Lines and screenshots in meeting order. A screenshot taken during a
    /// line goes after it, so it never splits a sentence from its speaker.
    public static func merge(_ lines: [TranscriptLine], _ shots: [MeetingScreenshot]) -> [TranscriptItem] {
        var out: [TranscriptItem] = []
        var pending = shots[...]
        for line in lines {
            while let shot = pending.first, shot.offset < line.start {
                out.append(.screenshot(shot))
                pending = pending.dropFirst()
            }
            out.append(.line(line))
        }
        out += pending.map(TranscriptItem.screenshot)
        return out
    }
}
