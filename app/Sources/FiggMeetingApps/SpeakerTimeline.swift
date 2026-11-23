import Foundation

/// Who a meeting app showed as speaking, and when, in seconds from the start
/// of the recording (the same clock as the audio chunks). Saved beside the
/// recording as `speakers.json` so the final pass, and crash recovery, can
/// put names on the call's voices, and leave out what the mic heard while
/// you were muted.
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

    /// A stretch of the recording, in seconds on the same clock as `Span`.
    public struct Stretch: Codable, Sendable, Equatable {
        public var start: Double
        public var end: Double
        public init(start: Double, end: Double) {
            self.start = start
            self.end = end
        }
    }

    public var app: String
    public var spans: [Span] = []
    /// Everyone seen on the call, in order of first appearance.
    public var participants: [String] = []
    public var selfName: String?
    /// When the app clearly showed you as muted, in time order. Only a
    /// clear "muted" reading opens or extends one; anything else ends it.
    public var muted: [Stretch] = []

    public init(app: String, spans: [Span] = [], participants: [String] = [], selfName: String? = nil, muted: [Stretch] = []) {
        self.app = app
        self.spans = spans
        self.participants = participants
        self.selfName = selfName
        self.muted = muted
    }

    enum CodingKeys: String, CodingKey {
        case app, spans, participants, selfName, muted
    }

    /// Written by hand so a `speakers.json` saved before `muted` existed
    /// (no `muted` key) still loads; synthesized decoding needs every key.
    /// Encoding stays synthesized.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        app = try c.decode(String.self, forKey: .app)
        spans = try c.decodeIfPresent([Span].self, forKey: .spans) ?? []
        participants = try c.decodeIfPresent([String].self, forKey: .participants) ?? []
        selfName = try c.decodeIfPresent(String.self, forKey: .selfName)
        muted = try c.decodeIfPresent([Stretch].self, forKey: .muted) ?? []
    }

    public static let fileName = "speakers.json"

    /// The other people on the call, and who the app shows talking at
    /// `time` (a span still open within `grace` seconds), for the recording
    /// strip. Empty when the app showed nobody.
    public func others(at time: Double, grace: Double = 1.5) -> (people: [String], speaking: String?) {
        let people = participants.filter { $0 != selfName }
        let speaking = spans.last.flatMap { $0.end + grace >= time && $0.start <= time ? $0.name : nil }
        return (people, speaking)
    }

    /// The most voices the call audio can hold: everyone the meeting app
    /// showed, less you (your voice is on the mic, not the call). nil when
    /// the app showed nobody. An upper bound, never a count: some people
    /// never speak, and a second device of yours shows twice.
    public var callSpeakerLimit: Int? {
        let others = participants.filter { $0 != selfName }
        return others.isEmpty ? nil : others.count
    }

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

    /// Adds one reading taken at `time`, as `record(_:at:interval:maxGap:)`
    /// does, and also tracks your own mute state in `muted`.
    ///
    /// Each muted reading is credited until the next reading, so uneven or
    /// slow polls leave no holes and a stretch never runs past a reading that
    /// was not muted. A reading more than `2 * interval` after a muted one
    /// (a missed poll) ends the stretch at the muted reading plus `interval`:
    /// a gap can only end a stretch, never fill one, so unclear readings can
    /// only keep mic lines. A nil snapshot, or a `selfMuted` of false or nil,
    /// is not muted.
    /// - Parameters:
    ///   - names: false records no speaking spans, participants or self name,
    ///     so nothing about the other people is kept when only mute is wanted.
    ///   - tracker: the caller's memory of the previous reading. It lives
    ///     outside the timeline so a saved and a live timeline compare equal.
    public mutating func record(_ snapshot: MeetingAppSnapshot?, at time: Double, interval: Double, maxGap: Double = 2, names: Bool = true, tracker: inout MuteTracker) {
        recordMute(snapshot?.selfMuted == true, at: time, interval: interval, tracker: &tracker)
        if names { record(snapshot, at: time, interval: interval, maxGap: maxGap) }
    }

    private mutating func recordMute(_ isMuted: Bool, at time: Double, interval: Double, tracker: inout MuteTracker) {
        // An open stretch is joined only by a reading within 2x interval;
        // after a missed poll it keeps ending at the last muted reading plus
        // `interval`, as it already does.
        if tracker.open, let lastTime = tracker.lastTime, !muted.isEmpty, time - lastTime <= 2 * interval {
            let i = muted.count - 1
            if isMuted {
                muted[i].end = max(muted[i].end, time + interval)
                tracker.lastTime = time
                return
            }
            muted[i].end = max(muted[i].start, time)
            if muted[i].end <= muted[i].start { muted.removeLast() }
        }
        tracker.open = false
        if isMuted {
            muted.append(Stretch(start: time, end: time + interval))
            tracker.open = true
        }
        tracker.lastTime = time
    }

    /// The share of [start, end] that falls inside a muted stretch, from 0
    /// to 1; 0 for a zero or negative length. The one place this is worked
    /// out, so the live and final-pass filters agree.
    public func mutedShare(start: Double, end: Double) -> Double {
        let length = end - start
        guard length > 0 else { return 0 }
        var total = 0.0
        for s in muted where s.end > start && s.start < end {
            total += min(end, s.end) - max(start, s.start)
        }
        return min(1, total / length)
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

/// What `SpeakerTimeline.record(_:at:interval:maxGap:names:tracker:)` needs
/// to remember between readings: when the last one was taken and whether
/// the timeline's last muted stretch is still open. Owned by the caller
/// (`SpeakerWatcher`), not saved; a timeline loaded after a relaunch starts
/// with a fresh tracker and so with no open stretch.
public struct MuteTracker: Sendable, Equatable {
    var lastTime: Double?
    var open = false

    public init() {}
}
