import FiggAudio
import FiggStore
@testable import FiggTranscription
import Foundation
import Testing

/// Records what it was given and returns the mic scaled by `gain`
/// (0 = all of it was echo). Throws when `fails` is set.
actor FakeEchoCanceller: EchoCanceller {
    var calls: [(mic: [Float], reference: [Float])] = []
    let gain: Float
    let fails: Bool

    init(gain: Float = 0, fails: Bool = false) {
        self.gain = gain
        self.fails = fails
    }

    struct Failure: Error {}

    func cancel(mic: [Float], reference: [Float]) async throws -> [Float] {
        calls.append((mic, reference))
        if fails { throw Failure() }
        return mic.map { $0 * gain }
    }
}

@Suite struct StreamAudioTests {
    let rate = StreamAudio.sampleRate

    func chunk(_ stream: AudioStream, _ offset: Double) -> AudioChunk {
        AudioChunk(url: URL(fileURLWithPath: "/x/\(AudioChunk.fileName(stream: stream, offset: offset))"), stream: stream, offset: offset)
    }

    @Test func joinsBackToBackChunksWithoutGaps() throws {
        // 1 s chunks whose rounded offsets are a few samples off.
        let chunks = [chunk(.mic, 2), chunk(.mic, 3.0004), chunk(.mic, 3.9998)]
        let audio = try #require(try StreamAudio.assemble(chunks) { _ in [Float](repeating: 0.1, count: rate) })
        #expect(audio.offset == 2)
        #expect(audio.samples.count == 3 * rate)
        #expect(audio.hasSpeech)
    }

    @Test func keepsAMissingChunkAsSilence() throws {
        // The chunk at 1 s never reached done/: later audio stays at 2 s.
        let chunks = [chunk(.mic, 0), chunk(.mic, 2)]
        let audio = try #require(try StreamAudio.assemble(chunks) { _ in [Float](repeating: 0.1, count: rate) })
        #expect(audio.samples.count == 3 * rate)
        #expect(audio.samples[rate..<2 * rate].allSatisfy { $0 == 0 })
        #expect(audio.samples[2 * rate] == 0.1)
    }

    @Test func silentStreamHasNoSpeech() throws {
        let audio = try #require(try StreamAudio.assemble([chunk(.system, 0)]) { _ in [Float](repeating: 0, count: rate) })
        #expect(!audio.hasSpeech)
        #expect(try StreamAudio.assemble([]) == nil)
    }

    @Test func alignsAStreamThatStartedEarlier() {
        // System started at 1.0 s, mic at 1.5 s: mic sample 0 is system sample 0.5 s in.
        let system = StreamAudio(offset: 1, samples: (0..<(2 * rate)).map(Float.init), hasSpeech: true)
        let mic = StreamAudio(offset: 1.5, samples: [Float](repeating: 0, count: 2 * rate), hasSpeech: true)
        let ref = system.aligned(to: mic)
        #expect(ref.count == mic.samples.count)
        #expect(ref[0] == Float(rate / 2))
        #expect(ref[rate + rate / 2 - 1] == Float(2 * rate - 1))   // last system sample
        #expect(ref[(rate + rate / 2)...].allSatisfy { $0 == 0 })  // system had ended
    }

    @Test func alignsAStreamThatStartedLater() {
        let system = StreamAudio(offset: 2, samples: [Float](repeating: 1, count: rate), hasSpeech: true)
        let mic = StreamAudio(offset: 1, samples: [Float](repeating: 0, count: 3 * rate), hasSpeech: true)
        let ref = system.aligned(to: mic)
        #expect(ref[..<rate].allSatisfy { $0 == 0 })
        #expect(ref[rate..<(2 * rate)].allSatisfy { $0 == 1 })
        #expect(ref[(2 * rate)...].allSatisfy { $0 == 0 })
    }

    @Test func alignsStreamsThatDoNotOverlap() {
        let system = StreamAudio(offset: 10, samples: [1, 1, 1], hasSpeech: true)
        let mic = StreamAudio(offset: 0, samples: [0, 0], hasSpeech: true)
        #expect(system.aligned(to: mic) == [0, 0])
    }

