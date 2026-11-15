import FiggAudio
import FiggStore
@testable import FiggTranscription
import Foundation
import Testing

@Suite struct RecordingRunsTests {
    @Test func backToBackChunksAreOneRun() {
        let runs = RecordingRuns.runs([(0, 160_000), (10, 160_000), (20, 32_000)])
        #expect(runs == [RecordingRun(offset: 0, start: 0, count: 352_000)])
    }

    @Test func aLaterChunkStartsANewRun() {
        // 22 s recorded, paused, resumed at 95.3 s.
        let runs = RecordingRuns.runs([(0, 160_000), (10, 160_000), (20, 32_000), (95.3, 160_000), (105.3, 16_000)])
        #expect(runs == [
            RecordingRun(offset: 0, start: 0, count: 352_000),
            RecordingRun(offset: 95.3, start: 352_000, count: 176_000),
        ])
    }

    @Test func millisecondRoundingInNamesIsNotAPause() {
        let runs = RecordingRuns.runs([(1.234, 160_000), (11.235, 160_000)])
        #expect(runs.count == 1)
    }

    @Test func turnsMoveToTheWallClockAndSplitAtThePause() {
        let runs = [RecordingRun(offset: 2, start: 0, count: 160_000), RecordingRun(offset: 60, start: 160_000, count: 160_000)]
        let turns = [
            SpeakerTurn(start: 1, end: 4, speaker: "a"),
            SpeakerTurn(start: 8, end: 13, speaker: "b"),   // spans the pause
            SpeakerTurn(start: 15, end: 16, speaker: "a"),
        ]
        // Relative to the stream's first offset (2): the second run starts 58 s later.
        #expect(RecordingRuns.wallClock(turns, runs: runs, base: 2) == [
            SpeakerTurn(start: 1, end: 4, speaker: "a"),
            SpeakerTurn(start: 8, end: 10, speaker: "b"),
            SpeakerTurn(start: 58, end: 61, speaker: "b"),
            SpeakerTurn(start: 63, end: 64, speaker: "a"),
        ])
    }

    @Test func oneRunLeavesTurnsAlone() {
        let turns = [SpeakerTurn(start: 1, end: 4, speaker: "a")]
        #expect(RecordingRuns.wallClock(turns, runs: [RecordingRun(offset: 7, start: 0, count: 160_000)], base: 7) == turns)
    }
}

/// Answers each call with one line, half a second in, and records the
/// length of audio it was given.
actor RunRecordingTranscriber: Transcriber {
    var calls: [Int] = []
    nonisolated func transcribe(samples: [Float]) async throws -> [TranscriptSegment] {
        await record(samples.count)
        return [TranscriptSegment(start: 0.5, end: 1, text: "said something")]
    }
    private func record(_ n: Int) { calls.append(n) }
}

@Suite struct FinalPassPauseTests {
    @Test func eachSideOfAPauseIsTranscribedOnItsOwnAtItsRealTime() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let paths = FiggPaths(base: base)
        let store = try Store.inMemory()
        let meeting = Meeting(status: .recording)
        try store.save(meeting)
        let pending = paths.pendingDir(meeting.id)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        let speech = (0..<16_000).map { sin(Float($0) / 5) * 0.3 }
        // 2 s of audio, a pause, then 1 s more from 40 s: what a crash while
        // paused (or after resuming) leaves on disk.
        for offset in [0.0, 1.0, 40.0] {
            try writeChunk(speech, to: pending.appendingPathComponent(AudioChunk.fileName(stream: .system, offset: offset)))
        }
        let engine = RunRecordingTranscriber()
        let queue = TranscriptionQueue(store: store, paths: paths, transcriber: engine, keepAudio: { false }, onLines: { _ in })
        await queue.enqueuePending(meetingId: meeting.id)
        await queue.drain()
        try await queue.finalPass(meetingId: meeting.id)

        let lines = try store.transcript(meetingId: meeting.id)
        #expect(lines.map(\.start) == [0.5, 40.5])
        // Three live chunks, then one call per run (2 s and 1 s), never one across the pause.
        #expect(await engine.calls == [16_000, 16_000, 16_000, 32_000, 16_000])
    }
}
