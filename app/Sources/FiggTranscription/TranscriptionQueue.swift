import FiggAudio
import FiggMeetingApps
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
    private let keepAudio: @Sendable () -> Bool
    /// Who the meeting app shows speaking over a stretch of a live meeting, if anyone.
    private let liveName: @Sendable (_ meetingId: String, _ start: Double, _ end: Double) -> String?
    private let onLines: @Sendable ([TranscriptLine]) -> Void

    private var queue: [(meetingId: String, chunk: AudioChunk)] = []
    private var running = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        store: Store,
        paths: FiggPaths,
        transcriber: Transcriber,
        separator: SpeakerSeparator? = nil,
        keepAudio: @escaping @Sendable () -> Bool,
        liveName: @escaping @Sendable (_ meetingId: String, _ start: Double, _ end: Double) -> String? = { _, _, _ in nil },
        onLines: @escaping @Sendable ([TranscriptLine]) -> Void
    ) {
        self.store = store
        self.paths = paths
        self.transcriber = transcriber
        self.separator = separator
        self.keepAudio = keepAudio
        self.liveName = liveName
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
                if chunk.stream == .system {
                    for i in lines.indices { lines[i].speakerLabel = liveName(meetingId, lines[i].start, lines[i].end) }
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

        // Names the meeting app showed while recording (Zoom), if any.
        let timeline = SpeakerTimeline.load(from: paths.meetingDir(meetingId).appendingPathComponent(SpeakerTimeline.fileName))
            .flatMap { $0.spans.isEmpty ? nil : $0 }

        var lines: [TranscriptLine] = []
        for stream in AudioStream.allCases {
            let mine = chunks.filter { $0.stream == stream }
            guard let first = mine.first else { continue }
            var samples: [Float] = []
            var anySpeech = false
            for chunk in mine {
                let s = try chunk.samples()
                if !SilenceGate.isSilent(s) { anySpeech = true }
                samples += s
            }
            // A stream that never had speech would only produce hallucinations.
            guard anySpeech else { continue }
            let segments = try await transcriber.transcribe(samples: samples)
            let whole = AudioChunk(url: first.url, stream: stream, offset: first.offset)
            var streamLines = Self.lines(from: segments, chunk: whole, meetingId: meetingId)
            // Who spoke when, so several people on one stream get their own
            // labels. Optional: on failure the default Me/Them labels stay.
            if let separator {
                do {
                    let count = stream == .mic ? roomSpeakers : nil
                    // One person in the room: nothing to separate on the mic.
                    let turns = count == 1 ? [] : try await separator.turns(samples: samples, speakerCount: count)
                    streamLines = SpeakerLabels.apply(turns, to: streamLines, stream: stream, offset: first.offset, timeline: timeline)
                } catch {
                    NSLog("figg: speaker separation failed: \(error)")
                }
            }
            if stream == .system, let timeline { streamLines = SpeakerLabels.nameLines(streamLines, timeline: timeline) }
            lines += streamLines
        }
        // Without headphones the mic also hears the call; keep only the
        // system-audio copy of those lines.
        lines = EchoFilter.removeEchoes(from: lines)
        lines.sort { $0.start < $1.start }
        let stored = try store.replaceTranscript(meetingId: meetingId, with: lines)
        onLines(stored)
        fm.createFile(atPath: finalMarker(meetingId).path, contents: nil)
        if !keepAudio() { try? fm.removeItem(at: done) }
    }
}
