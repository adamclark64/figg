import FiggAudio
import FiggStore
@testable import FiggTranscription
import Foundation
import Testing

/// Speech-like test audio: bursts of noise (syllables) of varying loudness
/// with pauses between them, the same every run for a given seed.
func babble(seconds: Double, seed: UInt64, level: Float = 0.2) -> [Float] {
    var state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    func random() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(state >> 40) / Float(1 << 24)
    }
    let count = Int(seconds * 16_000)
    var out = [Float](repeating: 0, count: count)
    var i = 0
    while i < count {
        let on = Int((0.08 + 0.22 * random()) * 16_000)
        let loudness = level * (0.3 + 0.7 * random())
        for j in i..<min(count, i + on) { out[j] = (random() * 2 - 1) * loudness }
        i += on + Int((0.05 + 0.35 * random()) * 16_000)
    }
    return out
}

/// `signal` as the mic hears it from the speakers: `delay` samples later
/// (earlier when negative) and scaled by `gain`.
func heard(_ signal: [Float], delay: Int, gain: Float) -> [Float] {
    var out = [Float](repeating: 0, count: signal.count)
    for i in signal.indices where i + delay >= 0 && i + delay < signal.count {
        out[i + delay] = signal[i] * gain
    }
    return out
}

func mix(_ a: [Float], _ b: [Float]) -> [Float] { zip(a, b).map { $0 + $1 } }

/// Silence outside `range` (seconds), for people taking turns.
func only(_ signal: [Float], _ range: Range<Double>) -> [Float] {
    signal.enumerated().map { i, s in range.contains(Double(i) / 16_000) ? s : 0 }
}

@Suite struct EchoDetectorTests {
    let frame = EchoDetector.delayFrame

    @Test func findsTheSpeakerDelay() throws {
        let call = babble(seconds: 20, seed: 1)
        let mic = mix(heard(call, delay: 640, gain: 0.4), babble(seconds: 20, seed: 9, level: 0.002))
        let delay = try #require(EchoDetector.estimateDelay(mic: mic, reference: call))
        #expect(abs(delay.samples - 640) <= frame)
        #expect(delay.confidence > 0.8)
    }

    @Test func findsAnEchoThatComesBeforeItsReference() throws {
        // The real call: stream offsets put the mic's copy 56 ms early.
        let call = babble(seconds: 20, seed: 2)
        let delay = try #require(EchoDetector.estimateDelay(mic: heard(call, delay: -896, gain: 1.4), reference: call))
        #expect(abs(delay.samples + 896) <= frame)
    }

    @Test func findsTheDelayWhilePeopleTakeTurns() throws {
        // A quiet echo while they talk, then a loud voice in the room while
        // the call is silent: the mic is loudest when the call is quiet.
        let call = only(babble(seconds: 30, seed: 3), 0..<15)
        let room = only(babble(seconds: 30, seed: 4, level: 0.4), 15..<30)
        let delay = try #require(EchoDetector.estimateDelay(mic: mix(heard(call, delay: 640, gain: 0.3), room), reference: call))
        #expect(abs(delay.samples - 640) <= frame)
    }

    @Test func findsNoDelayForUnrelatedSound() {
        // Headphones: the mic hears only the room.
        let call = babble(seconds: 20, seed: 5)
        #expect(EchoDetector.estimateDelay(mic: babble(seconds: 20, seed: 6), reference: call) == nil)
        #expect(EchoDetector.estimateDelay(mic: call, reference: [Float](repeating: 0, count: call.count)) == nil)
        #expect(EchoDetector.estimateDelay(mic: [0.1, 0.2], reference: [0.1, 0.2]) == nil)
    }

    @Test func marksEchoAndRoomSpeech() throws {
        let call = only(babble(seconds: 20, seed: 7), 0..<10)
        let room = only(babble(seconds: 20, seed: 8, level: 0.3), 10..<20)
        let map = EchoDetector.map(mic: mix(heard(call, delay: 640, gain: 0.4), room), reference: call, offset: 100)
        #expect(map.delay != nil)
        #expect(try #require(map.echoShare(start: 101, end: 109)) > 0.9)
        #expect(try #require(map.echoShare(start: 111, end: 119)) < 0.05)
        #expect(map.isEcho(start: 101, end: 109))
        #expect(!map.isEcho(start: 111, end: 119))
    }

    @Test func talkingOverTheCallIsSpeech() throws {
        let call = babble(seconds: 20, seed: 10)
        let room = only(babble(seconds: 20, seed: 11, level: 0.3), 8..<12)
        let map = EchoDetector.map(mic: mix(heard(call, delay: 640, gain: 0.4), room), reference: call, offset: 0)
        // Frames in the gaps between their words are still echo, but the
        // line as a whole is theirs.
        let share = try #require(map.echoShare(start: 8.5, end: 11.5))
        #expect(share < EchoDetector.echoLineShare)
        #expect(!map.isEcho(start: 8.5, end: 11.5))
        #expect(map.isEcho(start: 2, end: 6))
    }

