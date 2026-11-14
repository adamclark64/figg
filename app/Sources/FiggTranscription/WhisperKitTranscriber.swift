import Foundation
import WhisperKit

/// On-device Whisper via WhisperKit (CoreML). The model downloads from
/// Hugging Face on first use and is cached by WhisperKit; audio never leaves
/// the Mac.
public actor WhisperKitTranscriber: Transcriber {
    public static let defaultModel = "large-v3-v20240930_turbo"

    private let model: String
    private let language: String?
    private let downloadBase: URL?
    private var pipe: WhisperKit?
    private var loading: Task<WhisperKit, Error>?

    /// - Parameter downloadBase: where model files are cached; nil uses
    ///   WhisperKit's default (~/Documents/huggingface).
    public init(model: String = defaultModel, language: String? = "en", downloadBase: URL? = nil) {
        self.model = model
        self.language = language
        self.downloadBase = downloadBase
    }

    /// Downloads (first run) and loads the model. Safe to call repeatedly.
    @discardableResult
    public func prepare() async throws -> WhisperKit {
        if let pipe { return pipe }
        if let loading { return try await loading.value }
        let model = self.model, base = self.downloadBase
        let task = Task {
            try await WhisperKit(WhisperKitConfig(model: model, downloadBase: base, verbose: false, logLevel: .error, prewarm: true, load: true, download: true))
        }
        loading = task
        do {
            let loaded = try await task.value
            pipe = loaded
            loading = nil
            return loaded
        } catch {
            loading = nil
            throw error
        }
    }

    public func load() async throws {
        try await prepare()
        UserDefaults.standard.set(true, forKey: downloadedKey)
    }

    public func isDownloaded() async -> Bool { UserDefaults.standard.bool(forKey: downloadedKey) }

    private var downloadedKey: String { "whisperDownloaded:\(model)" }

    public func transcribe(samples: [Float]) async throws -> [TranscriptSegment] {
        let pipe = try await prepare()
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            skipSpecialTokens: true,
            withoutTimestamps: false)
        let results: [TranscriptionResult] = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        return results.flatMap(\.segments).map {
            TranscriptSegment(start: Double($0.start), end: Double($0.end), text: $0.text)
        }
    }
}
