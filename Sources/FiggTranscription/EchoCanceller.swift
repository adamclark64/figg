import FluidAudio
import Foundation

/// Removes the call audio that the mic picks up from the Mac's speakers.
///
/// Without headphones every remote sentence reaches the mic too, so it was
/// transcribed twice ("Me" and "Them") and the remote voices counted as
/// people in the room. figg already records exactly what the speakers
/// played (the system audio stream), which is the reference an echo
/// canceller needs, so the echo can be taken out of the sound itself
/// rather than guessed at from the words afterwards.
public protocol EchoCanceller: Sendable {
    /// - Parameters:
    ///   - mic: 16 kHz mono microphone samples.
    ///   - reference: what the speakers played, sample-aligned with `mic`
    ///     and the same length (see `StreamAudio.aligned(to:)`).
    /// - Returns: the mic with the echo removed, same length as `mic`.
    func cancel(mic: [Float], reference: [Float]) async throws -> [Float]
}

/// FluidAudio's LocalVQE (neural echo cancellation, noise suppression and
/// dereverb). Runs on the CPU; the small model downloads once into
/// FluidAudio's shared cache on first use. FluidAudio marks it beta, which
/// is why the final pass falls back to the raw mic if it fails and the
/// `transcription.echo_cancellation` setting can turn it off.
public actor LocalVqeEchoCanceller: EchoCanceller {
    private var manager: LocalVqeManager?
    private var loading: Task<LocalVqeManager, Error>?

    /// Samples pushed per call: bounds the extra memory for a long meeting
    /// to a few seconds of audio instead of a second copy of the whole hour.
    /// Streaming output is identical to processing the clip in one go.
    static let block = 30 * 16_000

    public init() {}

    private func prepare() async throws -> LocalVqeManager {
        if let manager { return manager }
        if let loading { return try await loading.value }
        let task = Task { try await LocalVqeManager() }
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

    public func cancel(mic: [Float], reference: [Float]) async throws -> [Float] {
        guard !mic.isEmpty else { return mic }
        let reference = StreamAudio.fit(reference, to: mic.count)
        let stream = try await prepare().makeStream()
        var out: [Float] = []
        out.reserveCapacity(mic.count)
        var i = 0
        while i < mic.count {
            let j = min(i + Self.block, mic.count)
            out += try await stream.enhance(mic: Array(mic[i..<j]), reference: Array(reference[i..<j]))
            i = j
        }
        out += try await stream.flush()
        return StreamAudio.fit(out, to: mic.count)
    }
}
