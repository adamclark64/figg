import Foundation

/// Which part of a dictation the live preview transcribes.
///
/// The preview runs again about every second on everything heard so far, so
/// its cost grows with the dictation, and the final pass has to wait for a
/// preview that is running when the key is let go. Only the last few lines
/// fit in the panel anyway, so only the last stretch of audio is
/// transcribed: the preview costs the same however long the dictation is.
public enum DictationPreview {
    /// Seconds of audio the preview transcribes at most.
    public static let seconds = 15.0

    /// The end of `samples`, at most `seconds` long (plus up to two more to
    /// start in a pause, not in the middle of a word), and whether anything
    /// was left off the front.
    public static func tail(
        _ samples: [Float], seconds: Double = seconds, sampleRate: Double = 16_000
    ) -> (samples: [Float], cut: Bool) {
        let keep = Int(seconds * sampleRate)
        guard samples.count > keep else { return (samples, false) }
        let latest = samples.count - keep
        let earliest = max(0, latest - Int(2 * sampleRate))
        // The quietest 50 ms in the two seconds before the cut point.
        let frame = max(1, Int(0.05 * sampleRate))
        var start = latest
        var quietest = Float.greatestFiniteMagnitude
        var i = earliest
        while i + frame <= latest {
            var energy: Float = 0
            for k in i..<(i + frame) { energy += samples[k] * samples[k] }
            if energy <= quietest {
                quietest = energy
                start = i
            }
            i += frame
        }
        return (Array(samples[start...]), start > 0)
    }
}
