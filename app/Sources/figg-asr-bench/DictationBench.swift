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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("figg-dict-\(UUID().uuidString).aiff")
        try run("/usr/bin/say", ["-o", url.path, text])
        let samples = try load16k(url)
        try? FileManager.default.removeItem(at: url)
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
}
