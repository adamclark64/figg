import FiggWidget
import Foundation
import Testing

@Suite struct NewtonMotionTests {
    private let period = NewtonMotion.period

    private func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

    @Test func everyHopStartsAndEndsOnTheGround() {
        for cycle in 0..<6 {
            let start = NewtonMotion.hop(at: Double(cycle) * period)
            #expect(start.lift == 0)
            #expect(close(start.stretch, 1))
            #expect(close(start.spread, 1))
            #expect(start.grow == 1)
        }
        // On the ground for the crouch and the landing, in the air between.
        #expect(NewtonMotion.hop(at: 0.1 * period).lift == 0)
        #expect(NewtonMotion.hop(at: 0.9 * period).lift == 0)
        #expect(NewtonMotion.hop(at: 0.3 * period).lift > 0)
    }

    @Test func hopPeaksMidAirAtFullHeight() {
        let apex = NewtonMotion.hop(at: 0.48 * period)
        #expect(close(apex.lift, NewtonMotion.hopHeight))
        #expect(apex.stretch > 1)
        #expect(apex.spread < 1)
    }

    @Test func aLowerHopOnlyChangesHowHighItGoes() {
        let t = 0.48 * period
        let full = NewtonMotion.hop(at: t)
        let low = NewtonMotion.hop(at: t, height: 0.3)
        #expect(close(low.lift, 0.3))
        #expect(low.yaw == full.yaw)
        #expect(low.stretch == full.stretch)
        // No hop at all, or a nonsense height, keeps it on the ground.
        #expect(NewtonMotion.hop(at: t, height: 0).lift == 0)
        #expect(NewtonMotion.hop(at: t, height: -2).lift == 0)
    }

    @Test func crouchAndLandingSquashWithoutLeavingTheGround() {
        for t in [0.09, 0.89] {
            let pose = NewtonMotion.hop(at: t * period)
            #expect(pose.lift == 0)
            #expect(pose.stretch < 1)
            #expect(pose.spread > 1)
        }
    }

    @Test func eachHopTurnsAQuarterAndTheTurnHappensInTheAir() {
        let quarter = Double.pi / 2
        let rest = NewtonMotion.restYaw
        #expect(close(NewtonMotion.hop(at: 0).yaw, rest))
        // Still facing the old way through the crouch.
        #expect(close(NewtonMotion.hop(at: 0.17 * period).yaw, rest))
        // Half way round at the top.
        #expect(close(NewtonMotion.hop(at: 0.48 * period).yaw, rest + quarter / 2))
        // Landed facing the new way, and it stays there into the next hop.
        #expect(close(NewtonMotion.hop(at: 0.8 * period).yaw, rest + quarter))
        #expect(close(NewtonMotion.hop(at: 1.1 * period).yaw, rest + quarter))
        #expect(close(NewtonMotion.hop(at: 3.05 * period).yaw, rest + 3 * quarter))
    }

    @Test func yawNeverJumpsBetweenFrames() {
        // A jump would show as the cookie snapping round. The fourth hop ends
        // a full turn, where the angle wraps back to the start.
        var previous = NewtonMotion.hop(at: 0).yaw
        var t = 0.0
        while t < 3.95 * period {
            t += 1.0 / 240
            let yaw = NewtonMotion.hop(at: t).yaw
            #expect(abs(yaw - previous) < 0.05)
            previous = yaw
        }
    }

    @Test func fourHopsAreAFullTurnSoLongUptimeLooksTheSame() {
        let early = NewtonMotion.hop(at: 0.4 * period)
        let late = NewtonMotion.hop(at: (4_000_000 + 0.4) * period)
        #expect(abs(early.yaw - late.yaw) < 1e-6)
        #expect(abs(early.lift - late.lift) < 1e-6)
    }

    @Test func extrudingGrowsWithProgressAndStaysOnTheGround() {
        #expect(NewtonMotion.extruding(progress: 0.4, at: nil).grow == 0.4)
        #expect(NewtonMotion.extruding(progress: 1, at: nil).grow == 1)
        #expect(NewtonMotion.extruding(progress: 0.4, at: 12).lift == 0)
    }

    @Test func extrudingClampsProgressAndNeverVanishes() {
        #expect(NewtonMotion.extruding(progress: 0, at: nil).grow == NewtonMotion.minimumGrow)
        #expect(NewtonMotion.extruding(progress: -3, at: nil).grow == NewtonMotion.minimumGrow)
        #expect(NewtonMotion.extruding(progress: 7, at: nil).grow == 1)
    }

    @Test func extrudingHoldsStillWithoutATimeAndSwaysWithOne() {
        #expect(NewtonMotion.extruding(progress: 0.5, at: nil).yaw == NewtonMotion.restYaw)
        let swayed = NewtonMotion.extruding(progress: 0.5, at: 2.5).yaw
        #expect(swayed != NewtonMotion.restYaw)
        #expect(abs(swayed - NewtonMotion.restYaw) <= 0.12)
    }
}
