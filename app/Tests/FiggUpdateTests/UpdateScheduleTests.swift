import FiggUpdate
import Foundation
import Testing

@Suite struct UpdateScheduleTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func firstCheckIsAlwaysDue() {
        #expect(UpdateSchedule().isDue(at: start))
    }

    @Test func waitsForTheIntervalAfterACheck() {
        var s = UpdateSchedule()
        s.checked(at: start)
        #expect(!s.isDue(at: start.addingTimeInterval(UpdateSchedule.interval - 1)))
        #expect(s.isDue(at: start.addingTimeInterval(UpdateSchedule.interval)))
    }

    @Test func wakeUsesTheShorterInterval() {
        var s = UpdateSchedule()
        s.checked(at: start)
        let later = start.addingTimeInterval(UpdateSchedule.wakeInterval)
        #expect(s.isDue(at: later, after: UpdateSchedule.wakeInterval))
        #expect(!s.isDue(at: later))
        #expect(!s.isDue(at: start.addingTimeInterval(60), after: UpdateSchedule.wakeInterval))
    }

    @Test func offersEachVersionOnce() {
        var s = UpdateSchedule()
        #expect(s.shouldOffer("0.9.0"))
        #expect(!s.shouldOffer("0.9.0"))
        #expect(s.offered == "0.9.0")
    }

    @Test func offersANewerReleaseThatAppearsLater() {
        var s = UpdateSchedule()
        #expect(s.shouldOffer("0.9.0"))
        #expect(s.shouldOffer("0.10.0"))
        #expect(!s.shouldOffer("0.9.0"))
        #expect(s.offered == "0.10.0")
    }
}