    @Test func findsSpeechInAnyWindow() {
        var s = [Float](repeating: 0, count: 25 * rate)
        #expect(!StreamAudio.hasSpeech(s))
        for i in (21 * rate)..<(22 * rate) { s[i] = 0.5 }
        #expect(StreamAudio.hasSpeech(s))
    }
}

@Suite struct EchoCancellationTests {
    /// A meeting with one second of speech on both streams, already moved to done/.
    func setUp() throws -> (Store, FiggPaths, Meeting, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = FiggPaths(base: base)
        let store = try Store.inMemory()
        let meeting = Meeting()
        try store.save(meeting)
        let done = paths.doneDir(meeting.id)
        try FileManager.default.createDirectory(at: done, withIntermediateDirectories: true)
        let speech = (0..<16_000).map { sin(Float($0) / 5) * 0.3 }
        try writeChunk(speech, to: done.appendingPathComponent(AudioChunk.fileName(stream: .system, offset: 0)))
        try writeChunk(speech.map { $0 * 0.5 }, to: done.appendingPathComponent(AudioChunk.fileName(stream: .mic, offset: 0.25)))
        return (store, paths, meeting, base)
    }

    func queue(_ store: Store, _ paths: FiggPaths, _ engine: CountingTranscriber, _ canceller: EchoCanceller?, on: Bool = true) -> TranscriptionQueue {
        TranscriptionQueue(store: store, paths: paths, transcriber: engine, echoCanceller: canceller, cancelEcho: { on }, keepAudio: { false }, onLines: { _ in })
    }

    @Test func micThatOnlyHeardTheCallIsNotTranscribed() async throws {
        let (store, paths, meeting, base) = try setUp()
        defer { try? FileManager.default.removeItem(at: base) }
        let engine = CountingTranscriber()
        let canceller = FakeEchoCanceller(gain: 0)
        try await queue(store, paths, engine, canceller).finalPass(meetingId: meeting.id)

        let calls = await canceller.calls
        #expect(calls.count == 1)
        // The reference is the system audio shifted onto the mic's timeline.
        #expect(calls[0].reference.count == calls[0].mic.count)
        #expect(abs(calls[0].reference[0] - sin(Float(4_000) / 5) * 0.3) < 1e-6)
        #expect(await engine.calls.count == 1)   // system only
        #expect(try store.transcript(meetingId: meeting.id).map(\.speaker) == [.them])
    }

    @Test func cleanedMicIsTranscribed() async throws {
        let (store, paths, meeting, base) = try setUp()
        defer { try? FileManager.default.removeItem(at: base) }
        let engine = CountingTranscriber()
        try await queue(store, paths, engine, FakeEchoCanceller(gain: 1)).finalPass(meetingId: meeting.id)
        #expect(await engine.calls.count == 2)
    }

    @Test func settingOffSkipsCancellation() async throws {
        let (store, paths, meeting, base) = try setUp()
        defer { try? FileManager.default.removeItem(at: base) }
        let canceller = FakeEchoCanceller(gain: 0)
        let engine = CountingTranscriber()
        try await queue(store, paths, engine, canceller, on: false).finalPass(meetingId: meeting.id)
        #expect(await canceller.calls.isEmpty)
        #expect(await engine.calls.count == 2)
    }

    @Test func failureFallsBackToTheRawMic() async throws {
        let (store, paths, meeting, base) = try setUp()
        defer { try? FileManager.default.removeItem(at: base) }
        let engine = CountingTranscriber()
        try await queue(store, paths, engine, FakeEchoCanceller(fails: true)).finalPass(meetingId: meeting.id)
        #expect(await engine.calls.count == 2)
        #expect(FileManager.default.fileExists(atPath: paths.meetingDir(meeting.id).appendingPathComponent("final-pass.done").path))
    }

    @Test func noCallAudioMeansNothingToCancel() async throws {
        let (store, paths, meeting, base) = try setUp()
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.removeItem(at: paths.doneDir(meeting.id).appendingPathComponent(AudioChunk.fileName(stream: .system, offset: 0)))
        let canceller = FakeEchoCanceller(gain: 0)
        try await queue(store, paths, CountingTranscriber(), canceller).finalPass(meetingId: meeting.id)
        #expect(await canceller.calls.isEmpty)
    }
}
