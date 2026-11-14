import AVFoundation
import Foundation

/// Which streams actually started, and why any did not.
public struct RecordingStart: Sendable {
    public var mic: Bool
    public var system: Bool
    public var problems: [String]

    public var anyStarted: Bool { mic || system }
}

/// Records the mic and system audio as two independent streams into chunk
/// files under `dir`. Mic speech is labelled "Me", system audio "Them".
public final class Recorder: @unchecked Sendable {
    public let dir: URL
    private let chunkSeconds: Double
    private let onChunk: @Sendable (AudioChunk) -> Void

    private var mic: MicCapture?
    private var system: AnyObject?
    private var writers: [AudioStream: ChunkWriter] = [:]
    private var startedAt = Date()
    /// Live per-stream loudness for the recording strip's waveform.
    public let levels = LevelMeter()

    public init(dir: URL, chunkSeconds: Double = 10, onChunk: @escaping @Sendable (AudioChunk) -> Void) {
        self.dir = dir
        self.chunkSeconds = chunkSeconds
        self.onChunk = onChunk
    }

    public var elapsed: TimeInterval { Date().timeIntervalSince(startedAt) }

    public func start() async -> RecordingStart {
        var result = RecordingStart(mic: false, system: false, problems: [])
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            result.problems.append("Could not create the recording folder: \(error.localizedDescription)")
            return result
        }
        startedAt = Date()

        if await MicCapture.requestPermission() {
            let writer = makeWriter(.mic)
            let capture = MicCapture()
            do {
                try capture.start { writer.append($0) }
                mic = capture
                writers[.mic] = writer
                levels.activate(.mic)
                result.mic = true
            } catch {
                result.problems.append("Microphone: \(error.localizedDescription)")
            }
        } else {
            result.problems.append("Microphone access is off. Turn it on in System Settings > Privacy & Security > Microphone.")
        }

        if #available(macOS 14.2, *) {
            let writer = makeWriter(.system)
            let capture = SystemAudioCapture()
            do {
                try capture.start { writer.append($0) }
                system = capture
                writers[.system] = writer
                levels.activate(.system)
                result.system = true
            } catch {
                result.problems.append("System audio: \(error.localizedDescription) Check System Settings > Privacy & Security > Screen & System Audio Recording.")
            }
        } else {
            result.problems.append(AudioCaptureError.unsupportedOS.localizedDescription)
        }
        for problem in result.problems { NSLog("figg recorder: %@", problem) }
        return result
    }

    /// Stops capture and writes the final partial chunks.
    public func stop() {
        mic?.stop()
        if #available(macOS 14.2, *) { (system as? SystemAudioCapture)?.stop() }
        mic = nil
        system = nil
        for writer in writers.values { writer.flush() }
        writers.removeAll()
    }

    private func makeWriter(_ stream: AudioStream) -> ChunkWriter {
        ChunkWriter(
            stream: stream,
            dir: dir,
            chunkSeconds: chunkSeconds,
            streamStartOffset: Date().timeIntervalSince(startedAt),
            levels: levels,
            onChunk: onChunk)
    }
}
