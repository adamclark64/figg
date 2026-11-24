import Testing
@testable import FiggStartup

struct StallDetectorTests {
    @Test func noStallUnderTheThreshold() {
        var detector = StallDetector(start: 100)
        #expect(detector.threshold == 3)
        #expect(detector.stall(at: 101) == nil)
        #expect(detector.stall(at: 103) == nil)
        detector.heartbeat(at: 102.5)
        #expect(detector.stall(at: 105) == nil)
    }

    @Test func stallReportedWithItsLength() {
        let detector = StallDetector(start: 100)
        #expect(detector.stall(at: 103.5) == 3.5)
        #expect(detector.stall(at: 112) == 12)
    }

    @Test func heartbeatClearsTheStall() {
        var detector = StallDetector(start: 0)
        #expect(detector.stall(at: 10) == 10)
        detector.heartbeat(at: 10)
        #expect(detector.stall(at: 10.5) == nil)
    }

    /// A heartbeat stamp read late (older than one already seen) must not
    /// move the clock back and invent a stall.
    @Test func olderHeartbeatIsIgnored() {
        var detector = StallDetector(threshold: 1, start: 0)
        detector.heartbeat(at: 5)
        detector.heartbeat(at: 2)
        #expect(detector.lastHeartbeat == 5)
        #expect(detector.stall(at: 5.5) == nil)
    }
}
