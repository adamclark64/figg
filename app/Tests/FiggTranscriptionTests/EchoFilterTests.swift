import FiggAudio
import FiggStore
@testable import FiggTranscription
import Foundation
import Testing

@Suite struct EchoFilterTests {
    func line(_ speaker: Speaker, _ start: Double, _ end: Double, _ text: String) -> TranscriptLine {
        TranscriptLine(meetingId: "m", speaker: speaker, start: start, end: end, text: text)
    }

    @Test func dropsMicCopyOfCallAudio() {
        let lines = [
            line(.them, 284, 288, "Can everyone see my screen now?"),
            line(.me, 284.2, 288.1, "Can everyone see my screen now?"),
        ]
        #expect(EchoFilter.removeEchoes(from: lines).map(\.speaker) == [.them])
    }

    @Test func toleratesSmallTranscriptionDifferences() {
        let lines = [
            line(.them, 10, 14, "So the plan is to ship the beta on Friday."),
            line(.me, 10.1, 14.2, "So the plan is ship the beta Friday"),
        ]
        #expect(EchoFilter.removeEchoes(from: lines).count == 1)
    }

    @Test func matchesAcrossDifferentSegmentation() {
        // The system stream split the sentence in two; the mic kept it whole.
        let lines = [
            line(.them, 20, 22, "Let's start with the roadmap."),
            line(.them, 22.3, 24, "Then budget."),
            line(.me, 20.1, 24.1, "Let's start with the roadmap. Then budget."),
        ]
        #expect(EchoFilter.removeEchoes(from: lines).allSatisfy { $0.speaker == .them })
    }

    @Test func keepsRealReplyAtTheSameTime() {
        let lines = [
            line(.them, 30, 33, "Does Friday work for the launch?"),
            line(.me, 31, 33, "Friday is too early for us."),
        ]
        #expect(EchoFilter.removeEchoes(from: lines).count == 2)
    }

    @Test func keepsSameWordsAtADifferentTime() {
        let lines = [
            line(.them, 40, 42, "Sounds good to me."),
            line(.me, 60, 62, "Sounds good to me."),
        ]
        #expect(EchoFilter.removeEchoes(from: lines).count == 2)
    }

    @Test func shortLinesNeedAnExactMatch() {
        let lines = [
            line(.them, 50, 51, "Yeah, totally."),
            line(.me, 50.2, 50.8, "Yeah, no."),      // shares a word: a real reply
            line(.them, 55, 56, "Okay."),
            line(.me, 55.1, 55.9, "okay"),          // full match: echo
        ]
        #expect(EchoFilter.removeEchoes(from: lines).map(\.text) == ["Yeah, totally.", "Yeah, no.", "Okay."])
    }

    @Test func leavesMicOnlyMeetingsAlone() {
        let lines = [line(.me, 0, 2, "Notes to self."), line(.me, 3, 5, "Notes to self.")]
        #expect(EchoFilter.removeEchoes(from: lines) == lines)
    }

    @Test func commonSubsequenceLength() {
        #expect(EchoFilter.commonSubsequence(["a", "b", "c", "d"], ["a", "x", "c", "d"]) == 3)
        #expect(EchoFilter.commonSubsequence([], ["a"]) == 0)
    }
}

/// Returns the same sentence for every stream, as when the mic hears the call.
struct EchoTranscriber: Transcriber {
    func transcribe(samples: [Float]) async throws -> [TranscriptSegment] {
        [TranscriptSegment(start: 0.5, end: 2.5, text: "Can everyone see my screen now?")]
    }
}

@Suite struct FinalPassEchoTests {
    @Test func finalPassKeepsOnlyTheSystemCopy() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = FiggPaths(base: base)
        let store = try Store.inMemory()
        let meeting = Meeting()
        try store.save(meeting)
        let pending = paths.pendingDir(meeting.id)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        let speech = (0..<48_000).map { sin(Float($0) / 5) * 0.3 }
        try writeChunk(speech, to: pending.appendingPathComponent(AudioChunk.fileName(stream: .mic, offset: 0.05)))
        try writeChunk(speech, to: pending.appendingPathComponent(AudioChunk.fileName(stream: .system, offset: 0)))

        let queue = TranscriptionQueue(store: store, paths: paths, transcriber: EchoTranscriber(), keepAudio: { false }, onLines: { _ in })
        await queue.enqueuePending(meetingId: meeting.id)
        await queue.drain()
        #expect(try store.transcript(meetingId: meeting.id).count == 2)   // live lines still doubled

        try await queue.finalPass(meetingId: meeting.id)
        let lines = try store.transcript(meetingId: meeting.id)
        #expect(lines.map(\.displaySpeaker) == ["Them"])
        try? FileManager.default.removeItem(at: base)
    }
}
