import AVFoundation
import FiggAudio
import FiggStore
@testable import FiggTranscription
import FluidAudio
import Foundation
import Testing

struct FakeTranscriber: Transcriber {
    func transcribe(samples: [Float]) async throws -> [TranscriptSegment] {
        [TranscriptSegment(start: 1, end: 2, text: " hello there "), TranscriptSegment(start: 3, end: 4, text: "Thank you.")]
    }
}

func writeChunk(_ samples: [Float], to url: URL) throws {
    let buffer = AVAudioPCMBuffer(pcmFormat: AudioChunk.format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    for (i, s) in samples.enumerated() { buffer.floatChannelData![0][i] = s }
    let file = try AVAudioFile(forWriting: url, settings: AudioChunk.format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: buffer)
}

@Suite struct TranscriptionTests {
    @Test func silenceGate() {
        #expect(SilenceGate.isSilent([Float](repeating: 0.001, count: 1000)))
        #expect(!SilenceGate.isSilent((0..<1000).map { sin(Float($0) / 5) * 0.3 }))
    }

    @Test func cleanerDropsTagsAndHallucinations() {
        #expect(TranscriptCleaner.clean("<|en|> Hi team") == "Hi team")
        #expect(TranscriptCleaner.clean("[Music]") == nil)
        #expect(TranscriptCleaner.clean(" Thank you. ") == nil)
        #expect(TranscriptCleaner.clean("Thank you for the update") == "Thank you for the update")
    }

    @Test func silenceWatchWarnsOnceAfterSilentRun() {
        var watch = SilenceWatch(chunksBeforeWarning: 3)
        // Sound resets the run; the warning fires once.
        let peaks: [Float] = [0, 0, 0.2, 0, 0, 0, 0]
        let fired = peaks.map { watch.record(peak: $0) }
        #expect(fired == [false, false, false, false, false, true, false])
    }

    @Test func readsWholeFileNotJustFirst1024Multiple() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).caf")
        try writeChunk([Float](repeating: 0.1, count: 16_000), to: url)
        #expect(try AudioChunk.readMono(url).count == 16_000)
        try? FileManager.default.removeItem(at: url)
    }

    @Test func chunkNamesRoundTrip() {
        let name = AudioChunk.fileName(stream: .system, offset: 12.345)
        let chunk = AudioChunk(url: URL(fileURLWithPath: "/tmp/\(name)"))
        #expect(chunk?.stream == .system)
        #expect(chunk?.offset == 12.345)
        #expect(AudioChunk(url: URL(fileURLWithPath: "/tmp/\(name).partial")) == nil)
    }

    @Test func queueStoresOffsetLabelledLinesAndRemovesAudio() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = FiggPaths(base: base)
        let store = try Store.inMemory()
        let meeting = Meeting()
        try store.save(meeting)
        let pending = paths.pendingDir(meeting.id)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)

        let speech = (0..<16_000).map { sin(Float($0) / 5) * 0.3 }
        try writeChunk(speech, to: pending.appendingPathComponent(AudioChunk.fileName(stream: .system, offset: 20)))
        try writeChunk([Float](repeating: 0, count: 16_000), to: pending.appendingPathComponent(AudioChunk.fileName(stream: .mic, offset: 30)))

        let queue = TranscriptionQueue(store: store, paths: paths, transcriber: FakeTranscriber(), keepAudio: { false }, onLines: { _ in })
        await queue.enqueuePending(meetingId: meeting.id)
        await queue.drain()

        let lines = try store.transcript(meetingId: meeting.id)
        #expect(lines.count == 1)                    // silent mic chunk skipped, "Thank you." dropped
        #expect(lines[0].speaker == .them)
        #expect(lines[0].start == 21)
        #expect(lines[0].text == "hello there")
        #expect(AudioChunk.list(in: pending).isEmpty)
        try? FileManager.default.removeItem(at: base)
    }

    /// Word error rate against recorded fixtures. Needs the Whisper model
    /// download, so it only runs with FIGG_WER=1. Put `name.wav` + `name.txt`
    /// pairs in Fixtures/.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FIGG_WER"] == "1"))
    func wordErrorRate() async throws {
        let dir = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
        let wavs = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "wav" }
        try #require(!wavs.isEmpty, "No WAV fixtures recorded yet")
        let whisper = WhisperKitTranscriber()
        for wav in wavs {
            let expected = try String(contentsOf: wav.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)
            let samples = try AudioChunk.readMono(wav)
            let got = try await whisper.transcribe(samples: samples).map(\.text).joined(separator: " ")
            let wer = WER.compute(reference: expected, hypothesis: got)
            #expect(wer < 0.15, "\(wav.lastPathComponent) WER \(wer)")
        }
    }
}

