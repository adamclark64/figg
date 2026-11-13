import Foundation

/// Decides, one meter bar at a time, whether the mic is only hearing the
/// call through the Mac's speakers, so the live "Me" waveform stays flat
/// while the other side talks instead of moving for both.
///
/// The same rule as `EchoDetector` in FiggTranscription (which this module
/// cannot import), cut down for 50 ms bars: the mic counts as echo when the
/// call is sounding, the mic's loudness has been following the call's, and
/// the mic is no more than 2x as loud as the speakers would make it. Talking
/// over the call makes the mic clearly louder than that; with headphones
/// the mic does not follow the call at all, so nothing is hidden.
struct EchoGate {
    /// RMS below this (about -50 dBFS) is quiet.
    static let quiet: Float = 0.003
    /// How much louder than the predicted echo the mic may be: 2x (+6 dB).
    static let margin: Float = 2
    /// Bars with both streams sounding needed before judging (2 s).
    static let minPairs = 40
    /// Bars remembered: the last 10 s with both streams sounding.
    static let history = 200
    /// Correlation of the two loudnesses (in dB) needed to call it echo.
    static let minCorrelation: Float = 0.5

    private var pairs: [(mic: Float, system: Float)] = []

    /// - Parameters:
    ///   - mic: RMS of one mic bar.
    ///   - near: RMS of the system bar closest in time, to learn how the
    ///     mic follows the call.
    ///   - peak: the loudest system RMS around that moment (the room's tail
    ///     and buffer timing), to predict how loud the echo can be.
    mutating func isEcho(mic: Float, near: Float, peak: Float) -> Bool {
        guard mic >= Self.quiet, peak >= Self.quiet else { return false }
        if near >= Self.quiet {
            pairs.append((mic, near))
            if pairs.count > Self.history { pairs.removeFirst(pairs.count - Self.history) }
        }
        guard pairs.count >= Self.minPairs,
              Self.correlation(pairs.map { Self.db($0.mic) }, pairs.map { Self.db($0.system) }) >= Self.minCorrelation
        else { return false }
        // How loud the speakers are in the mic: most of these bars are echo
        // alone, so the median ratio is the speakers' gain.
        let ratios = pairs.map { $0.mic / $0.system }.sorted()
        let gain = ratios[ratios.count / 2]
        return mic <= peak * gain * Self.margin
    }

    static func db(_ rms: Float) -> Float { 20 * log10(max(rms, 1e-4)) }

    /// Pearson correlation; 0 when either side is flat.
    static func correlation(_ a: [Float], _ b: [Float]) -> Float {
        let n = Float(a.count)
        guard n > 1 else { return 0 }
        let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
        var cov: Float = 0, va: Float = 0, vb: Float = 0
        for (x, y) in zip(a, b) {
            cov += (x - ma) * (y - mb)
            va += (x - ma) * (x - ma)
            vb += (y - mb) * (y - mb)
        }
        guard va > 1e-6, vb > 1e-6 else { return 0 }
        return cov / (va * vb).squareRoot()
    }
}
