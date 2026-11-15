import Foundation

/// Runs heavy work at a low priority, so it uses the efficiency cores and
/// gives way to the call app. The final pass after Stop is the biggest burst
/// figg makes (minutes on several cores for an hour-long call), and people
/// often press Stop while still on the call (issue #27).
public enum BackgroundWork {
    /// Awaiting a task's `value` would lift it to the caller's priority, so
    /// the result comes back through a continuation instead, which does not.
    /// Cancelling the caller does not cancel `work`.
    public static func run<T: Sendable>(
        priority: TaskPriority = .utility,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: priority) {
                do { continuation.resume(returning: try await work()) } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
