import FluidAudio
import Foundation

/// On-device Nvidia Parakeet TDT v3 via FluidAudio (CoreML, Neural Engine).
/// Models live in FluidAudio's shared cache
/// (~/Library/Application Support/FluidAudio/Models), so other apps built on
/// FluidAudio share the same download.
public actor ParakeetTranscriber: Transcriber {
    private var manager: AsrManager?
    private var loading: Task<AsrManager, Error>?

    public init() {}

    /// Downloads (if missing) and loads the models. Safe to call repeatedly.
    @discardableResult
    public func prepare() async throws -> AsrManager {
        if let manager { return manager }
        if let loading { return try await loading.value }
        let task = Task {
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        }
        loading = task
        do {
            let loaded = try await task.value
            manager = loaded
            loading = nil
            return loaded
        } catch {
            loading = nil
            throw error
        }
    }

    public func load() async throws { try await prepare() }

    public func isDownloaded() async -> Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3))
    }

    public func transcribe(samples: [Float]) async throws -> [TranscriptSegment] {
        let manager = try await prepare()
        // Each chunk is independent, so each gets a fresh decoder state.
        var state = TdtDecoderState.make()
        let result = try await manager.transcribe(samples, decoderState: &state)
        return Self.segments(text: result.text, timings: result.tokenTimings ?? [], duration: Double(samples.count) / 16_000)
    }

    /// Splits token timings into sentence segments, so a 10 s chunk becomes
    /// lines like Whisper's rather than one block. Falls back to one segment
    /// covering the chunk when there are no timings.
    static func segments(text: String, timings: [TokenTiming], duration: Double) -> [TranscriptSegment] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !timings.isEmpty else {
            return trimmed.isEmpty ? [] : [TranscriptSegment(start: 0, end: duration, text: trimmed)]
        }
        var out: [TranscriptSegment] = []
        var words = ""
        var start: Double?
        var end = 0.0
        func flush() {
            let t = words.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, let s = start { out.append(TranscriptSegment(start: s, end: end, text: t)) }
            words = ""
            start = nil
        }
        for token in timings {
            // SentencePiece marks a word start with "▁".
            let piece = token.token.replacingOccurrences(of: "▁", with: " ")
            if start == nil { start = token.startTime }
            words += piece
            end = token.endTime
            if let last = piece.trimmingCharacters(in: .whitespaces).last, ".?!".contains(last) { flush() }
        }
        flush()
        return out
    }
}
