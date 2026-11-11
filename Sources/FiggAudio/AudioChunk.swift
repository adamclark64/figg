import AVFoundation
import Foundation

public enum AudioStream: String, Sendable, CaseIterable {
    case mic
    case system
}

/// One finished chunk file on disk. The file name encodes the stream and the
/// offset from meeting start, so a chunk can be recovered after a crash with
/// nothing but the folder listing.
public struct AudioChunk: Sendable, Equatable {
    public let url: URL
    public let stream: AudioStream
    /// Seconds from meeting start to the first sample.
    public let offset: Double

    public static let fileExtension = "caf"
    /// All chunks are 16 kHz mono Float32, which is what Whisper expects.
    public static let sampleRate: Double = 16_000

    public static func fileName(stream: AudioStream, offset: Double) -> String {
        String(format: "%@_%010d.%@", stream.rawValue, Int((offset * 1000).rounded()), fileExtension)
    }

    public init(url: URL, stream: AudioStream, offset: Double) {
        self.url = url
        self.stream = stream
        self.offset = offset
    }

    /// Parses `mic_0000012345.caf`; nil for anything else (e.g. partial files).
    public init?(url: URL) {
        guard url.pathExtension == Self.fileExtension else { return nil }
        let parts = url.deletingPathExtension().lastPathComponent.split(separator: "_")
        guard parts.count == 2,
              let stream = AudioStream(rawValue: String(parts[0])),
              let millis = Int(parts[1]) else { return nil }
        self.init(url: url, stream: stream, offset: Double(millis) / 1000)
    }

    /// Finished chunks in a folder, oldest first.
    public static func list(in dir: URL) -> [AudioChunk] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap(AudioChunk.init(url:)).sorted { $0.offset < $1.offset }
    }

    public static var format: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    }

    /// Loudest absolute sample, 0 for digital silence.
    public func peak() -> Float {
        ((try? samples()) ?? []).reduce(0) { max($0, abs($1)) }
    }

    /// Reads the chunk back as samples.
    public func samples() throws -> [Float] {
        try Self.readMono(url)
    }

    /// Reads a whole mono file as Float32 samples. Loops because a single
    /// `AVAudioFile.read` returns a multiple of 1024 frames and leaves the
    /// remainder, which once silently cut up to 64 ms off every chunk.
    public static func readMono(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        var out: [Float] = []
        out.reserveCapacity(Int(file.length))
        while file.framePosition < file.length {
            let remaining = AVAudioFrameCount(file.length - file.framePosition)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: remaining) else { break }
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            out.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        }
        return out
    }
}

/// Notices when system audio is pure digital silence for a while. macOS
/// returns exact zeros (not an error) when figg lacks the System Audio
/// Recording permission, so this is the only signal we get.
public struct SilenceWatch: Sendable {
    public let chunksBeforeWarning: Int
    private var silentRun = 0
    private var warned = false

    public init(chunksBeforeWarning: Int = 3) {
        self.chunksBeforeWarning = chunksBeforeWarning
    }

    /// Returns true exactly once, when the run of silent chunks reaches the limit.
    public mutating func record(peak: Float) -> Bool {
        silentRun = peak == 0 ? silentRun + 1 : 0
        guard !warned, silentRun >= chunksBeforeWarning else { return false }
        warned = true
        return true
    }
}
