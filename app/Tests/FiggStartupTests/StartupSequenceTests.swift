import Foundation
import Testing
@testable import FiggStartup

/// Collects strings from concurrent callbacks for tests.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func add(_ item: String) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

struct FakeStartupError: Error, CustomStringConvertible {
    var description: String { "fake failure" }
}

/// A step that never finishes in test time.
func hang() async throws {
    try await Task.sleep(nanoseconds: 60_000_000_000)
}

struct StartupSequenceTests {
    @Test func stepsRunInOrder() async {
        let ran = Recorder()
        let steps = ["a", "b", "c"].map { name in StartupStep(name) { ran.add(name) } }
        let failures = await StartupSequence(steps: steps, defaultTimeout: 1).run()
        #expect(ran.all == ["a", "b", "c"])
        #expect(failures.isEmpty)
    }

    @Test func hangingStepTimesOutAndTheNextStillRuns() async {
        let ran = Recorder()
        let failed = Recorder()
        let steps = [
            StartupStep("stuck") { try await hang() },
            StartupStep("after") { ran.add("after") },
        ]
        let started = Date()
        let failures = await StartupSequence(steps: steps, defaultTimeout: 0.2).run(
            onSuccess: { ran.add("ok \($0)") },
            onFailure: { name, reason in failed.add("\(name): \(reason)") }
        )
        let elapsed = Date().timeIntervalSince(started)
        #expect(ran.all == ["after", "ok after"])
        #expect(failures.count == 1)
        #expect(failures.first?.name == "stuck")
        #expect(failures.first?.failure == .timedOut(0.2))
        #expect(failed.all == ["stuck: did not respond within 0.2 s"])
        // About the timeout, not the 60 s the step would take.
        #expect(elapsed < 5)
    }

    @Test func throwingStepIsReportedByName() async {
        let ran = Recorder()
        let failed = Recorder()
        let steps = [
            StartupStep("first") { ran.add("first") },
            StartupStep("broken") { throw FakeStartupError() },
            StartupStep("last") { ran.add("last") },
        ]
        await StartupSequence(steps: steps, defaultTimeout: 1).run(
            onFailure: { name, reason in failed.add("\(name): \(reason)") }
        )
        #expect(ran.all == ["first", "last"])
        #expect(failed.all == ["broken: failed: fake failure"])
    }

    @Test func perStepTimeoutOverridesTheDefault() async {
        let steps = [StartupStep("quick", timeout: 0.05) { try await hang() }]
        let started = Date()
        let failures = await StartupSequence(steps: steps, defaultTimeout: 60).run()
        #expect(failures.first?.failure == .timedOut(0.05))
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func defaultTimeoutIsTenSeconds() {
        #expect(StartupSequence(steps: []).defaultTimeout == 10)
    }

    /// Several hung steps cost about one timeout each, so the whole
    /// sequence still ends.
    @Test func severalHungStepsAllFinish() async {
        let steps = (1...4).map { StartupStep("hung \($0)") { try await hang() } }
        let started = Date()
        let failures = await StartupSequence(steps: steps, defaultTimeout: 0.05).run()
        #expect(failures.map(\.name) == ["hung 1", "hung 2", "hung 3", "hung 4"])
        #expect(Date().timeIntervalSince(started) < 5)
    }
}
