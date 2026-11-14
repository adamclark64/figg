import FiggAudio
import FiggMeetingApps
import FiggStore
import FluidAudio
import Foundation

/// One stretch of speech by one (anonymous) speaker, in seconds from the
/// start of the audio it came from.
public struct SpeakerTurn: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var speaker: String

    public init(start: Double, end: Double, speaker: String) {
        self.start = start
        self.end = end
        self.speaker = speaker
    }
}

/// Splits one audio stream into speakers ("who spoke when"). FluidAudio's
/// offline diarizer in the app; a fake in tests.
public protocol SpeakerSeparator: Sendable {
    /// - Parameter speakerCount: exact number of people when known, else nil (auto).
    func turns(samples: [Float], speakerCount: Int?) async throws -> [SpeakerTurn]
}

/// FluidAudio's offline pipeline (pyannote segmentation + VBx clustering).
/// Models download once into FluidAudio's shared cache.
public actor FluidSpeakerSeparator: SpeakerSeparator {
    /// One manager per speaker-count setting (the count is baked into its config).
    private var managers: [Int: OfflineDiarizerManager] = [:]
    private let threshold: Double?

    /// - Parameter threshold: clustering distance; lower splits voices more
    ///   eagerly (FluidAudio default 0.6). In testing it did not separate
    ///   similar voices; giving the speaker count did.
    public init(threshold: Double? = nil) {
        self.threshold = threshold
    }

    public func turns(samples: [Float], speakerCount: Int?) async throws -> [SpeakerTurn] {
        let manager = try await prepared(speakerCount)
        let result = try await manager.process(audio: samples)
        return result.segments.map {
            SpeakerTurn(start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds), speaker: $0.speakerId)
        }
    }

    private func prepared(_ speakerCount: Int?) async throws -> OfflineDiarizerManager {
        let key = speakerCount ?? 0
        if let m = managers[key] { return m }
        var config = OfflineDiarizerConfig.default
        if let threshold { config.clustering.threshold = threshold }
        if let speakerCount { config.clustering.numSpeakers = speakerCount }
        let m = OfflineDiarizerManager(config: config)
        try await m.prepareModels()
        managers[key] = m
        return m
    }
}

/// Turns anonymous diarizer speakers into the labels people read.
public enum SpeakerLabels {
    /// Display labels for the speakers of one stream, or nil when the stream
    /// has a single speaker (then the default "Me"/"Them" is right).
    ///
    /// Mic: the speaker who talks most is assumed to be the person at the
    /// Mac ("Me"); others in the room become "Guest 1", "Guest 2"...
    /// System audio: "Them 1", "Them 2"... in order of talk time.
    public static func labels(for turns: [SpeakerTurn], stream: FiggAudio.AudioStream) -> [String: String]? {
        var talk: [String: Double] = [:]
        for t in turns { talk[t.speaker, default: 0] += max(0, t.end - t.start) }
        // Ignore speakers with under 2 s total; usually noise or a cough.
        let ranked = talk.filter { $0.value >= 2 }.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
        guard ranked.count > 1 else { return nil }
        var out: [String: String] = [:]
        for (i, id) in ranked.enumerated() {
            switch stream {
            case .mic: out[id] = i == 0 ? "Me" : "Guest \(i)"
            case .system: out[id] = "Them \(i + 1)"
            }
        }
        return out
    }

    /// The speaker whose turns overlap the line most; if none overlap, the
    /// nearest turn within 1 s. `offset` converts turn times to meeting time.
    public static func speaker(for line: TranscriptLine, turns: [SpeakerTurn], offset: Double) -> String? {
        var overlap: [String: Double] = [:]
        for t in turns {
            let o = min(line.end, t.end + offset) - max(line.start, t.start + offset)
            if o > 0 { overlap[t.speaker, default: 0] += o }
        }
        if let best = overlap.max(by: { $0.value < $1.value }) { return best.key }
        let nearest = turns.min { distance(line, $0, offset) < distance(line, $1, offset) }
        return nearest.flatMap { distance(line, $0, offset) <= 1 ? $0.speaker : nil }
    }

    private static func distance(_ line: TranscriptLine, _ t: SpeakerTurn, _ offset: Double) -> Double {
        max(0, max(t.start + offset - line.end, line.start - (t.end + offset)))
    }

    /// Sets `speakerLabel` on each line from the stream's diarization.
    /// - Parameter timeline: for the system audio, who the meeting app
    ///   showed as speaking. A voice that one name covers for most of its
    ///   talk time gets that name instead of "Them N".
    public static func apply(_ turns: [SpeakerTurn], to lines: [TranscriptLine], stream: FiggAudio.AudioStream, offset: Double, timeline: SpeakerTimeline? = nil) -> [TranscriptLine] {
        var names = labels(for: turns, stream: stream)
        if stream == .system, let timeline {
            let named = appNames(for: turns, timeline: timeline, offset: offset)
            if !named.isEmpty { names = (names ?? [:]).merging(named) { _, app in app } }
        }
        guard let names else { return lines }
        return lines.map { line in
            var line = line
            if let id = speaker(for: line, turns: turns, offset: offset), let name = names[id] {
                line.speakerLabel = name
            }
            return line
        }
    }

    /// Names from the meeting app for diarizer voices: the name shown as
    /// speaking for at least `SpeakerTimeline.minShare` of a voice's talk
    /// time. Voices without such a name are left out.
    public static func appNames(for turns: [SpeakerTurn], timeline: SpeakerTimeline, offset: Double) -> [String: String] {
        var talk: [String: Double] = [:]
        var shown: [String: [String: Double]] = [:]
        for t in turns {
            talk[t.speaker, default: 0] += max(0, t.end - t.start)
            for (name, seconds) in timeline.coverage(start: t.start + offset, end: t.end + offset) {
                shown[t.speaker, default: [:]][name, default: 0] += seconds
            }
        }
        var out: [String: String] = [:]
        for (id, seconds) in talk where seconds > 0 {
            if let best = shown[id]?.max(by: { $0.value < $1.value }), best.value / seconds >= SpeakerTimeline.minShare {
                out[id] = best.key
            }
        }
        return out
    }

    /// Names system-audio lines that diarization left unlabelled (it was
    /// off, failed, or heard one voice it could not name), one line at a time.
    public static func nameLines(_ lines: [TranscriptLine], timeline: SpeakerTimeline) -> [TranscriptLine] {
        lines.map { line in
            guard line.speaker == .them, line.speakerLabel == nil,
                  let name = timeline.name(start: line.start, end: line.end) else { return line }
            var line = line
            line.speakerLabel = name
            return line
        }
    }
}
