import AVFoundation
import Foundation

/// Mic capture for one dictation: 16 kHz mono samples kept in memory only,
/// never written to disk. Its own engine, so it works alongside a meeting
/// recording.
public final class DictationCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let resampler = MonoResampler()
    private let lock = NSLock()
    private var samples: [Float] = []
    /// Live level (0...1) for the listening pill.
    private var _level: Float = 0

    public init() {}

    public static func requestPermission() async -> Bool { await MicCapture.requestPermission() }

    public var level: Float { lock.withLock { _level } }

    public func start() throws {
        lock.withLock { samples.removeAll(keepingCapacity: true) }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioCaptureError.noInputDevice }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let converted = self.resampler.convert(buffer) else { return }
            let rms = (converted.reduce(0) { $0 + $1 * $1 } / Float(max(converted.count, 1))).squareRoot()
            self.lock.withLock {
                self.samples.append(contentsOf: converted)
                self._level = min(1, rms * 8)
            }
        }
        engine.prepare()
        try engine.start()
    }

    /// Everything heard so far, without stopping (for the live preview).
    public func snapshot() -> [Float] { lock.withLock { samples } }

    /// Stops the mic and hands back everything heard.
    public func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return lock.withLock {
            let out = samples
            samples.removeAll()
            _level = 0
            return out
        }
    }
}
