import Foundation

/// When the running app should look for an update again, and whether a
/// release it finds deserves a new banner.
///
/// figg often stays open for days, so a check at launch alone leaves it
/// offering whatever was newest when it started. It checks again every few
/// hours and after the Mac wakes, but tells the user about each version only
/// once: closing the banner means "not now", not "ask again at 3 pm".
public struct UpdateSchedule: Sendable, Equatable {
    /// How long a running copy waits between checks.
    public static let interval: TimeInterval = 6 * 3600
    /// After the Mac wakes, check if the last check is at least this old.
    /// Short, because a laptop is often asleep across a release, but not
    /// zero, so a lid opened and closed in a meeting does not re-check.
    public static let wakeInterval: TimeInterval = 3600

    public private(set) var lastCheck: Date?
    /// The newest version the user has been told about.
    public private(set) var offered: String?

    public init() {}

    /// Whether a check is due at `now`, given how stale the last one may be.
    public func isDue(at now: Date, after interval: TimeInterval = UpdateSchedule.interval) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }

    /// Notes that a check started at `now`, whatever its outcome, so a
    /// failing download site is asked again on the schedule, not in a loop.
    public mutating func checked(at now: Date) {
        lastCheck = now
    }

    /// Whether `version` is newer than anything already offered. Records it
    /// when it is, so the same version is never offered twice.
    public mutating func shouldOffer(_ version: String) -> Bool {
        if let offered, !UpdateChecker.isNewer(version, than: offered) { return false }
        offered = version
        return true
    }
}