    @Test func withoutEchoEverySoundIsSpeech() {
        let call = babble(seconds: 20, seed: 12)
        let map = EchoDetector.map(mic: babble(seconds: 20, seed: 13), reference: call, offset: 0)
        #expect(map.delay == nil)
        #expect(!map.frames.contains(.echo))
        #expect(map.frames.contains(.speech))
    }

    @Test func usesAKnownDelay() {
        let call = babble(seconds: 20, seed: 14)
        let known = EchoDetector.Delay(samples: 640, confidence: 1)
        let map = EchoDetector.map(mic: heard(call, delay: 640, gain: 0.4), reference: call, offset: 0, delay: known)
        #expect(map.delay == known)
    }

    @Test func quietSpanHasNoShare() {
        let map = EchoDetector.Map(offset: 10, frames: [.quiet, .quiet, .echo, .speech], delay: nil)
        #expect(map.echoShare(start: 10, end: 10.04) == nil)
        #expect(map.echoShare(start: 10, end: 10.08) == 0.5)
        #expect(map.echoShare(start: 0, end: 5) == nil)      // before the map
        #expect(!map.isEcho(start: 10, end: 10.04))
    }

    @Test func shiftPutsTheReferenceJustAheadOfTheEcho() {
        var reference = [Float](repeating: 0, count: 6_000)
        reference[3_000] = 1
        // Echo 640 samples after the reference: move it 640 - lead later.
        let later = EchoDetector.shift(reference, for: .init(samples: 640, confidence: 1))
        #expect(later.firstIndex(of: 1) == 3_000 + 640 - EchoDetector.referenceLead)
        // Echo 896 samples before it: move it 896 + lead earlier.
        let earlier = EchoDetector.shift(reference, for: .init(samples: -896, confidence: 1))
        #expect(earlier.firstIndex(of: 1) == 3_000 - 896 - EchoDetector.referenceLead)
        #expect(earlier.count == reference.count)
        // Shifted off the end entirely.
        #expect(EchoDetector.shift(reference, for: .init(samples: 10_000, confidence: 1)).allSatisfy { $0 == 0 })
    }
}

@Suite struct EchoFilterSoundTests {
    func line(_ speaker: Speaker, _ start: Double, _ end: Double, _ text: String) -> TranscriptLine {
        TranscriptLine(meetingId: "m", speaker: speaker, start: start, end: end, text: text)
    }

    /// 0 to 2 s echo, 2 to 4 s room speech.
    let map = EchoDetector.Map(
        offset: 0,
        frames: [EchoDetector.Frame](repeating: .echo, count: 100) + [EchoDetector.Frame](repeating: .speech, count: 100),
        delay: .init(samples: 640, confidence: 0.9))

    @Test func dropsEchoTheWordsMissed() {
        let lines = [
            line(.them, 0, 2, "We'll ship it Friday."),
            line(.me, 0.1, 1.9, "Shipping Friday."),
            line(.me, 2.1, 3.9, "Friday is too early."),
        ]
        #expect(EchoFilter.removeEchoes(from: lines).count == 3)
        #expect(EchoFilter.removeEchoes(from: lines, echo: map).map(\.text) == ["We'll ship it Friday.", "Friday is too early."])
    }

    @Test func dropsEchoEvenWithoutSystemLines() {
        let lines = [line(.me, 0.1, 1.9, "mumble")]
        #expect(EchoFilter.removeEchoes(from: lines, echo: map).isEmpty)
    }
}

@Suite struct LiveEchoTests {
    /// A meeting whose pending/ holds a 10 s mic chunk and the system chunk
    /// recorded with it.
    func setUp(mic: [Float], system: [Float]) throws -> (Store, FiggPaths, Meeting, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = FiggPaths(base: base)
        let store = try Store.inMemory()
        let meeting = Meeting()
        try store.save(meeting)
        let pending = paths.pendingDir(meeting.id)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        try writeChunk(mic, to: pending.appendingPathComponent(AudioChunk.fileName(stream: .mic, offset: 0)))
        try writeChunk(system, to: pending.appendingPathComponent(AudioChunk.fileName(stream: .system, offset: 0.1)))
        return (store, paths, meeting, base)
    }

    func run(mic: [Float], system: [Float], on: Bool = true) async throws -> [TranscriptLine] {
        let (store, paths, meeting, base) = try setUp(mic: mic, system: system)
        defer { try? FileManager.default.removeItem(at: base) }
        let queue = TranscriptionQueue(store: store, paths: paths, transcriber: FakeTranscriber(), cancelEcho: { on }, keepAudio: { false }, onLines: { _ in })
        await queue.enqueuePending(meetingId: meeting.id)
        await queue.drain()
        return try store.transcript(meetingId: meeting.id)
    }

    @Test func dropsLiveMicLinesThatAreTheCall() async throws {
        let call = babble(seconds: 10, seed: 20)
        let lines = try await run(mic: heard(call, delay: -960, gain: 1.2), system: call)
        #expect(lines.map(\.speaker) == [.them])
    }

    @Test func keepsLiveMicLinesFromTheRoom() async throws {
        let lines = try await run(mic: babble(seconds: 10, seed: 21), system: babble(seconds: 10, seed: 22))
        #expect(lines.map(\.speaker).sorted { $0.rawValue < $1.rawValue } == [.me, .them])
    }

