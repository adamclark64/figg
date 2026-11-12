import FiggWidget
import Foundation
import Testing

@Suite struct LoaderStyleTests {
    @Test func theNewtonIsTheDefaultAndTheFigIsAskedForByName() {
        #expect(LoaderStyle.named("newton") == .newton)
        #expect(LoaderStyle.named("fig") == .fig)
        #expect(LoaderStyle.named(" Fig ") == .fig)
        // A typo or an empty value can only give the default.
        #expect(LoaderStyle.named("") == .newton)
        #expect(LoaderStyle.named("figs") == .newton)
        #expect(LoaderStyle.named("spinner") == .newton)
    }

    @Test func theFigStartsAtRestAndTurnsOncePerPeriod() {
        #expect(FigSpin.yaw(at: 0) == FigSpin.restYaw)
        #expect(abs(FigSpin.yaw(at: FigSpin.period / 4) - (FigSpin.restYaw + .pi / 2)) < 1e-9)
        #expect(abs(FigSpin.yaw(at: FigSpin.period / 2) - (FigSpin.restYaw + .pi)) < 1e-9)
    }

    @Test func theTurnIsSteady() {
        // Equal steps in time are equal steps in angle, apart from the wrap
        // back at the end of each turn, which is the same pose.
        let step = 1.0 / 120
        var previous = FigSpin.yaw(at: 0)
        var t = step
        while t < 3 * FigSpin.period {
            let yaw = FigSpin.yaw(at: t)
            let moved = yaw - previous
            let expected = 2 * Double.pi * step / FigSpin.period
            #expect(abs(moved - expected) < 1e-6 || abs(moved - expected + 2 * .pi) < 1e-6)
            previous = yaw
            t += step
        }
    }

    @Test func theAngleStaysWithinOneTurnHoweverLongItRuns() {
        for t in [0.0, 1.3, 86_400, 30 * 86_400 + 0.7] {
            let yaw = FigSpin.yaw(at: t)
            #expect(yaw >= FigSpin.restYaw)
            #expect(yaw < FigSpin.restYaw + 2 * .pi)
        }
        let early = FigSpin.yaw(at: 0.7)
        let late = FigSpin.yaw(at: 1_000_000 * FigSpin.period + 0.7)
        #expect(abs(early - late) < 1e-6)
    }
}
