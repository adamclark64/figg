import Accelerate
import Foundation

/// Tells mic sound that came out of the Mac's speakers from sound made in
/// the room, by comparing the mic with the system audio (what the speakers
/// played). Pure functions over sample arrays, so it runs live on 10 s
/// chunks as well as on a whole recording after Stop.
///
/// Two jobs:
/// - `estimateDelay`: how far the mic's copy of the call audio sits from the
///   system stream on meeting time. Chunk offsets alone are not enough: on a
///   real call the mic's copy came 56 ms *before* the system samples it
///   echoed (the two streams start up separately), and an echo canceller
///   cannot remove an echo that arrives before its reference.
/// - `map`: short frames marked quiet, echo or speech. A frame is echo when
///   the mic is no louder than the speakers' sound would make it; a person
///   talking over the call (or with no call audio at all) makes the mic
///   clearly louder than that.
public enum EchoDetector {
    static let sampleRate = StreamAudio.sampleRate
    /// Envelope step for the delay search: 5 ms. LocalVQE coped with the
    /// reference anywhere from 4 to 144 ms ahead of the echo on the real
    /// call, so this is fine enough.
    static let delayFrame = 80
    /// Frame length for the echo map: 20 ms.
    static let mapFrame = 320
    /// The furthest the streams are searched apart, either way.
    public static let maxDelaySeconds = 1.0
    /// Correlation of the two loudness envelopes (while the call sounds)
    /// needed to trust a delay. Headphones scored 0.05 in the bench; echo
    /// on the real call and the synthetic ones scored 0.85 to 0.94.
    static let minConfidence: Float = 0.3
    /// Mic RMS below this is quiet (about -50 dBFS), a little under
    /// `SilenceGate` so the soft ends of words are still judged.
    static let quietRMS: Float = 0.003
    /// How much louder than the predicted echo the mic may be and still
    /// count as echo: 2x in amplitude (+6 dB). Room speech over the call
    /// is usually far above that.
    static let echoMargin: Float = 2
    /// The speakers' sound lingers in the room; a mic frame is compared with
    /// the loudest reference frame this far back (100 ms).
    static let tailFrames = 5
    /// A mic line goes when at least this share of its sounding frames is echo.
    public static let echoLineShare = 0.7
    /// How far ahead of the echo the shifted reference is placed for the
    /// canceller: the middle of the 4 to 144 ms that worked on the real call.
    public static let referenceLead = 50 * sampleRate / 1000

    /// Where the call audio shows up in the mic, relative to `reference`.
    public struct Delay: Sendable, Equatable {
        /// Samples from a sound in `reference` to its copy in the mic.
        /// Negative when the mic's copy comes first (stream offsets are off).
        public var samples: Int
        /// Envelope correlation at that delay, 0 to 1.
        public var confidence: Float

        public var seconds: Double { Double(samples) / Double(EchoDetector.sampleRate) }
    }

    public enum Frame: Sendable, Equatable { case quiet, echo, speech }

    /// Quiet/echo/speech per 20 ms frame of the mic, on meeting time.
    public struct Map: Sendable, Equatable {
        /// Meeting time of frame 0.
        public var offset: Double
        public var frames: [Frame]
        /// The delay the map was built with; nil means no echo was found, so
        /// every sounding frame is speech.
        public var delay: Delay?

        public static let frameSeconds = Double(EchoDetector.mapFrame) / Double(EchoDetector.sampleRate)

        /// Share (0 to 1) of the sounding frames between two meeting times
        /// that are echo; nil when the mic was quiet the whole time.
        public func echoShare(start: Double, end: Double) -> Double? {
            let from = max(0, Int(((start - offset) / Self.frameSeconds).rounded(.down)))
            let to = min(frames.count, Int(((end - offset) / Self.frameSeconds).rounded(.up)))
            guard from < to else { return nil }
            var echo = 0, speech = 0
            for frame in frames[from..<to] {
                if frame == .echo { echo += 1 } else if frame == .speech { speech += 1 }
            }
            guard echo + speech > 0 else { return nil }
            return Double(echo) / Double(echo + speech)
        }

        /// True when a line over this span is mostly the call heard through
        /// the speakers.
        public func isEcho(start: Double, end: Double) -> Bool {
            (echoShare(start: start, end: end) ?? 0) >= EchoDetector.echoLineShare
        }
    }

    /// RMS of each `frame`-sample step.
    static func envelope(_ x: [Float], frame: Int) -> [Float] {
        let count = x.count / frame
        guard count > 0 else { return [] }
        return x.withUnsafeBufferPointer { p in
            (0..<count).map { i in
                var rms: Float = 0
                vDSP_rmsqv(p.baseAddress! + i * frame, 1, &rms, vDSP_Length(frame))
                return rms
            }
        }
    }

