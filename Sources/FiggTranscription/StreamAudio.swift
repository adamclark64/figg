import FiggAudio
import Foundation

/// One stream's whole recording laid out on meeting time, for the final pass.
///
/// Chunks are placed by the offset in their file names, not just joined end
/// to end, so a chunk that is missing (left in pending/ after a failed
/// transcription) leaves a silent gap instead of pulling every later word
/// earlier. The echo canceller needs this: it compares mic and system audio
/// sample by sample.
public struct StreamAudio: Sendable, Equatable {
    public static let sampleRate = Int(AudioChunk.sampleRate)
    /// Gaps up to this many samples (10 ms) are treated as no gap. Offsets in
    /// chunk file names are rounded to the millisecond, so back-to-back
    /// chunks can look a few samples apart.
    static let gapTolerance = 160

    /// Seconds from meeting start to the first sample.
    public var offset: Double
    public var samples: [Float]
    /// False when no chunk had speech: transcribing it would only give
    /// hallucinations.
    public var hasSpeech: Bool

    public init(offset: Double, samples: [Float], hasSpeech: Bool) {
        self.offset = offset
        self.samples = samples
        self.hasSpeech = hasSpeech
    }

    /// Joins one stream's chunks (oldest first), or nil for none.
    public static func assemble(_ chunks: [AudioChunk], read: (AudioChunk) throws -> [Float] = { try $0.samples() }) throws -> StreamAudio? {
        guard let first = chunks.first else { return nil }
        var samples: [Float] = []
        var anySpeech = false
        for chunk in chunks {
            let s = try read(chunk)
            if !SilenceGate.isSilent(s) { anySpeech = true }
            let position = Int(((chunk.offset - first.offset) * Double(sampleRate)).rounded())
            let gap = position - samples.count
            if gap > gapTolerance { samples += [Float](repeating: 0, count: gap) }
            samples += s
        }
        return StreamAudio(offset: first.offset, samples: samples, hasSpeech: anySpeech)
    }

    /// This stream's samples moved onto `other`'s timeline: sample `i` of the
    /// result is what this stream had at the moment of `other.samples[i]`.
    /// Silence where this stream has no audio. Same length as `other`.
    public func aligned(to other: StreamAudio) -> [Float] {
        let count = other.samples.count
        // Index in our samples of other's first sample.
        let shift = Int(((other.offset - offset) * Double(Self.sampleRate)).rounded())
        var out = [Float](repeating: 0, count: count)
        let from = max(0, -shift)          // first index in `out` we can fill
        let to = min(count, samples.count - shift)
        guard from < to else { return out }
        out.replaceSubrange(from..<to, with: samples[(from + shift)..<(to + shift)])
        return out
    }

    /// True if any 10 s window is louder than the silence gate, the same
    /// rule `assemble` applies per chunk.
    public static func hasSpeech(_ samples: [Float], window: Int = 10 * sampleRate) -> Bool {
        stride(from: 0, to: samples.count, by: window).contains {
            !SilenceGate.isSilent(Array(samples[$0..<min($0 + window, samples.count)]))
        }
    }

    /// Pads with silence or trims so the result has exactly `count` samples.
    static func fit(_ samples: [Float], to count: Int) -> [Float] {
        if samples.count == count { return samples }
        if samples.count > count { return Array(samples.prefix(count)) }
        return samples + [Float](repeating: 0, count: count - samples.count)
    }
}
