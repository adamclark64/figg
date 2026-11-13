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
/// way laptop speakers do: delayed, quieter and with one reflection.
func syntheticEchoCase() throws -> EchoCase {
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
    for turn in turns {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("figg-echo-\(UUID().uuidString).aiff")
        try run("/usr/bin/say", ["-v", turn.remote ? "Daniel" : "Samantha", "-o", url.path, turn.text])
        let voice = try load16k(url)
        try? FileManager.default.removeItem(at: url)
        let pause = [Float](repeating: 0, count: 8_000)
        if turn.remote {
            system += voice + pause
            mic += [Float](repeating: 0, count: voice.count + pause.count)
        } else {
            mic += voice + pause
            system += [Float](repeating: 0, count: voice.count + pause.count)
            nearEnd.append(turn.text)
        }
    }
    // Speaker to mic: 40 ms and a third as loud, then a wall reflection.
    for (delay, gain) in [(640, Float(0.35)), (1_440, Float(0.12))] {
        for i in 0..<max(0, system.count - delay) { mic[i + delay] += system[i] * gain }
    }
    return EchoCase(
        mic: StreamAudio(offset: 0, samples: mic, hasSpeech: true),
        system: StreamAudio(offset: 0, samples: system, hasSpeech: true),
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
    let input = try args.first.map { try recordedEchoCase(URL(fileURLWithPath: $0)) } ?? syntheticEchoCase()
    print(String(format: "mic %.1f s from %.1f s, system %.1f s from %.1f s\n",
                 Double(input.mic.samples.count) / 16_000, input.mic.offset,
                 Double(input.system.samples.count) / 16_000, input.system.offset))
    let asr = ParakeetTranscriber()
    try await asr.prepare()
    let systemLines = lines(try await asr.transcribe(samples: input.system.samples), .them, offset: input.system.offset)

    let started = Date()
    let cleaned = try await LocalVqeEchoCanceller().cancel(mic: input.mic.samples, reference: input.system.aligned(to: input.mic))
    let cancelSeconds = Date().timeIntervalSince(started)

    let env = ProcessInfo.processInfo.environment
    let separator: FluidSpeakerSeparator? = env["BENCH_NO_DIARIZE"] == nil ? FluidSpeakerSeparator() : nil
    for (name, mic) in [("raw mic", input.mic.samples), ("echo cancelled", cleaned)] {
        let micLines = StreamAudio.hasSpeech(mic) ? lines(try await asr.transcribe(samples: mic), .me, offset: input.mic.offset) : []
        let all = (micLines + systemLines).sorted { $0.start < $1.start }
        let kept = EchoFilter.removeEchoes(from: all)
        print("== \(name)")
        print(String(format: "mic lines %d | duplicates %.0f%% before the word filter, %.0f%% after",
                     micLines.count, EchoFilter.duplicateRate(all) * 100, EchoFilter.duplicateRate(kept) * 100))
        if let truth = input.nearEndText {
            let heard = micLines.map(\.text).joined(separator: " ")
            print(String(format: "mic WER against what the person at the Mac said: %.1f%%", WER.compute(reference: truth, hypothesis: heard) * 100))
        }
        if let separator {
            let turns = try await separator.turns(samples: mic, speakerCount: nil)
            let labels = SpeakerLabels.labels(for: turns, stream: .mic)
            print("voices found on the mic: \(labels?.count ?? (turns.isEmpty ? 0 : 1))")
        }
        for line in kept where line.speaker == .me { print(String(format: "   %6.1fs Me: %@", line.start, line.text)) }
        print("")
    }
    print(String(format: "echo cancellation took %.1f s (incl. model load)", cancelSeconds))
}
