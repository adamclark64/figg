import Foundation

/// Runs async jobs strictly one at a time.
///
/// An actor alone does not do this: while one call is suspended on an
/// `await`, the actor lets the next call in. For a CoreML model that means
/// two predictions at once on the same model (dictation's live preview and
/// its final pass, or dictation and a meeting chunk), which fails with
/// "Unable to compute the asynchronous prediction".
///
/// Jobs run in the order they were submitted, with two exceptions that keep
/// dictation quick:
/// - an `urgent` job goes ahead of every waiting job that is not urgent, so
///   someone waiting for their words to be typed is not held up by meeting
///   chunks that nobody is watching;
/// - a job whose caller was cancelled while it waited is dropped instead of
///   run, so a live preview nobody will see does not delay the final pass.
/// A job that has started always finishes: a prediction cannot be stopped
/// half way.
public actor SerialRunner {
    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    private var busy = false
    private var urgentWaiters: [Waiter] = []
    private var waiters: [Waiter] = []
    private var nextID: UInt64 = 0

    public init() {}

    /// Waits its turn, then runs `job`. A job that throws does not stop the
    /// ones after it. Throws `CancellationError` without running the job if
    /// the caller is cancelled while it waits.
    public func run<T: Sendable>(urgent: Bool = false, _ job: @escaping @Sendable () async throws -> T) async throws -> T {
        try await waitForTurn(urgent: urgent)
        defer { finishTurn() }
        // Its own task, so a caller cancelled now cannot cut a running
        // prediction short.
        return try await Task { try await job() }.value
    }

    private func waitForTurn(urgent: Bool) async throws {
        guard busy else {
            busy = true
            return
        }
        let id = nextID
        nextID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Cancelled before it could queue: `abandon` found nothing.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let waiter = Waiter(id: id, continuation: continuation)
                if urgent { urgentWaiters.append(waiter) } else { waiters.append(waiter) }
            }
        } onCancel: {
            Task { await self.abandon(id) }
        }
    }

    /// Takes a cancelled caller out of the line.
    private func abandon(_ id: UInt64) {
        if let i = urgentWaiters.firstIndex(where: { $0.id == id }) {
            urgentWaiters.remove(at: i).continuation.resume(throwing: CancellationError())
        } else if let i = waiters.firstIndex(where: { $0.id == id }) {
            waiters.remove(at: i).continuation.resume(throwing: CancellationError())
        }
    }

    /// Hands the turn to the next waiter, urgent ones first. `busy` stays
    /// set across the hand-over, so nothing can slip in between.
    private func finishTurn() {
        if !urgentWaiters.isEmpty {
            urgentWaiters.removeFirst().continuation.resume()
        } else if !waiters.isEmpty {
            waiters.removeFirst().continuation.resume()
        } else {
            busy = false
        }
    }
}
