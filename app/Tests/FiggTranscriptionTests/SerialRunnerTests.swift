import Foundation
import Testing
@testable import FiggTranscription

/// Counts how many jobs are inside at once.
private actor Overlap {
    var inside = 0
    var most = 0
    var order: [Int] = []
    func enter(_ n: Int) { inside += 1; most = max(most, inside); order.append(n) }
    func leave() { inside -= 1 }
}

@Suite struct SerialRunnerTests {
    /// Dictation's live preview and its final pass, or dictation and a
    /// meeting chunk, must never run on the shared model at the same time.
    @Test func runsOneJobAtATimeInOrder() async throws {
        let runner = SerialRunner()
        let overlap = Overlap()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for n in 0..<8 {
                group.addTask {
                    _ = try await runner.run {
                        await overlap.enter(n)
                        try await Task.sleep(for: .milliseconds(10))
                        await overlap.leave()
                        return n
                    }
                }
                // Submit in a known order.
                try await Task.sleep(for: .milliseconds(1))
            }
            try await group.waitForAll()
        }
        #expect(await overlap.most == 1)
        #expect(await overlap.order == Array(0..<8))
    }

    @Test func aFailedJobDoesNotBlockTheNext() async throws {
        struct Boom: Error {}
        let runner = SerialRunner()
        await #expect(throws: Boom.self) {
            try await runner.run { () async throws -> Int in throw Boom() }
        }
        let value = try await runner.run { 42 }
        #expect(value == 42)
    }

    /// A dictation waiting to be typed goes ahead of meeting chunks that
    /// are only waiting, but never interrupts the one that is running.
    @Test func anUrgentJobGoesAheadOfWaitingOnes() async throws {
        let runner = SerialRunner()
        let overlap = Overlap()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for n in 0..<4 {
                group.addTask {
                    _ = try await runner.run {
                        await overlap.enter(n)
                        try await Task.sleep(for: .milliseconds(30))
                        await overlap.leave()
                    }
                }
                try await Task.sleep(for: .milliseconds(2))
            }
            group.addTask {
                _ = try await runner.run(urgent: true) {
                    await overlap.enter(99)
                    await overlap.leave()
                }
            }
            try await group.waitForAll()
        }
        #expect(await overlap.most == 1)
        #expect(await overlap.order == [0, 99, 1, 2, 3])
    }

    /// A live preview still waiting when the key is let go is never run.
    @Test func aJobCancelledWhileWaitingIsDropped() async throws {
        let runner = SerialRunner()
        let overlap = Overlap()
        let first = Task {
            try await runner.run {
                await overlap.enter(0)
                try await Task.sleep(for: .milliseconds(60))
                await overlap.leave()
            }
        }
        try await Task.sleep(for: .milliseconds(10))
        let waiting = Task {
            try await runner.run(urgent: true) { await overlap.enter(1) }
        }
        try await Task.sleep(for: .milliseconds(10))
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        try await first.value
        // The line still moves afterwards.
        _ = try await runner.run { await overlap.enter(2) }
        #expect(await overlap.order == [0, 2])
    }

    /// Cancelling the caller does not cut a running prediction short.
    @Test func aRunningJobFinishesEvenIfItsCallerIsCancelled() async throws {
        let runner = SerialRunner()
        let overlap = Overlap()
        let task = Task {
            try await runner.run { () async throws -> Int in
                await overlap.enter(0)
                try? await Task.sleep(for: .milliseconds(30))
                try Task.checkCancellation()
                await overlap.leave()
                return 7
            }
        }
        try await Task.sleep(for: .milliseconds(10))
        task.cancel()
        #expect(try await task.value == 7)
    }
}