    @Test func waitsForTheSystemChunkWrittenJustAfter() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let paths = FiggPaths(base: base)
        let store = try Store.inMemory()
        let meeting = Meeting()
        try store.save(meeting)
        let pending = paths.pendingDir(meeting.id)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        let call = babble(seconds: 10, seed: 24)
        let micURL = pending.appendingPathComponent(AudioChunk.fileName(stream: .mic, offset: 0))
        try writeChunk(heard(call, delay: -960, gain: 1.2), to: micURL)

        let queue = TranscriptionQueue(store: store, paths: paths, transcriber: FakeTranscriber(), keepAudio: { false }, onLines: { _ in })
        await queue.enqueue(AudioChunk(url: micURL, stream: .mic, offset: 0), meetingId: meeting.id)
        // The recorder writes the system chunk a moment later.
        try await Task.sleep(for: .milliseconds(300))
        try writeChunk(call, to: pending.appendingPathComponent(AudioChunk.fileName(stream: .system, offset: 0.1)))
        await queue.drain()
        #expect(try store.transcript(meetingId: meeting.id).isEmpty)
    }

    /// A mic chunk at 0 s queued now, and the system chunk from `systemOffset`
    /// written `after` later. FakeTranscriber's one kept line is at 1 to 2 s.
    func runLate(systemOffset: Double, after: Duration) async throws -> [TranscriptLine] {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let paths = FiggPaths(base: base)
        let store = try Store.inMemory()
        let meeting = Meeting()
        try store.save(meeting)
        let pending = paths.pendingDir(meeting.id)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        let call = babble(seconds: 13, seed: 25)
        let micURL = pending.appendingPathComponent(AudioChunk.fileName(stream: .mic, offset: 0))
        try writeChunk(Array(heard(call, delay: 0, gain: 1.2).prefix(160_000)), to: micURL)

        let queue = TranscriptionQueue(store: store, paths: paths, transcriber: FakeTranscriber(), keepAudio: { false }, onLines: { _ in })
        await queue.enqueue(AudioChunk(url: micURL, stream: .mic, offset: 0), meetingId: meeting.id)
        try await Task.sleep(for: after)
        let skip = Int(systemOffset * 16_000)
        try writeChunk(Array(call[skip..<(skip + 160_000)]), to: pending.appendingPathComponent(AudioChunk.fileName(stream: .system, offset: systemOffset)))
        await queue.drain()
        return try store.transcript(meetingId: meeting.id)
    }

    @Test func waitsSecondsForASystemStreamThatStartedLate() async throws {
        // The system tap started 0.5 s after the mic, so its chunk finishes
        // 2.5 s after the mic's (as on a real call).
        #expect(try await runLate(systemOffset: 0.5, after: .milliseconds(2_500)).isEmpty)
    }

    @Test func doesNotJudgeMicAudioTheSystemDoesNotCover() async throws {
        // System audio only from 2.4 s: the line at 1 to 2 s has nothing to
        // compare with, so it stays (the final pass decides after Stop).
        let lines = try await runLate(systemOffset: 2.4, after: .milliseconds(100))
        #expect(lines.map(\.speaker) == [.me])
    }

    @Test func settingOffKeepsLiveEcho() async throws {
        let call = babble(seconds: 10, seed: 23)
        let lines = try await run(mic: heard(call, delay: -960, gain: 1.2), system: call, on: false)
        #expect(lines.count == 2)
    }
}

@Suite struct FinalPassAlignmentTests {
    @Test func referenceIsMovedAheadOfTheEcho() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let paths = FiggPaths(base: base)
        let store = try Store.inMemory()
        let meeting = Meeting()
        try store.save(meeting)
        let done = paths.doneDir(meeting.id)
        try FileManager.default.createDirectory(at: done, withIntermediateDirectories: true)
        let call = babble(seconds: 20, seed: 30)
        let mic = heard(call, delay: -896, gain: 1.4)
        try writeChunk(call, to: done.appendingPathComponent(AudioChunk.fileName(stream: .system, offset: 0)))
        try writeChunk(mic, to: done.appendingPathComponent(AudioChunk.fileName(stream: .mic, offset: 0)))

        let canceller = FakeEchoCanceller(gain: 0)
        let queue = TranscriptionQueue(store: store, paths: paths, transcriber: CountingTranscriber(), echoCanceller: canceller, keepAudio: { false }, onLines: { _ in })
        try await queue.finalPass(meetingId: meeting.id)

        let calls = await canceller.calls
        #expect(calls.count == 1)
        let delay = try #require(EchoDetector.estimateDelay(mic: mic, reference: call))
        #expect(calls[0].reference == EchoDetector.shift(call, for: delay))
        // The reference now leads the echo: its loudest moment comes first.
        let micPeak = mic.indices.max { abs(mic[$0]) < abs(mic[$1]) }!
        let refPeak = calls[0].reference.indices.max { abs(calls[0].reference[$0]) < abs(calls[0].reference[$1]) }!
        #expect(refPeak < micPeak)
    }
}
