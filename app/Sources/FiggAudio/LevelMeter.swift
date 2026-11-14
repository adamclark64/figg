import Foundation

/// Rolling loudness history per stream, for the live waveform in the
/// recording strip. Only levels (one number per window) are kept, never
/// samples, and they never leave the process.
///
/// Fed from audio callbacks with 16 kHz mono samples (after conversion), so
/// each bar covers the same span of time on both streams even though the mic
/// and the system tap deliver buffers of very different sizes. Readers poll
/// `snapshot()` from the UI; a lock keeps it safe across the capture queues.
public final class LevelMeter: @unchecked Sendable {
    /// Bars kept per stream.
    public let capacity: Int
    /// Samples (at 16 kHz) that make up one bar.
    public let windowSamples: Int

    private let lock = NSLock()
    private var bars: [AudioStream: [Float]] = [:]
    private var window: [AudioStream: (sumSquares: Float, count: Int)] = [:]

    /// Defaults: 50 ms bars, 3 s of history.
    public init(capacity: Int = 60, windowSamples: Int = 800) {
        self.capacity = capacity
        self.windowSamples = windowSamples
    }

    /// Marks a stream as running, so the UI can tell "silent" from "off".
    public func activate(_ stream: AudioStream) {
        lock.withLock {
            if bars[stream] == nil { bars[stream] = Array(repeating: 0, count: capacity) }
        }
    }

    /// Adds samples; pushes a bar for every full window.
    public func record(_ stream: AudioStream, samples: [Float]) {
        lock.withLock {
            guard var history = bars[stream] else { return }
            var (sum, count) = window[stream] ?? (0, 0)
            for s in samples {
                sum += s * s
                count += 1
                if count == windowSamples {
                    history.append(Self.normalized(rms: (sum / Float(count)).squareRoot()))
                    sum = 0
                    count = 0
                }
            }
            if history.count > capacity { history.removeFirst(history.count - capacity) }
            bars[stream] = history
            window[stream] = (sum, count)
        }
    }

    /// Bars oldest first, each 0...1; nil for a stream that never started.
    public func snapshot() -> [AudioStream: [Float]] {
        lock.withLock { bars }
    }

    /// Maps RMS to 0...1 on a -60...0 dBFS scale, which is how loud speech
    /// looks to a person. Exact digital silence (missing permission) is 0.
    public static func normalized(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(1, max(0, (db + 60) / 60))
    }
}
