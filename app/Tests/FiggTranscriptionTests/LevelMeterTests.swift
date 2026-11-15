import FiggAudio
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

@Suite struct LevelMeterRedrawTests {
    @Test func versionMovesOnlyWhenABarIsPushed() {
        let meter = LevelMeter(capacity: 4, windowSamples: 10)
        let start = meter.version
        meter.activate(.mic)
        let started = meter.version
        #expect(started != start)
        meter.activate(.mic)                                    // already on: no change
        meter.record(.mic, samples: [Float](repeating: 0.1, count: 9))   // not a full bar yet
        #expect(meter.version == started)
        meter.record(.mic, samples: [0.1])                      // completes a bar
        #expect(meter.version != started)
        meter.record(.system, samples: [Float](repeating: 0.1, count: 10))  // stream not started
        #expect(meter.snapshot()[.system] == nil)
    }

    @Test func redrawsOnlyWhenVisibleAndChanged() {
        let meter = LevelMeter(capacity: 4, windowSamples: 10)
        meter.activate(.mic)
        var gate = RedrawGate()
        func draw(_ m: LevelMeter, _ visible: Bool) -> Bool { gate.shouldRedraw(meter: m, visible: visible) }
        #expect(draw(meter, true))     // first draw
        #expect(!draw(meter, true))    // nothing new
        meter.record(.mic, samples: [Float](repeating: 0.1, count: 10))
        #expect(!draw(meter, false))   // hidden: skip
        #expect(draw(meter, true))     // back in view: catch up once
        #expect(!draw(meter, true))
        let next = LevelMeter(capacity: 4, windowSamples: 10)       // a new recording
        #expect(draw(next, true))
    }
}