    /// Finds the delay at which the mic's loudness best follows the
    /// reference's. Loudness envelopes rather than raw samples, so it is
    /// cheap on an hour of audio and does not care that a speaker can flip
    /// the waveform's sign. Nil when nothing in the mic follows the
    /// reference (headphones, or no call audio).
    ///
    /// Only frames where the call is sounding are scored, in dB: people
    /// take turns, so over the whole recording the mic is loudest exactly
    /// when the call is quiet, which hides the echo from a plain correlation.
    /// While the call sounds, an echo makes the mic rise and fall with it.
    /// - Parameters:
    ///   - mic, reference: 16 kHz samples on the same timeline (see
    ///     `StreamAudio.aligned(to:)`).
    public static func estimateDelay(mic: [Float], reference: [Float], maxSeconds: Double = maxDelaySeconds) -> Delay? {
        let m = envelope(mic, frame: delayFrame).map(decibels)
        let rLevels = envelope(reference, frame: delayFrame)
        let n = min(m.count, rLevels.count)
        let maxLag = Int(maxSeconds * Double(sampleRate)) / delayFrame
        guard n > 2 * maxLag + 10 else { return nil }
        // Sounding reference frames away from the ends, so every lag scores
        // the same frames.
        let active = (maxLag..<(n - maxLag)).filter { rLevels[$0] >= quietRMS }
        guard active.count >= 20 else { return nil }
        let r = active.map { decibels(rLevels[$0]) }

        var best: (lag: Int, score: Float) = (0, -1)
        var x = [Float](repeating: 0, count: active.count)
        for lag in -maxLag...maxLag {
            for (k, i) in active.enumerated() { x[k] = m[i + lag] }
            let score = pearson(x, r)
            if score > best.score { best = (lag, score) }
        }
        guard best.score >= minConfidence else { return nil }
        return Delay(samples: best.lag * delayFrame, confidence: min(1, best.score))
    }

    /// Level in dB, floored at -80 dBFS so digital silence stays finite.
    static func decibels(_ rms: Float) -> Float { 20 * log10(max(rms, 1e-4)) }

    /// Pearson correlation; 0 when either side is flat.
    static func pearson(_ a: [Float], _ b: [Float]) -> Float {
        var ma: Float = 0, sa: Float = 0, mb: Float = 0, sb: Float = 0
        var na = [Float](repeating: 0, count: a.count), nb = na
        vDSP_normalize(a, 1, &na, 1, &ma, &sa, vDSP_Length(a.count))
        vDSP_normalize(b, 1, &nb, 1, &mb, &sb, vDSP_Length(b.count))
        guard sa > 1e-6, sb > 1e-6 else { return 0 }
        var dot: Float = 0
        vDSP_dotpr(na, 1, nb, 1, &dot, vDSP_Length(a.count))
        return dot / Float(a.count)
    }

    /// `reference` moved so that each sound sits `lead` samples ahead of its
    /// copy in the mic, the way an echo canceller expects. Same length.
    public static func shift(_ reference: [Float], for delay: Delay, lead: Int = referenceLead) -> [Float] {
        let by = delay.samples - lead   // positive: later
        guard by != 0 else { return reference }
        let n = reference.count
        var out = [Float](repeating: 0, count: n)
        if by > 0 {
            if by < n { out.replaceSubrange(by..<n, with: reference[0..<(n - by)]) }
        } else if -by < n {
            out.replaceSubrange(0..<(n + by), with: reference[(-by)..<n])
        }
        return out
    }

    /// Marks each 20 ms of the mic as quiet, echo or speech.
    /// - Parameters:
    ///   - mic, reference: 16 kHz samples on the same timeline.
    ///   - offset: meeting time of `mic[0]`.
    ///   - delay: a known delay (say from earlier in the meeting); estimated
    ///     from these samples when nil.
    public static func map(mic: [Float], reference: [Float], offset: Double, delay known: Delay? = nil) -> Map {
        let m = envelope(mic, frame: mapFrame)
        let speechOnly = Map(offset: offset, frames: m.map { $0 < quietRMS ? .quiet : .speech }, delay: nil)
        guard let delay = known ?? estimateDelay(mic: mic, reference: reference) else { return speechOnly }

        // Reference loudness at the moment each mic frame would hear it,
        // held for the room's tail.
        let lagFrames = Int((Double(delay.samples) / Double(mapFrame)).rounded())
        let r = envelope(reference, frame: mapFrame)
        let heard: [Float] = m.indices.map { i in
            var peak: Float = 0
            for k in 0...tailFrames {
                let j = i - lagFrames - k
                if j >= 0, j < r.count { peak = max(peak, r[j]) }
            }
            return peak
        }

        // How loud the speakers are in the mic: the median mic/reference
        // ratio while the call is sounding. Most of that time is echo alone,
        // and with headphones the ratio is tiny, so room speech stands out.
        let ratios = m.indices.compactMap { i -> Float? in
            heard[i] >= quietRMS && m[i] >= quietRMS ? m[i] / heard[i] : nil
        }.sorted()
        guard !ratios.isEmpty else { return Map(offset: offset, frames: speechOnly.frames, delay: delay) }
        let gain = ratios[ratios.count / 2]

        let frames: [Frame] = m.indices.map { i in
            if m[i] < quietRMS { return .quiet }
            return m[i] <= heard[i] * gain * echoMargin ? .echo : .speech
        }
        return Map(offset: offset, frames: frames, delay: delay)
    }
}
