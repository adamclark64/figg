import FiggAudio
import FiggStore
import FiggTranscription
import Foundation

// --echo: how much of the call audio the mic picks up shows in the
// transcript, with and without echo cancellation.
//   swift run -c release figg-asr-bench --echo                  # synthetic: one voice "in the room", one "on the call"
//   swift run -c release figg-asr-bench --echo <meeting folder> # a real recording kept with Keep audio on
// A real meeting folder is ~/Library/Application Support/figg/meetings/<id>;
// its done/ holds the chunks. Audio is read on this Mac and never sent anywhere.

/// Mic and system audio on meeting time, plus what the person at the Mac
/// really said when known (synthetic case only).
struct EchoCase {
    var mic: StreamAudio
    var system: StreamAudio
    var nearEndText: String?
}

/// Two voices taking turns, with the remote one also reaching the mic the
/// way laptop speakers do: delayed, with one reflection.
enum SyntheticCall: CaseIterable {
    /// Speakers at a third of the voice's loudness, offsets right.
    case laptop
    /// What the first real call showed: the echo is louder than the remote
    /// voice itself, the system stream's offset is 100 ms late (so the mic's
    /// copy seems to come 60 ms early), and the person at the Mac starts one
    /// reply while the other side is still talking.
    case loud
    /// No echo at all: nothing on the mic may be dropped.
    case headphones

    var title: String {
        switch self {
        case .laptop: "laptop speakers"
        case .loud: "loud speakers, late system offset, talking over"
        case .headphones: "headphones (no echo)"
        }
    }
}

func syntheticEchoCase(_ call: SyntheticCall) throws -> EchoCase {
    let hard = call == .loud
    let turns: [(remote: Bool, text: String)] = [
        (true, "Can everyone see my screen now? I want to start with the roadmap."),
        (false, "Yes, I can see it. The second column looks cut off."),
        (true, "Right, let me zoom out a little. So the plan is to ship the beta on Friday."),
        (false, "Friday is too early for us. We still need two days of testing."),
        (true, "Okay, then let's say Tuesday, and Nora will send the release notes."),
        (false, "Tuesday works. I will tell the support team today."),
    ]
    var mic: [Float] = [], system: [Float] = []
    var nearEnd: [String] = []
    var lastRemote = 0..<0
    for (n, turn) in turns.enumerated() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("figg-echo-\(UUID().uuidString).aiff")
        try run("/usr/bin/say", ["-v", turn.remote ? "Daniel" : "Samantha", "-o", url.path, turn.text])
        let voice = try load16k(url)
        try? FileManager.default.removeItem(at: url)
        // In the hard case the last reply talks over the end of the remote turn.
        let at = hard && n == turns.count - 1 ? lastRemote.lowerBound + lastRemote.count / 2 : mic.count
        let needed = at + voice.count + 8_000
        if mic.count < needed {
            mic += [Float](repeating: 0, count: needed - mic.count)
            system += [Float](repeating: 0, count: needed - system.count)
        }
        if turn.remote {
            for (i, v) in voice.enumerated() { system[at + i] += v }
            lastRemote = at..<(at + voice.count)
        } else {
            for (i, v) in voice.enumerated() { mic[at + i] += v }
            nearEnd.append(turn.text)
        }
    }
    // Speaker to mic: 40 ms, then a wall reflection.
    let gains: [Float] = switch call {
    case .laptop: [0.35, 0.12]
    case .loud: [1.4, 0.5]
    case .headphones: [0, 0]
    }
    for (delay, gain) in zip([640, 1_440], gains) {
        for i in 0..<max(0, system.count - delay) { mic[i + delay] += system[i] * gain }
    }
    return EchoCase(
        mic: StreamAudio(offset: 0, samples: mic, hasSpeech: true),
        system: StreamAudio(offset: hard ? 0.1 : 0, samples: system, hasSpeech: true),
        nearEndText: nearEnd.joined(separator: " "))
}

