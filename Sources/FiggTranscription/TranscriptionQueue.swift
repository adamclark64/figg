import FiggAudio
import FiggStore
import Foundation

/// Transcribes chunk files in order, one at a time, and stores the lines.
/// Chunks wait on disk, so a slow Mac just falls behind and catches up after
/// the meeting instead of dropping audio.
///
/// Live chunks are 10 s so lines appear quickly, but cutting speech every
/// 10 s costs accuracy (words at the cuts get dropped or invented). So after
/// Stop, `finalPass` re-transcribes each stream's whole recording and swaps
/// in those lines.
public actor TranscriptionQueue {
    private let store: Store
    private let paths: FiggPaths
    private let transcriber: Transcriber
    private let separator: SpeakerSeparator?
    private let echoCanceller: EchoCanceller?
    private let cancelEcho: @Sendable () -> Bool
    private let keepAudio: @Sendable () -> Bool
    private let onLines: @Sendable ([TranscriptLine]) -> Void

    private var queue: [(meetingId: String, chunk: AudioChunk)] = []
    private var running = false
    /// Last speaker-to-mic delay found per meeting, for chunks too quiet on
    /// the call side to find their own.
    private var liveDelay: [String: EchoDetector.Delay] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        store: Store,
        paths: FiggPaths,
        transcriber: Transcriber,
        separator: SpeakerSeparator? = nil,
        echoCanceller: EchoCanceller? = nil,
        cancelEcho: @escaping @Sendable () -> Bool = { true },
        keepAudio: @escaping @Sendable () -> Bool,
        onLines: @escaping @Sendable ([TranscriptLine]) -> Void
    ) {
        self.store = store
        self.paths = paths
        self.transcriber = transcriber
        self.separator = separator
        self.echoCanceller = echoCanceller
        self.cancelEcho = cancelEcho
        self.keepAudio = keepAudio
        self.onLines = onLines
    }

    public func enqueue(_ chunk: AudioChunk, meetingId: String) {
        queue.append((meetingId, chunk))
        if !running {
            running = true
            Task { await self.run() }
        }
    }

    /// Queues every chunk still pending for a meeting (crash recovery).
    public func enqueuePending(meetingId: String) {
        let queued = Set(queue.map(\.chunk.url))
        for chunk in AudioChunk.list(in: paths.pendingDir(meetingId)) where !queued.contains(chunk.url) {
            enqueue(chunk, meetingId: meetingId)
        }
    }

    public var backlog: Int { queue.count }

    /// Returns once everything queued so far has been transcribed.
    public func drain() async {
        if !running && queue.isEmpty { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func run() async {
        while !queue.isEmpty {
            let (meetingId, chunk) = queue.removeFirst()
            await process(chunk, meetingId: meetingId)
        }
        running = false
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func process(_ chunk: AudioChunk, meetingId: String) async {
        do {
            let samples = try chunk.samples()
            if !SilenceGate.isSilent(samples) {
                let segments = try await transcriber.transcribe(samples: samples)
                var lines = Self.lines(from: segments, chunk: chunk, meetingId: meetingId)
                if chunk.stream == .mic, !lines.isEmpty, cancelEcho(),
                   let echo = await liveEchoMap(mic: samples, chunk: chunk, meetingId: meetingId) {
                    lines.removeAll { echo.isEcho(start: $0.start, end: $0.end) }
                }
                if !lines.isEmpty {
                    let stored = try store.append(lines)
                    onLines(stored)
                }
            }
            finish(chunk, meetingId: meetingId)
        } catch {
            // Leave the file in pending/ so recovery can retry it later.
            NSLog("figg: transcription failed for \(chunk.url.lastPathComponent): \(error)")
        }
    }

    /// Which parts of a live mic chunk were the call coming out of the
    /// speakers, judged against the system chunks recorded at the same time.
    /// Nil when there is no system audio for that stretch; the final pass
    /// catches those lines after Stop.
    private func liveEchoMap(mic: [Float], chunk: AudioChunk, meetingId: String) async -> EchoDetector.Map? {
        let end = chunk.offset + Double(mic.count) / Double(StreamAudio.sampleRate)
        var system = systemAudio(meetingId: meetingId, from: chunk.offset, to: end)
        // The system chunk for the same 10 s is written a moment after the
        // mic's. Wait up to a second for it, but only when this meeting has
        // system audio at all (or this is its first chunk, before any is on
        // disk), so a mic-only meeting does not stall.
        for _ in 0..<4 {
            guard system.any || chunk.offset < 1, (system.audio?.end ?? 0) < end - 0.5 else { break }
            try? await Task.sleep(for: .milliseconds(250))
            system = systemAudio(meetingId: meetingId, from: chunk.offset, to: end)
        }
        guard let audio = system.audio, audio.hasSpeech else { return nil }
        let micAudio = StreamAudio(offset: chunk.offset, samples: mic, hasSpeech: true)
        let reference = audio.aligned(to: micAudio)
        let found = EchoDetector.estimateDelay(mic: mic, reference: reference)
        if let found { liveDelay[meetingId] = found }
        guard let delay = found ?? liveDelay[meetingId] else { return nil }
        return EchoDetector.map(mic: mic, reference: reference, offset: chunk.offset, delay: delay)
    }

    /// The system audio on disk (pending or done) that can overlap a span,
    /// and whether the meeting has any system chunks at all.
    private func systemAudio(meetingId: String, from start: Double, to end: Double) -> (audio: StreamAudio?, any: Bool) {
        let all = (AudioChunk.list(in: paths.pendingDir(meetingId)) + AudioChunk.list(in: paths.doneDir(meetingId)))
            .filter { $0.stream == .system }
        // System chunks are 10 s too: one starting up to 12 s before the
        // span can still overlap it.
        let near = all.filter { $0.offset > start - 12 && $0.offset < end + 1 }.sorted { $0.offset < $1.offset }
        return ((try? StreamAudio.assemble(near)) ?? nil, !all.isEmpty)
    }

    static func lines(from segments: [TranscriptSegment], chunk: AudioChunk, meetingId: String) -> [TranscriptLine] {
        segments.compactMap { segment in
            guard let text = TranscriptCleaner.clean(segment.text) else { return nil }
            return TranscriptLine(
                meetingId: meetingId,
                speaker: chunk.stream == .mic ? .me : .them,
                start: chunk.offset + segment.start,
                end: chunk.offset + segment.end,
                text: text)
        }
    }

    /// Moves a transcribed chunk to done/, where the final pass reads it.
    private func finish(_ chunk: AudioChunk, meetingId: String) {
        let fm = FileManager.default
        let done = paths.doneDir(meetingId)
        try? fm.createDirectory(at: done, withIntermediateDirectories: true)
        try? fm.moveItem(at: chunk.url, to: done.appendingPathComponent(chunk.url.lastPathComponent))
    }

    private func finalMarker(_ meetingId: String) -> URL {
        paths.meetingDir(meetingId).appendingPathComponent("final-pass.done")
    }

    /// Re-transcribes each stream's full recording and replaces the live
    /// lines. Runs once per meeting (a marker file records it); call after
    /// `drain()`. On failure the live lines and the audio are left in place,
    /// so a later call can retry. Afterwards the audio is deleted unless
    /// "keep audio" is on.
    /// - Parameter roomSpeakers: how many people share the mic, if the user
    ///   said; nil lets the diarizer decide. Call audio is always automatic.
    public func finalPass(meetingId: String, roomSpeakers: Int? = nil) async throws {
        let fm = FileManager.default
        let done = paths.doneDir(meetingId)
        let chunks = AudioChunk.list(in: done)
        guard !chunks.isEmpty, !fm.fileExists(atPath: finalMarker(meetingId).path) else { return }

        var audio: [AudioStream: StreamAudio] = [:]
        for stream in AudioStream.allCases {
            audio[stream] = try StreamAudio.assemble(chunks.filter { $0.stream == stream })
        }
        // Where the call audio sits in the raw mic, for the canceller's
        // reference and for EchoFilter's sound check afterwards.
        var echoMap: EchoDetector.Map?
        if let mic = audio[.mic], let system = audio[.system], cancelEcho(), mic.hasSpeech, system.hasSpeech {
            let reference = system.aligned(to: mic)
            let map = EchoDetector.map(mic: mic.samples, reference: reference, offset: mic.offset)
            echoMap = map
            if let delay = map.delay {
                NSLog("figg: speaker echo found %.0f ms after the system audio (confidence %.2f)", delay.seconds * 1000, delay.confidence)
            }
            audio[.mic] = await removeEcho(from: mic, reference: reference, delay: map.delay)
        }

        var lines: [TranscriptLine] = []
        for stream in AudioStream.allCases {
            // A stream that never had speech would only produce hallucinations.
            guard let recorded = audio[stream], recorded.hasSpeech else { continue }
            let samples = recorded.samples
            let segments = try await transcriber.transcribe(samples: samples)
            let whole = AudioChunk(url: done, stream: stream, offset: recorded.offset)
            var streamLines = Self.lines(from: segments, chunk: whole, meetingId: meetingId)
            // Who spoke when, so several people on one stream get their own
            // labels. Optional: on failure the default Me/Them labels stay.
            if let separator {
                do {
                    let count = stream == .mic ? roomSpeakers : nil
                    // One person in the room: nothing to separate on the mic.
                    let turns = count == 1 ? [] : try await separator.turns(samples: samples, speakerCount: count)
                    streamLines = SpeakerLabels.apply(turns, to: streamLines, stream: stream, offset: recorded.offset)
                } catch {
                    NSLog("figg: speaker separation failed: \(error)")
                }
            }
            lines += streamLines
        }
        // Whatever echo the canceller left (or all of it, when it is off or
        // failed): keep only the system-audio copy of those lines.
        lines = EchoFilter.removeEchoes(from: lines, echo: echoMap)
        lines.sort { $0.start < $1.start }
        let stored = try store.replaceTranscript(meetingId: meetingId, with: lines)
        onLines(stored)
        fm.createFile(atPath: finalMarker(meetingId).path, contents: nil)
        if !keepAudio() { try? fm.removeItem(at: done) }
    }

    /// Takes the speakers' sound out of the mic before it is transcribed and
    /// diarized, so remote speech is neither doubled as "Me" nor counted as
    /// people in the room. Returns the mic unchanged when echo cancellation
    /// is off, when there was nothing on the call to echo, or on failure
    /// (the word-based `EchoFilter` still runs afterwards).
    /// - Parameters:
    ///   - reference: the system audio on the mic's timeline.
    ///   - delay: where the echo really sits, if `EchoDetector` found it. The
    ///     reference is moved to just ahead of the echo, since the stream
    ///     offsets can put it after the echo, where nothing gets cancelled.
    func removeEcho(from mic: StreamAudio, reference: [Float], delay: EchoDetector.Delay?) async -> StreamAudio {
        guard let echoCanceller else { return mic }
        do {
            var clean = mic
            let reference = delay.map { EchoDetector.shift(reference, for: $0) } ?? reference
            clean.samples = try await echoCanceller.cancel(mic: mic.samples, reference: reference)
            // A mic that only ever heard the call is now quiet: skip it.
            clean.hasSpeech = StreamAudio.hasSpeech(clean.samples)
            return clean
        } catch {
            NSLog("figg: echo cancellation failed, using the raw mic: \(error)")
            return mic
        }
    }
}
