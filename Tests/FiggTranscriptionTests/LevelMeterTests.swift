import FiggAudio
import FiggTranscription
import Testing

@Suite struct LevelMeterTests {
    @Test func normalizesOnDecibelScale() {
        #expect(LevelMeter.normalized(rms: 0) == 0)
        #expect(LevelMeter.normalized(rms: 1) == 1)
        #expect(LevelMeter.normalized(rms: 0.000_01) == 0)  // below -60 dBFS
        #expect(abs(LevelMeter.normalized(rms: 0.031_62) - 0.5) < 0.001)  // -30 dBFS
    }

    @Test func inactiveStreamStaysNil() {
        let meter = LevelMeter(capacity: 4, windowSamples: 10)
        meter.record(.system, samples: [Float](repeating: 0.5, count: 100))
        #expect(meter.snapshot()[.system] == nil)
    }

    @Test func barsAreTimeBasedAndCapped() {
        let meter = LevelMeter(capacity: 4, windowSamples: 10)
        meter.activate(.mic)
        #expect(meter.snapshot()[.mic] == [0, 0, 0, 0])
        // 15 samples: one full window, five carried over.
        meter.record(.mic, samples: [Float](repeating: 1, count: 15))
        #expect(meter.snapshot()[.mic] == [0, 0, 0, 1])
        // Five more complete the carried window; exact silence reads as 0.
        meter.record(.mic, samples: [Float](repeating: 0, count: 5))
        let bars = meter.snapshot()[.mic]!
        #expect(bars.count == 4)
        #expect(bars[2] == 1)
        #expect(bars[3] > 0 && bars[3] < 1)  // half loud, half silent window
        meter.record(.mic, samples: [Float](repeating: 0, count: 50))
        #expect(meter.snapshot()[.mic] == [0, 0, 0, 0])
    }
}

/// The live "Me" row with the call playing through the speakers.
@Suite struct LevelMeterEchoTests {
    /// Feeds the audio the way the app gets it: system audio in 10 ms
    /// buffers, the mic in 100 ms buffers, on a test clock. Returns the mic
    /// bars drawn for the last `judged` seconds, and whether the mic had
    /// sound in each.
    func run(mic: [Float], system: [Float], judged: Double) -> [(drawn: Float, sounding: Bool)] {
        let clock = SecondsClock()
        let meter = LevelMeter(capacity: 1_000, windowSamples: 800, now: { clock.seconds })
        meter.activate(.mic)
        meter.activate(.system)
        for step in 0..<(mic.count / 160) {
            clock.seconds = Double(step + 1) * 0.01
            meter.record(.system, samples: Array(system[(step * 160)..<((step + 1) * 160)]))
            if (step + 1) % 10 == 0 {
                let end = (step + 1) * 160
                meter.record(.mic, samples: Array(mic[(end - 1_600)..<end]))
            }
        }
        // Bars from the last 0.25 s are still held, waiting for system bars.
        let drawn = Int(((Double(mic.count) / 16_000 - 0.25) / 0.05).rounded(.down))
        let bars = Array(meter.snapshot()[.mic]!.suffix(drawn))
        let first = drawn - Int(judged * 20)
        return (first..<drawn).map { k in
            (bars[k], SilenceGate.rms(Array(mic[(k * 800)..<((k + 1) * 800)])) >= 0.003)
        }
    }

    /// Share of the sounding mic bars that were drawn (not flattened).
    func shareDrawn(_ bars: [(drawn: Float, sounding: Bool)]) -> Double {
        let sounding = bars.filter(\.sounding)
        return Double(sounding.filter { $0.drawn > 0 }.count) / Double(max(1, sounding.count))
    }

    @Test func callThroughTheSpeakersLeavesMeFlat() {
        let call = babble(seconds: 20, seed: 40)
        let bars = run(mic: heard(call, delay: 80, gain: 0.5), system: call, judged: 10)
        #expect(shareDrawn(bars) < 0.1)
    }

    @Test func talkingWhileTheCallIsQuietShows() {
        let call = only(babble(seconds: 20, seed: 41), 0..<12)
        let room = only(babble(seconds: 20, seed: 42, level: 0.3), 13..<20)
        let bars = run(mic: mix(heard(call, delay: 80, gain: 0.5), room), system: call, judged: 6)
        #expect(shareDrawn(bars) > 0.9)
    }

    @Test func talkingOverTheCallShows() {
        let call = babble(seconds: 20, seed: 43)
        let room = only(babble(seconds: 20, seed: 44, level: 0.4), 14..<20)
        let bars = run(mic: mix(heard(call, delay: 80, gain: 0.3), room), system: call, judged: 5)
        #expect(shareDrawn(bars) > 0.5)
    }

    @Test func withHeadphonesEverythingShows() {
        let bars = run(mic: babble(seconds: 20, seed: 45), system: babble(seconds: 20, seed: 46), judged: 10)
        #expect(shareDrawn(bars) > 0.95)
    }
}

final class SecondsClock: @unchecked Sendable {
    var seconds: Double = 0
}
