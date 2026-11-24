import Foundation

/// Decides whether the main thread has stalled, from its heartbeats.
///
/// A step that blocks the main actor synchronously cannot be timed out and
/// no banner can draw while it blocks, so the app runs a watchdog on a
/// background queue: a main-queue timer stamps heartbeats, and the
/// watchdog asks this detector whether the gap since the last one is too
/// long. The detector is pure (times are passed in, in seconds on any
/// monotonic clock) so it can be tested without threads or waiting.
public struct StallDetector: Sendable {
    /// A gap longer than this is a stall. Three seconds is well past a
    /// slow frame but short enough to catch a hang before the user quits.
    public let threshold: TimeInterval
    public private(set) var lastHeartbeat: TimeInterval

    public init(threshold: TimeInterval = 3, start: TimeInterval) {
        self.threshold = threshold
        self.lastHeartbeat = start
    }

    /// The main thread answered at `time`. Clears any stall.
    public mutating func heartbeat(at time: TimeInterval) {
        lastHeartbeat = max(lastHeartbeat, time)
    }

    /// How long the main thread has been stalled at `now`, or nil when the
    /// gap since the last heartbeat is within the threshold.
    public func stall(at now: TimeInterval) -> TimeInterval? {
        let gap = now - lastHeartbeat
        return gap > threshold ? gap : nil
    }
}
