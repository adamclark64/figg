import Foundation

/// Rolling loudness history per stream, for the live waveform in the
/// recording strip. Only levels (one number per window) are kept, never
/// samples, and they never leave the process.
///
/// Fed from audio callbacks with 16 kHz mono samples (after conversion), so
/// each bar covers the same span of time on both streams even though the mic
/// and the system tap deliver buffers of very different sizes. Readers poll
/// `snapshot()` from the UI; a lock keeps it safe across the capture queues.
///
/// Without headphones the mic hears the call too, which made the "Me" row
/// move whenever the other side talked. While system audio is running, mic
/// bars are held for a moment until the system bars from the same moment are
/// in (the two streams' callbacks do not line up), and a bar that is only
/// speaker echo (`EchoGate`) is drawn flat.
public final class LevelMeter: @unchecked Sendable {
    /// Bars kept per stream.
    public let capacity: Int
    /// Samples (at 16 kHz) that make up one bar.
    public let windowSamples: Int

    private let lock = NSLock()
    private var bars: [AudioStream: [Float]] = [:]
    private var window: [AudioStream: (sumSquares: Float, count: Int)] = [:]
    /// Mic bars (time, RMS) waiting for the system bars around them.
    private var micHeld: [(time: Double, rms: Float)] = []
    /// Recent system bars (time, RMS), for judging held mic bars.
    private var systemRecent: [(time: Double, rms: Float)] = []
    private var gate = EchoGate()
    private let now: @Sendable () -> Double

    /// How long a mic bar waits for the system bars from the same moment.
    static let hold = 0.25
    /// System bars this far before or after a mic bar count as "the same
    /// moment": buffer sizes differ and the room adds a short tail.
    static let before = 0.15, after = 0.1

    /// Defaults: 50 ms bars, 3 s of history.
    /// - Parameter now: seconds on any steady clock; tests pass their own.
    public init(capacity: Int = 60, windowSamples: Int = 800, now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.capacity = capacity
        self.windowSamples = windowSamples
        self.now = now
    }

    /// Marks a stream as running, so the UI can tell "silent" from "off".
    public func activate(_ stream: AudioStream) {
        lock.withLock {
            if bars[stream] == nil { bars[stream] = Array(repeating: 0, count: capacity) }
        }
    }

    /// Adds samples; pushes a bar for every full window.
    public func record(_ stream: AudioStream, samples: [Float]) {
        let arrived = now()
        lock.withLock {
            guard bars[stream] != nil else { return }
            // Only judge the mic against a running system stream.
            let judge = stream == .mic && bars[.system] != nil
            var (sum, count) = window[stream] ?? (0, 0)
            for (i, s) in samples.enumerated() {
                sum += s * s
                count += 1
                if count == windowSamples {
                    let rms = (sum / Float(count)).squareRoot()
                    // The bar ended this long before the buffer arrived.
                    let time = arrived - Double(samples.count - 1 - i) / 16_000
                    switch stream {
                    case .system:
                        push(.system, Self.normalized(rms: rms))
                        systemRecent.append((time, rms))
                    case .mic:
                        if judge { micHeld.append((time, rms)) } else { push(.mic, Self.normalized(rms: rms)) }
                    }
                    sum = 0
                    count = 0
                }
            }
            window[stream] = (sum, count)
            releaseHeldMic(at: arrived)
        }
    }

    private func push(_ stream: AudioStream, _ level: Float) {
        guard var history = bars[stream] else { return }
        history.append(level)
        if history.count > capacity { history.removeFirst(history.count - capacity) }
        bars[stream] = history
    }

    /// Draws held mic bars whose moment has passed, flat when they were
    /// only speaker echo.
    private func releaseHeldMic(at time: Double) {
        while let bar = micHeld.first, bar.time <= time - Self.hold {
            micHeld.removeFirst()
            let around = systemRecent.filter { $0.time >= bar.time - Self.before && $0.time <= bar.time + Self.after }
            let peak = around.map(\.rms).max() ?? 0
            let near = around.min { abs($0.time - bar.time) < abs($1.time - bar.time) }?.rms ?? 0
            push(.mic, gate.isEcho(mic: bar.rms, near: near, peak: peak) ? 0 : Self.normalized(rms: bar.rms))
        }
        systemRecent.removeAll { $0.time < time - 2 }
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
