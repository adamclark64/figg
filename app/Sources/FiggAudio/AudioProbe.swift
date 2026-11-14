import Foundation

/// Diagnostic: records a few seconds with `Recorder` into a temp folder and
/// reports which streams started, why any failed, and how loud each chunk
/// was. All-zero system audio usually means the System Audio Recording
/// permission is missing (macOS delivers silence rather than an error).
public enum AudioProbe {
    public static func run(seconds: Double) async -> String {
        var lines: [String] = []
        let lock = NSLock()
        func add(_ s: String) { lock.withLock { lines.append(s) } }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("figg-probe-\(UUID().uuidString.prefix(8))")
        let recorder = Recorder(dir: dir, chunkSeconds: seconds + 5) { chunk in
            let samples = (try? chunk.samples()) ?? []
            let peak = samples.map(abs).max() ?? 0
            let rms = samples.isEmpty ? 0 : (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
            add(String(format: "chunk %@ samples=%d rms=%.5f peak=%.5f", chunk.stream.rawValue, samples.count, rms, peak))
        }
        let result = await recorder.start()
        add("mic started: \(result.mic), system started: \(result.system)")
        result.problems.forEach { add("problem: \($0)") }
        try? await Task.sleep(for: .seconds(seconds))
        recorder.stop()
        try? await Task.sleep(for: .milliseconds(300))
        try? FileManager.default.removeItem(at: dir)
        return lock.withLock { lines.joined(separator: "\n") }
    }
}
