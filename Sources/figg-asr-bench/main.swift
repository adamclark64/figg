import AVFoundation
import FiggAudio
import FiggStore
import FiggTranscription
import Foundation

// Dev tool: compares speech engines on the same audio, cut into the same
// 10 s chunks the app uses. Reports word error rate and speed.
//   swift run -c release figg-asr-bench               # synthetic speech via `say`
//   swift run -c release figg-asr-bench file.wav "reference text"
//   swift run -c release figg-asr-bench --echo [meeting folder]  (see EchoBench.swift)
setvbuf(stdout, nil, _IONBF, 0)

let script = """
Thanks for coming, everyone. The spring book fair is on Saturday the twelfth, from ten until four, in the main hall of the library. \
So far forty people have signed up to bring books, which is more than last year. Nora has drawn a poster and it looks great. \
We have about three hundred dollars for tables, snacks and a banner, and the bakery on the corner has offered to bring cakes. \
There are two things to sort out. First, we need more volunteers for the morning, because setting up takes longer than you think. \
Second, somebody has to count the money at the end of the day. Ben said he could do it if nobody else wants to. \
If it rains we will move the children's corner inside. I will send a reminder to everyone a week before.
"""

func run(_ cmd: String, _ args: [String]) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: cmd)
    p.arguments = args
    try p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw NSError(domain: cmd, code: Int(p.terminationStatus)) }
}

func load16k(_ url: URL) throws -> [Float] {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("figg-bench-\(UUID().uuidString).wav")
    try run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEF32@16000", "-c", "1", url.path, tmp.path])
    defer { try? FileManager.default.removeItem(at: tmp) }
    return try AudioChunk.readMono(tmp)
}

if let i = CommandLine.arguments.firstIndex(of: "--echo") {
    try await runEchoBench(Array(CommandLine.arguments[(i + 1)...]))
    exit(0)
}

// --diarize: three voices take turns, as if three people shared one mic.
if CommandLine.arguments.contains("--diarize") {
    let lines: [(String, String)] = [
        ("Samantha", "Has anyone looked at the weather for the hike on Sunday?"),
        ("Daniel", "Yes. It should be dry in the morning, with some wind on the ridge."),
        ("Fred", "Then we should start early and take the shorter loop."),
        ("Samantha", "Good idea. Daniel, can you bring the map and the first aid kit?"),
        ("Daniel", "I will. I also have room for two more people in my car."),
        ("Fred", "I'll bring coffee and something to eat at the top."),
        ("Samantha", "Great. Let's meet at the trailhead at seven."),
    ]
    var samples: [Float] = []
    var truth: [(start: Double, end: Double, who: String)] = []
    for (voice, text) in lines {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("figg-dia-\(UUID().uuidString).aiff")
        try run("/usr/bin/say", ["-v", voice, "-o", url.path, text])
        let s = try load16k(url)
        let start = Double(samples.count) / 16_000
        samples += s + [Float](repeating: 0, count: 8_000)  // 0.5 s pause between turns
        truth.append((start, start + Double(s.count) / 16_000, voice))
        try? FileManager.default.removeItem(at: url)
    }
    let started = Date()
    let env = ProcessInfo.processInfo.environment
    let separator = FluidSpeakerSeparator(threshold: env["BENCH_THRESHOLD"].flatMap(Double.init))
    let turns = try await separator.turns(samples: samples, speakerCount: env["BENCH_SPEAKERS"].flatMap(Int.init))
    print(String(format: "diarized %.1f s in %.1f s (incl. model load)", Double(samples.count) / 16_000, Date().timeIntervalSince(started)))
    let labels = SpeakerLabels.labels(for: turns, stream: .mic) ?? [:]
    print("speakers found: \(Set(turns.map(\.speaker)).count) -> labels \(labels)")
    var mapping: [String: String] = [:]   // voice -> label, first seen
    var correct = 0
    for t in truth {
        let line = TranscriptLine(meetingId: "bench", speaker: .me, start: t.start, end: t.end, text: "")
        let id = SpeakerLabels.speaker(for: line, turns: turns, offset: 0)
        let label = id.flatMap { labels[$0] } ?? "?"
        if mapping[t.who] == nil, !mapping.values.contains(label) { mapping[t.who] = label }
        let ok = mapping[t.who] == label
        if ok { correct += 1 }
        print(String(format: "%6.1fs  %-8@ -> %-8@ %@", t.start, t.who, label, ok ? "ok" : "WRONG"))
    }
    print("\(correct)/\(truth.count) turns attributed consistently")
    exit(0)
}

let args = CommandLine.arguments.dropFirst()
let audioURL: URL
let reference: String
if args.count >= 2 {
    audioURL = URL(fileURLWithPath: args.first!)
    reference = args.dropFirst().joined(separator: " ")
} else {
    audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("figg-bench-say.aiff")
    try run("/usr/bin/say", ["-o", audioURL.path, script])
    reference = script
}
let samples = try load16k(audioURL)
let audioSeconds = Double(samples.count) / 16_000
let chunkSamples = Int((Double(ProcessInfo.processInfo.environment["BENCH_CHUNK"] ?? "10") ?? 10) * 16_000)
let chunks = stride(from: 0, to: samples.count, by: chunkSamples).map { Array(samples[$0..<min($0 + chunkSamples, samples.count)]) }
print(String(format: "audio: %.1f s in %d chunks\n", audioSeconds, chunks.count))

let engines: [(String, Transcriber, () async throws -> Void)] = {
    let whisper = WhisperKitTranscriber(downloadBase: FiggPaths.standard.models)
    let parakeet = ParakeetTranscriber()
    return [
        ("whisper (large-v3 turbo)", whisper, { try await whisper.prepare() }),
        ("parakeet (tdt 0.6b v3)", parakeet, { try await parakeet.prepare() }),
    ]
}()

let only = ProcessInfo.processInfo.environment["BENCH_ONLY"]?.lowercased()
for (name, engine, prepare) in engines where only.map({ name.hasPrefix($0) }) ?? true {
    let loadStart = Date()
    try await prepare()
    let load = Date().timeIntervalSince(loadStart)
    let start = Date()
    var text: [String] = []
    for chunk in chunks {
        text += try await engine.transcribe(samples: chunk).compactMap { TranscriptCleaner.clean($0.text) }
    }
    let secs = Date().timeIntervalSince(start)
    let hypothesis = text.joined(separator: " ")
    let wer = WER.compute(reference: reference, hypothesis: hypothesis)
    print("== \(name)")
    print(String(format: "load %.1f s | transcribe %.2f s (%.0fx real time) | WER %.1f%%", load, secs, audioSeconds / secs, wer * 100))
    print("   \(hypothesis)\n")
}
