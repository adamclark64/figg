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
}
