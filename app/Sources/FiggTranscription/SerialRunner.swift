import Foundation

/// Runs async jobs strictly one after another, in the order they were
/// submitted.
///
/// An actor alone does not do this: while one call is suspended on an
/// `await`, the actor lets the next call in. For a CoreML model that means
/// two predictions at once on the same model (dictation's live preview and
/// its final pass, or dictation and a meeting chunk), which fails with
/// "Unable to compute the asynchronous prediction".
public actor SerialRunner {
    private var tail: Task<Void, Never>?

    public init() {}

    /// Waits for every job submitted earlier, then runs `job`. A job that
    /// throws does not stop the ones after it.
    public func run<T: Sendable>(_ job: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task<T, Error> {
            await previous?.value
            return try await job()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}