func recordedEchoCase(_ folder: URL) throws -> EchoCase {
    let done = folder.appendingPathComponent("done")
    let dir = FileManager.default.fileExists(atPath: done.path) ? done : folder
    let chunks = AudioChunk.list(in: dir)
    guard let mic = try StreamAudio.assemble(chunks.filter { $0.stream == .mic }),
          let system = try StreamAudio.assemble(chunks.filter { $0.stream == .system }) else {
        throw NSError(domain: "figg-asr-bench", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(dir.path) needs both mic_ and system_ chunks (record with Keep audio on)"])
    }
    return EchoCase(mic: mic, system: system, nearEndText: nil)
}

func lines(_ segments: [TranscriptSegment], _ speaker: Speaker, offset: Double) -> [TranscriptLine] {
    segments.compactMap { s in
        TranscriptCleaner.clean(s.text).map { TranscriptLine(meetingId: "bench", speaker: speaker, start: offset + s.start, end: offset + s.end, text: $0) }
    }
}

func runEchoBench(_ args: [String]) async throws {
    if let folder = args.first {
        try await runEchoCase(try recordedEchoCase(URL(fileURLWithPath: folder)))
        try await replayLive(URL(fileURLWithPath: folder))
    } else {
        for call in SyntheticCall.allCases {
            print("##### synthetic: \(call.title)")
            try await runEchoCase(try syntheticEchoCase(call))
        }
    }
}

/// The final pass's echo steps on one recording, with the numbers.
func runEchoCase(_ input: EchoCase) async throws {
    print(String(format: "mic %.1f s from %.1f s, system %.1f s from %.1f s",
                 Double(input.mic.samples.count) / 16_000, input.mic.offset,
                 Double(input.system.samples.count) / 16_000, input.system.offset))
    let asr = ParakeetTranscriber()
    try await asr.prepare()
    let systemLines = lines(try await asr.transcribe(samples: input.system.samples), .them, offset: input.system.offset)

    let reference = input.system.aligned(to: input.mic)
    let started = Date()
    let echoMap = EchoDetector.map(mic: input.mic.samples, reference: reference, offset: input.mic.offset)
    let detectSeconds = Date().timeIntervalSince(started)
    if let delay = echoMap.delay {
        print(String(format: "echo found %.0f ms after the system audio (confidence %.2f), in %.2f s", delay.seconds * 1000, delay.confidence, detectSeconds))
    } else {
        print("no echo found")
    }
    let frames = echoMap.frames
    print(String(format: "mic frames: %.0f%% echo, %.0f%% speech, %.0f%% quiet\n",
                 Double(frames.filter { $0 == .echo }.count) * 100 / Double(max(1, frames.count)),
                 Double(frames.filter { $0 == .speech }.count) * 100 / Double(max(1, frames.count)),
                 Double(frames.filter { $0 == .quiet }.count) * 100 / Double(max(1, frames.count))))

    let cancelStarted = Date()
    let shifted = echoMap.delay.map { EchoDetector.shift(reference, for: $0) } ?? reference
    let cleaned = try await LocalVqeEchoCanceller().cancel(mic: input.mic.samples, reference: shifted)
    let cancelSeconds = Date().timeIntervalSince(cancelStarted)

    let env = ProcessInfo.processInfo.environment
    let separator: FluidSpeakerSeparator? = env["BENCH_NO_DIARIZE"] == nil ? FluidSpeakerSeparator() : nil
    for (name, mic) in [("raw mic", input.mic.samples), ("echo cancelled", cleaned)] {
        let micLines = StreamAudio.hasSpeech(mic) ? lines(try await asr.transcribe(samples: mic), .me, offset: input.mic.offset) : []
        let all = (micLines + systemLines).sorted { $0.start < $1.start }
        let byWords = EchoFilter.removeEchoes(from: all)
        let kept = EchoFilter.removeEchoes(from: all, echo: echoMap)
        let bySound = micLines.filter { echoMap.isEcho(start: $0.start, end: $0.end) }.count
        print("== \(name)")
        print(String(format: "mic lines %d | duplicates %.0f%% before the filter, %.0f%% after words only, %.0f%% after words and sound",
                     micLines.count, EchoFilter.duplicateRate(all) * 100, EchoFilter.duplicateRate(byWords) * 100, EchoFilter.duplicateRate(kept) * 100))
        print("mic lines the sound check alone drops (the live filter): \(bySound) of \(micLines.count)")
        if let truth = input.nearEndText {
            let heard = micLines.map(\.text).joined(separator: " ")
            let survived = kept.filter { $0.speaker == .me }.map(\.text).joined(separator: " ")
            print(String(format: "WER against what the person at the Mac said: %.1f%% on the mic, %.1f%% on the Me lines kept",
                         WER.compute(reference: truth, hypothesis: heard) * 100, WER.compute(reference: truth, hypothesis: survived) * 100))
        }
        if let separator {
            let turns = try await separator.turns(samples: mic, speakerCount: nil)
            let labels = SpeakerLabels.labels(for: turns, stream: .mic)
            print("voices found on the mic: \(labels?.count ?? (turns.isEmpty ? 0 : 1))")
        }
        for line in kept where line.speaker == .me { print(String(format: "   %6.1fs Me: %@", line.start, line.text)) }
        print("")
    }
    print(String(format: "echo cancellation took %.1f s (incl. model load)\n", cancelSeconds))
}

/// Feeds a recording's chunks through `TranscriptionQueue` one by one, as
/// during the meeting, to count the live lines with the echo check on and
/// off. Works on copies in a temporary folder; the meeting is untouched.
func replayLive(_ folder: URL) async throws {
    let done = folder.appendingPathComponent("done")
    let source = FileManager.default.fileExists(atPath: done.path) ? done : folder
    let asr = ParakeetTranscriber()
    try await asr.prepare()
    // BENCH_REALTIME=1 replays at recording speed (slow, but faithful).
    let realtime = ProcessInfo.processInfo.environment["BENCH_REALTIME"] != nil
    print("== live lines, chunk by chunk\(realtime ? ", in real time" : "")")
    for on in [false, true] {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("figg-echo-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let paths = FiggPaths(base: base)
        let store = try Store.inMemory()
        let meeting = Meeting()
        try store.save(meeting)
        let pending = paths.pendingDir(meeting.id)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        let queue = TranscriptionQueue(store: store, paths: paths, transcriber: asr, cancelEcho: { on }, keepAudio: { false }, onLines: { _ in })
        if realtime {
            // Each chunk appears when the recorder would have finished it,
            // so the live check sees system chunks arrive late, as in the app.
            let arrivals = try AudioChunk.list(in: source).map { chunk in
                (chunk, chunk.offset + Double(try chunk.samples().count) / 16_000)
            }.sorted { $0.1 < $1.1 }
            let started = ContinuousClock.now
            for (chunk, at) in arrivals {
                try await Task.sleep(until: started.advanced(by: .milliseconds(Int(at * 1000))), clock: .continuous)
                let url = pending.appendingPathComponent(chunk.url.lastPathComponent)
                try FileManager.default.copyItem(at: chunk.url, to: url)
                await queue.enqueue(AudioChunk(url: url, stream: chunk.stream, offset: chunk.offset), meetingId: meeting.id)
            }
        } else {
            for chunk in AudioChunk.list(in: source) {
                try FileManager.default.copyItem(at: chunk.url, to: pending.appendingPathComponent(chunk.url.lastPathComponent))
            }
            await queue.enqueuePending(meetingId: meeting.id)
        }
        await queue.drain()
        let lines = try store.transcript(meetingId: meeting.id)
        print(String(format: "echo check %@: %d Me, %d Them, duplicates %.0f%%",
                     on ? "on " : "off", lines.filter { $0.speaker == .me }.count, lines.filter { $0.speaker == .them }.count,
                     EchoFilter.duplicateRate(lines) * 100))
        if on { for line in lines where line.speaker == .me { print(String(format: "   %6.1fs Me: %@", line.start, line.text)) } }
    }
}
