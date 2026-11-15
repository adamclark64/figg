import FiggAudio
import Foundation

/// One stretch of a stream recorded without a pause.
public struct RecordingRun: Sendable, Equatable {
    /// Seconds from meeting start to the run's first sample (wall clock).
    public var offset: Double
    /// Index of the run's first sample in the stream's joined samples.
    public var start: Int
    public var count: Int

    public init(offset: Double, start: Int, count: Int) {
        self.offset = offset
        self.start = start
        self.count = count
    }

    public var duration: Double { Double(count) / AudioChunk.sampleRate }
}

/// Finds the pauses in a stream from its chunk files alone. Chunk names hold
/// their wall-clock offset, and while recording each chunk starts where the
/// last one ended, so a chunk that starts noticeably later than that marks
/// a pause. Needing no other record means a meeting left paused by a crash
/// recovers like any other.
///
/// The final pass transcribes each run on its own, so no line spans a pause
/// and every timestamp stays true to the wall clock, but it separates
/// speakers over the whole stream at once, so a voice keeps its label on
/// both sides of a pause. `wallClock` moves those speaker turns from the
/// joined samples' time back to the meeting's.
public enum RecordingRuns {
    /// Slack for rounding in chunk names (they hold whole milliseconds).
    public static let tolerance = 0.5

    /// Groups chunks, in order, into runs.
    /// - Parameter chunks: each chunk's wall-clock offset and sample count.
    public static func runs(_ chunks: [(offset: Double, samples: Int)]) -> [RecordingRun] {
        var runs: [RecordingRun] = []
        var next = 0
        for chunk in chunks {
            if var last = runs.last, chunk.offset <= last.offset + last.duration + tolerance {
                last.count += chunk.samples
                runs[runs.count - 1] = last
            } else {
                runs.append(RecordingRun(offset: chunk.offset, start: next, count: chunk.samples))
            }
            next += chunk.samples
        }
        return runs
    }

    /// Turns timed in seconds from the start of the joined samples, retimed
    /// to seconds from `base` on the wall clock (base is the stream's first
    /// offset, as `SpeakerLabels.apply` expects). A turn that spans a pause
    /// is split in two.
    public static func wallClock(_ turns: [SpeakerTurn], runs: [RecordingRun], base: Double) -> [SpeakerTurn] {
        guard runs.count > 1 else { return turns }
        var out: [SpeakerTurn] = []
        for turn in turns {
            for run in runs {
                let runStart = Double(run.start) / AudioChunk.sampleRate
                let runEnd = runStart + run.duration
                let from = max(turn.start, runStart), to = min(turn.end, runEnd)
                guard to > from else { continue }
                let shift = run.offset - base - runStart
                out.append(SpeakerTurn(start: from + shift, end: to + shift, speaker: turn.speaker))
            }
        }
        return out
    }
}
