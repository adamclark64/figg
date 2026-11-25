import Foundation

/// One named startup step.
public struct StartupStep: Sendable {
    public let name: String
    /// Overrides the sequence's default timeout when set.
    public let timeout: TimeInterval?
    public let run: @Sendable () async throws -> Void

    public init(_ name: String, timeout: TimeInterval? = nil, run: @escaping @Sendable () async throws -> Void) {
        self.name = name
        self.timeout = timeout
        self.run = run
    }
}

/// Why a startup step did not finish.
public enum StartupFailure: Equatable, Sendable, CustomStringConvertible {
    case threw(String)
    case timedOut(TimeInterval)

    public var description: String {
        switch self {
        case .threw(let message): return "failed: \(message)"
        case .timedOut(let seconds): return "did not respond within \(seconds) s"
        }
    }
}

/// Runs named async steps in order, each under a timeout, so one step that
/// hangs or throws cannot hold up the rest of startup.
///
/// A step that times out is not cancelled (most system calls ignore
/// cancellation anyway); it keeps running in the background and is simply
/// no longer awaited. That is why the timeout is not a task group racing a
/// sleep: a group waits for every child before it returns, hung or not.
public struct StartupSequence: Sendable {
    public let steps: [StartupStep]
    public let defaultTimeout: TimeInterval

    public init(steps: [StartupStep], defaultTimeout: TimeInterval = 10) {
        self.steps = steps
        self.defaultTimeout = defaultTimeout
    }

    /// Runs every step in order. `onFailure` gets the step's name and why
    /// it failed; `onSuccess` gets the name of each step that finished in
    /// time. Both are called in step order, before the next step starts.
    /// Returns the failures, in order.
    @discardableResult
    public func run(
        onSuccess: @Sendable (String) async -> Void = { _ in },
        onFailure: @Sendable (String, StartupFailure) async -> Void = { _, _ in }
    ) async -> [(name: String, failure: StartupFailure)] {
        var failures: [(name: String, failure: StartupFailure)] = []
        for step in steps {
            if let failure = await Self.attempt(step, timeout: step.timeout ?? defaultTimeout) {
                failures.append((step.name, failure))
                await onFailure(step.name, failure)
            } else {
                await onSuccess(step.name)
            }
        }
        return failures
    }

    /// Runs one step, returning nil when it finished in time. The step and
    /// a timer run as unstructured tasks; whichever ends first resumes the
    /// continuation, and the other's result is dropped.
    static func attempt(_ step: StartupStep, timeout: TimeInterval) async -> StartupFailure? {
        await withCheckedContinuation { (continuation: CheckedContinuation<StartupFailure?, Never>) in
            let once = ResumeOnce(continuation)
            let nanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
            let timer = Task.detached {
                do { try await Task.sleep(nanoseconds: nanoseconds) } catch { return }
                once.resume(.timedOut(timeout))
            }
            let run = step.run
            Task.detached {
                do {
                    try await run()
                    once.resume(nil)
                } catch {
                    once.resume(.threw(String(describing: error)))
                }
                timer.cancel()
            }
        }
    }
}

/// Resumes a continuation at most once, from whichever task gets there
/// first. The lock makes the check and the clear one step.
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
