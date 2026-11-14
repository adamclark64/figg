import Foundation

/// Who a meeting app showed as speaking, and when, in seconds from the start
/// of the recording (the same clock as the audio chunks). Saved beside the
/// recording as `speakers.json` so the final pass, and crash recovery, can
/// put names on the call's voices.
public struct SpeakerTimeline: Codable, Sendable, Equatable {
    public struct Span: Codable, Sendable, Equatable {
        public var start: Double
        public var end: Double
        public var name: String
        public init(start: Double, end: Double, name: String) {
            self.start = start
            self.end = end
            self.name = name
        }
    }

    public var app: String
    public var spans: [Span] = []
    /// Everyone seen on the call, in order of first appearance.
    public var participants: [String] = []
    public var selfName: String?

    public init(app: String, spans: [Span] = [], participants: [String] = [], selfName: String? = nil) {
        self.app = app
        self.spans = spans
        self.participants = participants
        self.selfName = selfName
    }

    public static let fileName = "speakers.json"

    /// Adds one reading taken at `time`. A reading counts for `interval`
    /// seconds (the poll period); readings of the same speaker less than
    /// `maxGap` apart join into one span.
    public mutating func record(_ snapshot: MeetingAppSnapshot?, at time: Double, interval: Double, maxGap: Double = 2) {
        guard let snapshot else { return }
        for p in snapshot.participants where !participants.contains(p.name) { participants.append(p.name) }
        if let me = snapshot.selfName { selfName = me }
        guard let name = snapshot.speaking else { return }
        if var last = spans.last, last.name == name, time - last.end <= maxGap {
            last.end = time + interval
            spans[spans.count - 1] = last
        } else {
            spans.append(Span(start: time, end: time + interval, name: name))
        }
    }

    /// Seconds each name was shown as speaking within [start, end].
    public func coverage(start: Double, end: Double) -> [String: Double] {
        var out: [String: Double] = [:]
        for s in spans where s.end > start && s.start < end {
            out[s.name, default: 0] += min(end, s.end) - max(start, s.start)
        }
        return out
    }

    /// The one name shown for at least `minShare` of [start, end], if any.
    public func name(start: Double, end: Double, minShare: Double = SpeakerTimeline.minShare) -> String? {
        let length = end - start
        guard length > 0, let best = coverage(start: start, end: end).max(by: { $0.value < $1.value }) else { return nil }
        return best.value / length >= minShare ? best.key : nil
    }

    /// How much of a stretch one name must cover before figg uses it. Zoom
    /// switches its speaker tile about a second late and keeps the last
    /// speaker up through silence, so a lower bar would mislabel short turns.
    public static let minShare = 0.6

    public func save(to url: URL) throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }

    public static func load(from url: URL) -> SpeakerTimeline? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SpeakerTimeline.self, from: data)
    }
}
