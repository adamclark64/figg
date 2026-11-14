import Foundation

/// A piece of recognised speech, timed relative to the start of the audio it
/// came from.
public struct TranscriptSegment: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Speech-to-text over 16 kHz mono samples: Parakeet (default) or WhisperKit,
/// or a fake in tests. Must handle both 10 s live chunks and a whole
/// recording (the final pass).
public protocol Transcriber: Sendable {
    /// Downloads (if needed) and loads the model. Safe to call repeatedly.
    func load() async throws
    /// True if the model files are already on disk, so loading needs no download.
    func isDownloaded() async -> Bool
    func transcribe(samples: [Float]) async throws -> [TranscriptSegment]
}

public extension Transcriber {
    func load() async throws {}
    func isDownloaded() async -> Bool { true }
}

/// Skips chunks with no speech worth sending to Whisper, which otherwise
/// invents phrases like "Thank you." on silence.
public enum SilenceGate {
    /// RMS below this (about -46 dBFS) counts as silence.
    public static let defaultThreshold: Float = 0.005

    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    public static func isSilent(_ samples: [Float], threshold: Float = defaultThreshold) -> Bool {
        rms(samples) < threshold
    }
}

/// Cleans model output: drops special tokens, bracketed non-speech tags
/// ("[Music]", "(laughs)") and known silence hallucinations.
public enum TranscriptCleaner {
    static let hallucinations: Set<String> = [
        "thank you.", "thanks for watching!", "thank you for watching.",
        "you", "bye.", "subtitles by the amara.org community",
    ]

    public static func clean(_ text: String) -> String? {
        var t = text.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"^\s*[\[\(][^\]\)]*[\]\)]\s*$"#, with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || hallucinations.contains(t.lowercased()) { return nil }
        return t
    }
}
