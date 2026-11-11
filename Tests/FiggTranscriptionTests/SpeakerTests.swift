import FiggAudio
import FiggStore
@testable import FiggTranscription
import Foundation
import Testing

@Suite struct SpeakerLabelTests {
    let room = [
        SpeakerTurn(start: 0, end: 10, speaker: "A"),     // talks most: Me
        SpeakerTurn(start: 10, end: 14, speaker: "B"),
        SpeakerTurn(start: 14, end: 17, speaker: "C"),
        SpeakerTurn(start: 17, end: 18, speaker: "D"),    // 1 s: ignored as noise
    ]

    @Test func micSpeakersRankedByTalkTime() {
        #expect(SpeakerLabels.labels(for: room, stream: .mic) == ["A": "Me", "B": "Guest 1", "C": "Guest 2"])
    }

    @Test func systemSpeakersNumbered() {
        #expect(SpeakerLabels.labels(for: room, stream: .system) == ["A": "Them 1", "B": "Them 2", "C": "Them 3"])
    }

    @Test func singleSpeakerKeepsDefaults() {
        #expect(SpeakerLabels.labels(for: [SpeakerTurn(start: 0, end: 30, speaker: "A")], stream: .mic) == nil)
    }

    @Test func lineGetsMostOverlappingSpeaker() {
        let line = TranscriptLine(meetingId: "m", speaker: .me, start: 109, end: 113, text: "x")
        // offset 100: turns map to 100-110 (A) and 110-114 (B); B overlaps 3 s, A 1 s.
        #expect(SpeakerLabels.speaker(for: line, turns: room, offset: 100) == "B")
    }

    @Test func gapsSnapToNearbyTurnOnly() {
        let near = TranscriptLine(meetingId: "m", speaker: .me, start: 18.5, end: 19, text: "x")
        let far = TranscriptLine(meetingId: "m", speaker: .me, start: 30, end: 31, text: "x")
        #expect(SpeakerLabels.speaker(for: near, turns: room, offset: 0) == "D")
        #expect(SpeakerLabels.speaker(for: far, turns: room, offset: 0) == nil)
    }

    @Test func applyLabelsLines() {
        let lines = [
            TranscriptLine(meetingId: "m", speaker: .me, start: 1, end: 5, text: "hi"),
            TranscriptLine(meetingId: "m", speaker: .me, start: 11, end: 13, text: "hello"),
        ]
        let out = SpeakerLabels.apply(room, to: lines, stream: .mic, offset: 0)
        #expect(out.map(\.displaySpeaker) == ["Me", "Guest 1"])
    }
}

struct FakeSeparator: SpeakerSeparator {
    func turns(samples: [Float], speakerCount: Int?) async throws -> [SpeakerTurn] {
        [SpeakerTurn(start: 0, end: 0.4, speaker: "x"), SpeakerTurn(start: 0.4, end: 3, speaker: "y")]
    }
}

@Suite struct FinalPassSpeakerTests {
    @Test func finalPassLabelsSpeakersAndStoresThem() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = FiggPaths(base: base)
        let store = try Store.inMemory()
        let meeting = Meeting()
        try store.save(meeting)
        let pending = paths.pendingDir(meeting.id)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        try writeChunk((0..<48_000).map { sin(Float($0) / 5) * 0.3 }, to: pending.appendingPathComponent(AudioChunk.fileName(stream: .system, offset: 0)))

        // Two "speakers" of 0.4 s and 2.6 s: the short one is under the 2 s
        // noise floor, so only one real speaker remains and defaults stay.
        let queue = TranscriptionQueue(store: store, paths: paths, transcriber: CountingTranscriber(), separator: FakeSeparator(), keepAudio: { false }, onLines: { _ in })
        await queue.enqueuePending(meetingId: meeting.id)
        await queue.drain()
        try await queue.finalPass(meetingId: meeting.id)
        #expect(try store.transcript(meetingId: meeting.id).map(\.displaySpeaker) == ["Them"])
        try? FileManager.default.removeItem(at: base)
    }

    @Test func speakerLabelPersists() throws {
        let store = try Store.inMemory()
        let meeting = Meeting()
        try store.save(meeting)
        try store.append([TranscriptLine(meetingId: meeting.id, speaker: .them, start: 0, end: 1, text: "hi", speakerLabel: "Them 2")])
        #expect(try store.transcript(meetingId: meeting.id).first?.displaySpeaker == "Them 2")
    }
}

actor RecordingSeparator: SpeakerSeparator {
    var counts: [Int?] = []
    func turns(samples: [Float], speakerCount: Int?) async throws -> [SpeakerTurn] {
        counts.append(speakerCount)
        return []
    }
}

@Suite struct RoomSpeakerCountTests {
    @Test func roomCountGoesToMicOnlyAndOneSkipsDiarization() async throws {
        for (room, expected) in [(Int?.none, [Int?.none, nil]), (3, [3, nil]), (1, [nil])] {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let paths = FiggPaths(base: base)
            let store = try Store.inMemory()
            let meeting = Meeting()
            try store.save(meeting)
            let pending = paths.pendingDir(meeting.id)
            try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
            let speech = (0..<16_000).map { sin(Float($0) / 5) * 0.3 }
            try writeChunk(speech, to: pending.appendingPathComponent(AudioChunk.fileName(stream: .mic, offset: 0)))
            try writeChunk(speech, to: pending.appendingPathComponent(AudioChunk.fileName(stream: .system, offset: 0)))
            let sep = RecordingSeparator()
            let queue = TranscriptionQueue(store: store, paths: paths, transcriber: CountingTranscriber(), separator: sep, keepAudio: { false }, onLines: { _ in })
            await queue.enqueuePending(meetingId: meeting.id)
            await queue.drain()
            try await queue.finalPass(meetingId: meeting.id, roomSpeakers: room)
            #expect(await sep.counts == expected, "room \(String(describing: room))")
            try? FileManager.default.removeItem(at: base)
        }
    }
}