/// Returns one segment per call; counts calls so tests can see the final pass ran.
actor CountingTranscriber: Transcriber {
    var calls: [Int] = []
    func transcribe(samples: [Float]) async throws -> [TranscriptSegment] {
        calls.append(samples.count)
        return [TranscriptSegment(start: 0.5, end: 1, text: samples.count > 16_000 ? "full pass" : "live chunk")]
    }
}

@Suite struct FinalPassTests {
    func setUp(keepAudio: Bool) throws -> (Store, FiggPaths, Meeting, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = FiggPaths(base: base)
        let store = try Store.inMemory()
        let meeting = Meeting()
        try store.save(meeting)
        let pending = paths.pendingDir(meeting.id)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        let speech = (0..<16_000).map { sin(Float($0) / 5) * 0.3 }
        try writeChunk(speech, to: pending.appendingPathComponent(AudioChunk.fileName(stream: .system, offset: 5)))
        try writeChunk(speech, to: pending.appendingPathComponent(AudioChunk.fileName(stream: .system, offset: 6)))
        return (store, paths, meeting, base)
    }

    @Test func replacesLiveLinesWithOneFullPassPerStream() async throws {
        let (store, paths, meeting, base) = try setUp(keepAudio: false)
        let engine = CountingTranscriber()
        let queue = TranscriptionQueue(store: store, paths: paths, transcriber: engine, keepAudio: { false }, onLines: { _ in })
        await queue.enqueuePending(meetingId: meeting.id)
        await queue.drain()
        #expect(try store.transcript(meetingId: meeting.id).map(\.text) == ["live chunk", "live chunk"])

        try await queue.finalPass(meetingId: meeting.id)
        let lines = try store.transcript(meetingId: meeting.id)
        #expect(lines.map(\.text) == ["full pass"])
        #expect(lines[0].start == 5.5)             // offset of the stream's first chunk
        let calls = await engine.calls
        #expect(calls == [16_000, 16_000, 32_000])
        #expect(!FileManager.default.fileExists(atPath: paths.doneDir(meeting.id).path))  // audio deleted

        try await queue.finalPass(meetingId: meeting.id)   // second call is a no-op
        #expect(await engine.calls.count == 3)
        try? FileManager.default.removeItem(at: base)
    }

    @Test func keepsAudioWhenAsked() async throws {
        let (store, paths, meeting, base) = try setUp(keepAudio: true)
        let queue = TranscriptionQueue(store: store, paths: paths, transcriber: CountingTranscriber(), keepAudio: { true }, onLines: { _ in })
        await queue.enqueuePending(meetingId: meeting.id)
        await queue.drain()
        try await queue.finalPass(meetingId: meeting.id)
        #expect(AudioChunk.list(in: paths.doneDir(meeting.id)).count == 2)
        try? FileManager.default.removeItem(at: base)
    }
}

@Suite struct ParakeetSegmentTests {
    @Test func splitsTokensIntoSentences() {
        func t(_ s: String, _ a: Double, _ b: Double) -> TokenTiming {
            TokenTiming(token: s, tokenId: 0, startTime: a, endTime: b, confidence: 1)
        }
        let timings = [t("▁Hello", 0.1, 0.4), t("▁team", 0.4, 0.7), t(".", 0.7, 0.8),
                       t("▁Ship", 1.2, 1.5), t("▁it", 1.5, 1.7), t("?", 1.7, 1.8), t("▁ok", 2.0, 2.2)]
        let segs = ParakeetTranscriber.segments(text: "Hello team. Ship it? ok", timings: timings, duration: 3)
        #expect(segs.map(\.text) == ["Hello team.", "Ship it?", "ok"])
        #expect(segs[1].start == 1.2 && segs[1].end == 1.8)
    }

    @Test func fallsBackToWholeTextWithoutTimings() {
        let segs = ParakeetTranscriber.segments(text: " hi ", timings: [], duration: 4)
        #expect(segs == [TranscriptSegment(start: 0, end: 4, text: "hi")])
    }
}
