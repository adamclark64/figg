import AVFoundation
@testable import FiggAudio
import Foundation
import Testing

/// A clock the test moves by hand.
final class TestClock: @unchecked Sendable {
    var time: Date
    init(_ time: Date) { self.time = time }
}

@Suite struct ChunkWriterTests {
    func buffer(seconds: Double) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(seconds * AudioChunk.sampleRate)
        let b = AVAudioPCMBuffer(pcmFormat: AudioChunk.format, frameCapacity: frames)!
        b.frameLength = frames
        for i in 0..<Int(frames) { b.floatChannelData![0][i] = 0.1 }
        return b
    }

    @Test func stampsTheStreamFromItsFirstBuffer() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let started = Date(timeIntervalSince1970: 1_000)
        let clock = TestClock(started)
        let chunks = Chunks()
        let writer = ChunkWriter(stream: .system, dir: dir, chunkSeconds: 1, recordingStarted: started,
                                 now: { clock.time }, onChunk: { chunks.add($0) })

        // The tap delivers nothing for 2.5 s; its first 0.5 s buffer lands at 3 s.
        clock.time = started.addingTimeInterval(3)
        writer.append(buffer(seconds: 0.5))
        // Later buffers do not move the start.
        clock.time = started.addingTimeInterval(10)
        writer.append(buffer(seconds: 0.5))
        writer.append(buffer(seconds: 0.5))
        writer.flush()

        let offsets = chunks.all.map(\.offset)
        #expect(offsets.count == 2)
        #expect(abs(offsets[0] - 2.5) < 0.002)
        #expect(abs(offsets[1] - 3.5) < 0.002)
    }

    @Test func neverStampsBeforeTheRecordingStarted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let started = Date(timeIntervalSince1970: 1_000)
        let chunks = Chunks()
        // A first buffer longer than the time since Start.
        let writer = ChunkWriter(stream: .mic, dir: dir, chunkSeconds: 1, recordingStarted: started,
                                 now: { started.addingTimeInterval(0.1) }, onChunk: { chunks.add($0) })
        writer.append(buffer(seconds: 0.5))
        writer.flush()
        #expect(chunks.all.map(\.offset) == [0])
    }
}

final class Chunks: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [AudioChunk] = []
    func add(_ chunk: AudioChunk) { lock.lock(); chunks.append(chunk); lock.unlock() }
    var all: [AudioChunk] { lock.lock(); defer { lock.unlock() }; return chunks }
}
