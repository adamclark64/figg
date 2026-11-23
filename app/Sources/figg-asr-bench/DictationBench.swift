import FiggDictation
import FiggTranscription
import Foundation

// --dictation: where the time goes between letting go of the dictation key
// and the text being typed. Two parts are timed apart, because only one of
// them is figg's own text handling:
//   1. the text step (`DictationText.prepare`), in microseconds per call,
//      with spoken punctuation off and on;
//   2. Parakeet on a spoken utterance, with the text step beside it.
// Run it before and after changing anything on the dictation path.
//   swift run -c release figg-asr-bench --dictation
//   BENCH_TEXT_ONLY=1 skips part 2 (no model needed).

/// Median nanoseconds for one call of `body`, over `samples` batches.
func medianNanos(samples: Int = 60, batch: Int = 200, _ body: () -> Void) -> Double {
    var times: [Double] = []
    for _ in 0..<samples {
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<batch { body() }
        times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / Double(batch))
    }
    return times.sorted()[samples / 2]
}

/// Keeps a result alive so the optimiser cannot drop the call being timed.
@inline(never) func keep(_ text: String) { if text.utf8.count == .max { print(text) } }

func dictationBench() async throws {
    let plain = "Thanks for sending the notes over. I read them this morning and I think the plan for the book fair looks good."
    let spoken = "Hi Sam comma thanks for sending the notes period New paragraph can we meet on Tuesday question mark"
    // What Parakeet tends to write when the marks are spoken: its own
    // punctuation around the words.
    let spokenAsHeard = "Hi Sam, comma, thanks for sending the notes. Period. New paragraph. Can we meet on Tuesday? Question mark."
    let cases: [(String, [String])] = [
        ("plain, 21 words", [plain]),
        ("spoken marks, 18 words", [spoken]),
        ("spoken marks as heard, 18 words", [spokenAsHeard]),
        ("plain, 420 words", [Array(repeating: plain, count: 20).joined(separator: " ")]),
        ("spoken marks, 360 words", [Array(repeating: spoken, count: 20).joined(separator: " ")]),
    ]
    print("== text step (DictationText.prepare), median per call")
    for (name, segments) in cases {
        let off = medianNanos { keep(DictationText.prepare(segments, precedingCharacter: "x")) }
        let on = medianNanos { keep(DictationText.prepare(segments, precedingCharacter: "x", spokenPunctuation: true)) }
        print(String(format: "%-34@ off %8.2f µs | spoken punctuation on %8.2f µs", name as NSString, off / 1_000, on / 1_000))
    }
    if ProcessInfo.processInfo.environment["BENCH_TEXT_ONLY"] != nil { return }

    let utterances: [(String, String)] = [
        ("short", "Hi Sam comma thanks for the notes period"),
        ("medium", "Hi Sam comma thanks for sending the notes over period New paragraph I read them this morning and the plan for the book fair looks good period Can we meet on Tuesday at ten to go through the budget question mark"),
        ("long", script),
    ]
    let parakeet = ParakeetTranscriber()
    let loadStart = Date()
    try await parakeet.prepare()
    print(String(format: "\n== release to text (parakeet, load %.1f s)", Date().timeIntervalSince(loadStart)))
    for (name, text) in utterances {
        let samples = try speech(text)
        _ = try await parakeet.transcribe(samples: samples)  // warm
        var asr: [Double] = []
        var segments: [String] = []
        for _ in 0..<5 {
            let start = DispatchTime.now().uptimeNanoseconds
            segments = try await parakeet.transcribe(samples: samples).compactMap { TranscriptCleaner.clean($0.text) }
            asr.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        let asrMs = asr.sorted()[asr.count / 2]
        let textUs = medianNanos {
            keep(DictationText.prepare(segments, precedingCharacter: "x", spokenPunctuation: true))
        } / 1_000
        print(String(format: "%-7@ %5.1f s audio | transcribe %7.1f ms | text step %7.2f µs (%.4f%% of the wait)",
                     name as NSString, Double(samples.count) / 16_000, asrMs, textUs, textUs / 1_000 / asrMs * 100))
        print("   heard: \(segments.joined(separator: " "))")
        print("   typed: \(DictationText.prepare(segments, spokenPunctuation: true).debugDescription)")
    }

    // 3. What the final pass waits behind. Predictions run one at a time, so
    // letting go of the key while something else is being transcribed adds
    // to the wait.
    let long = try speech(script + " " + script)
    let chunk = Array(long.prefix(160_000))
    func ms(_ body: () async throws -> Void) async rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try await body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    }
    func median(_ runs: Int = 5, _ body: () async throws -> Double) async rethrows -> Double {
        var all: [Double] = []
        for _ in 0..<runs { all.append(try await body()) }
        return all.sorted()[runs / 2]
    }
    print(String(format: "\n== what the final pass waits behind (%.0f s dictation)", Double(long.count) / 16_000))
    let alone = try await median { try await ms { _ = try await finalPass(parakeet, long) } }
    print(String(format: "%-44@ %7.1f ms", "nothing else running" as NSString, alone))
    let behindPreview = try await median {
        let preview = Task { try? await previewPass(parakeet, Array(long.dropLast(4_800))) }
        try await Task.sleep(for: .milliseconds(5))
        let wait = try await ms { _ = try await finalPass(parakeet, long) }
        preview.cancel()
        _ = await preview.value
        return wait
    }
    print(String(format: "%-44@ %7.1f ms", "a live preview pass just started" as NSString, behindPreview))
    let behindMeeting = try await median(3) {
        let chunks = (0..<6).map { _ in Task { _ = try? await parakeet.transcribe(samples: chunk) } }
        try await Task.sleep(for: .milliseconds(5))
        let wait = try await ms { _ = try await finalPass(parakeet, long) }
        for task in chunks { _ = await task.value }
        return wait
    }
    print(String(format: "%-44@ %7.1f ms", "6 meeting chunks (10 s each) waiting" as NSString, behindMeeting))
    // The preview's own cost, which every pass pays while you speak.
    let previewCost = try await median { try await ms { _ = try await previewPass(parakeet, long) } }
    print(String(format: "%-44@ %7.1f ms", "one live preview pass" as NSString, previewCost))
}

/// `text` as 16 kHz speech. The voice is named: the system default can be
/// one that `say` cannot write to a file, which gives an empty recording.
func speech(_ text: String) throws -> [Float] {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("figg-dict-\(UUID().uuidString).aiff")
    defer { try? FileManager.default.removeItem(at: url) }
    try run("/usr/bin/say", ["-v", ProcessInfo.processInfo.environment["BENCH_VOICE"] ?? "Samantha", "-o", url.path, text])
    let samples = try load16k(url)
    guard samples.count > 8_000 else { throw NSError(domain: "say wrote no audio; set BENCH_VOICE to an installed voice", code: 1) }
    return samples
}

/// The two dictation passes as the app makes them, so the bench follows the
/// app when either changes.
func previewPass(_ transcriber: ParakeetTranscriber, _ samples: [Float]) async throws -> [TranscriptSegment] {
    try await transcriber.transcribe(samples: DictationPreview.tail(samples).samples, urgent: true)
}

func finalPass(_ transcriber: ParakeetTranscriber, _ samples: [Float]) async throws -> [TranscriptSegment] {
    try await transcriber.transcribe(samples: samples, urgent: true)
}
