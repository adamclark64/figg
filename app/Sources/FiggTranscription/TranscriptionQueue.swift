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
    /// Whether to leave out mic lines heard while you were muted
    /// (`transcription.skip_mic_when_muted`), read at the time of use.
    private let skipMuted: @Sendable () -> Bool
    /// The share of a stretch of a live meeting you were muted for, from the
    /// running watcher; nil when no watcher is running for that meeting.
    private let liveMutedShare: @Sendable (_ meetingId: String, _ start: Double, _ end: Double) -> Double?
    private let onLines: @Sendable ([TranscriptLine]) -> Void

    private var queue: [(meetingId: String, chunk: AudioChunk)] = []
    private var running = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    /// The last `speakers.json` loaded for live filtering, for one meeting.
    private var savedMute: (meetingId: String, timeline: SpeakerTimeline)?

    /// - Parameters:
    ///   - skipMuted: default off, so callers that do not pass it keep every mic line.
    ///   - liveMutedShare: when it gives nil, the meeting's saved
    ///     `speakers.json` is used instead (the backlog after Stop, crash recovery).
    public init(
        store: Store,
        paths: FiggPaths,
        transcriber: Transcriber,
        separator: SpeakerSeparator? = nil,
        keepAudio: @escaping @Sendable () -> Bool,
        liveName: @escaping @Sendable (_ meetingId: String, _ start: Double, _ end: Double) -> String? = { _, _, _ in nil },
        skipMuted: @escaping @Sendable () -> Bool = { false },
        liveMutedShare: @escaping @Sendable (_ meetingId: String, _ start: Double, _ end: Double) -> Double? = { _, _, _ in nil },
        onLines: @escaping @Sendable ([TranscriptLine]) -> Void
    ) {
        self.store = store
        self.paths = paths
        self.transcriber = transcriber
        self.separator = separator
        self.keepAudio = keepAudio
        self.liveName = liveName
        self.skipMuted = skipMuted
        self.liveMutedShare = liveMutedShare
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
                if chunk.stream == .mic, !lines.isEmpty, skipMuted() {
                    lines = lines.filter { mutedShare(meetingId, $0.start, $0.end) < MuteFilter.minShare }
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

    /// How much of [start, end] you were muted for: from the running watcher,
    /// else from the meeting's saved `speakers.json`, else 0. The chunk is
    /// still moved to done/ either way, so the final pass sees every file.
    private func mutedShare(_ meetingId: String, _ start: Double, _ end: Double) -> Double {
        if let share = liveMutedShare(meetingId, start, end) { return share }
        return savedTimeline(meetingId)?.mutedShare(start: start, end: end) ?? 0
    }

    /// The meeting's saved timeline, loaded once per meeting. A missing file
    /// is not remembered, so one written later (at Stop) is still found.
    private func savedTimeline(_ meetingId: String) -> SpeakerTimeline? {
        if let savedMute, savedMute.meetingId == meetingId { return savedMute.timeline }
        guard let loaded = SpeakerTimeline.load(from: timelineURL(meetingId)) else { return nil }
        savedMute = (meetingId, loaded)
        return loaded
    }

    private func timelineURL(_ meetingId: String) -> URL {
        paths.meetingDir(meetingId).appendingPathComponent(SpeakerTimeline.fileName)
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

        let saved = SpeakerTimeline.load(from: timelineURL(meetingId))
        // Names the meeting app showed while recording (Zoom), if any.
        let timeline = saved.flatMap { $0.spans.isEmpty ? nil : $0 }
        // When you were muted, if any and if the setting is on now.
        let muted = skipMuted() ? saved.flatMap { $0.muted.isEmpty ? nil : $0 } : nil

        var lines: [TranscriptLine] = []
        for stream in AudioStream.allCases {
            let mine = chunks.filter { $0.stream == stream }
            guard let first = mine.first else { continue }
            var samples: [Float] = []
            var sizes: [(offset: Double, samples: Int)] = []
            var speechAt = Set<Int>()  // sample index where a chunk with speech starts
            for chunk in mine {
                let s = try chunk.samples()
                if !SilenceGate.isSilent(s) { speechAt.insert(samples.count) }
                sizes.append((chunk.offset, s.count))
                samples += s
            }
            // A stream that never had speech would only produce hallucinations.
            guard !speechAt.isEmpty else { continue }
            // Each stretch between pauses on its own, so no line spans a
            // pause and its timestamps stay on the wall clock.
            let runs = RecordingRuns.runs(sizes)
            var streamLines: [TranscriptLine] = []
            for run in runs where speechAt.contains(where: { $0 >= run.start && $0 < run.start + run.count }) {
                let segments = try await transcriber.transcribe(samples: Array(samples[run.start..<(run.start + run.count)]))
                let whole = AudioChunk(url: first.url, stream: stream, offset: run.offset)
                streamLines += Self.lines(from: segments, chunk: whole, meetingId: meetingId)
            }
            // Who spoke when, so several people on one stream get their own
            // labels. Optional: on failure the default Me/Them labels stay.
            // Separated over the whole stream, so a voice keeps its label
            // across a pause.
            if let separator {
                do {
                    let count = stream == .mic ? roomSpeakers : nil
                    // One person in the room: nothing to separate on the mic.
                    let joined = count == 1 ? [] : try await separator.turns(samples: samples, speakerCount: count)
                    let turns = RecordingRuns.wallClock(joined, runs: runs, base: first.offset)
                    // Talk while muted does not count towards choosing "Me".
                    let rankTurns: [SpeakerTurn]? = stream == .mic && muted != nil
                        ? MuteFilter.unmutedTurns(turns, muted: muted, offset: first.offset) : nil
                    streamLines = SpeakerLabels.apply(turns, to: streamLines, stream: stream, offset: first.offset, timeline: timeline, rankTurns: rankTurns)
                } catch {
                    NSLog("figg: speaker separation failed: \(error)")
                }
            }
            // Outside the separator block, so it also applies with speaker
            // separation off or failed.
            if stream == .mic { streamLines = MuteFilter.drop(streamLines, muted: muted) }
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
