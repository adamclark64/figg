import AVFoundation
import Foundation

/// Converts incoming buffers of any format to 16 kHz mono and writes a chunk
/// file every `chunkSeconds`. Files are written under a temporary name and
/// renamed when complete, so readers never see a half-written chunk.
///
/// Chunk names carry their meeting time, which the final pass uses to line
/// the mic up with the system audio. The stream's start is taken from its
/// first buffer, not from when capture was asked to start: the system
/// audio tap once took 2.5 s to deliver anything, and stamping its chunks
/// from the request put every one of them 2.5 s early.
final class ChunkWriter: @unchecked Sendable {
    let stream: AudioStream
    private let dir: URL
    private let chunkFrames: Int
    private let recordingStarted: Date
    private let now: @Sendable () -> Date
    /// Meeting time of the stream's first sample; set by the first buffer.
    private var streamStartOffset: Double?
    private let onChunk: @Sendable (AudioChunk) -> Void
    private let levels: LevelMeter?
    private let queue: DispatchQueue

    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private var pending: [Float] = []
    private var framesWritten = 0

    init(
        stream: AudioStream,
        dir: URL,
        chunkSeconds: Double,
        recordingStarted: Date,
        now: @escaping @Sendable () -> Date = { Date() },
        levels: LevelMeter? = nil,
        onChunk: @escaping @Sendable (AudioChunk) -> Void
    ) {
        self.stream = stream
        self.dir = dir
        self.chunkFrames = Int(chunkSeconds * AudioChunk.sampleRate)
        self.recordingStarted = recordingStarted
        self.now = now
        self.onChunk = onChunk
        self.levels = levels
        self.queue = DispatchQueue(label: "figg.chunkwriter.\(stream.rawValue)")
    }

    /// Called from audio callbacks. Converts on the caller's thread, then
    /// hands the samples to a serial queue for accumulation and file IO.
    func append(_ buffer: AVAudioPCMBuffer) {
        // A buffer arrives once it is full, so its first sample was heard
        // one buffer's length before now. (Measured on the input: the
        // converter can hold part of a buffer back until the next one.)
        let firstSample = now().timeIntervalSince(recordingStarted) - Double(buffer.frameLength) / buffer.format.sampleRate
        guard let samples = convert(buffer), !samples.isEmpty else { return }
        levels?.record(stream, samples: samples)
        queue.async { [self] in
            if streamStartOffset == nil { streamStartOffset = max(0, firstSample) }
            pending.append(contentsOf: samples)
            while pending.count >= chunkFrames {
                let chunk = Array(pending.prefix(chunkFrames))
                pending.removeFirst(chunkFrames)
                write(chunk)
            }
        }
    }

    /// Writes whatever is buffered as a final short chunk.
    func flush() {
        queue.sync {
            if !pending.isEmpty { write(pending) }
            pending.removeAll()
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let outFormat = AudioChunk.format
        if converter == nil || converterInput != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outFormat)
            converter?.downmix = true
            converterInput = buffer.format
        }
        guard let converter else { return nil }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }

    private func write(_ samples: [Float]) {
        let offset = (streamStartOffset ?? 0) + Double(framesWritten) / AudioChunk.sampleRate
        framesWritten += samples.count
        let name = AudioChunk.fileName(stream: stream, offset: offset)
        let final = dir.appendingPathComponent(name)
        let partial = dir.appendingPathComponent(name + ".partial")
        do {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: AudioChunk.format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { src in
                buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
            }
            // Scope the file so it is closed before the rename.
            do {
                let file = try AVAudioFile(
                    forWriting: partial,
                    settings: AudioChunk.format.settings,
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false)
                try file.write(from: buffer)
            }
            try FileManager.default.moveItem(at: partial, to: final)
            onChunk(AudioChunk(url: final, stream: stream, offset: offset))
        } catch {
            NSLog("figg: failed to write chunk \(name): \(error)")
            try? FileManager.default.removeItem(at: partial)
        }
    }
}
