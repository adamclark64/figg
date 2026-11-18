@testable import FiggNotes
import Testing

@Suite struct StreamRevealTests {
    @Test func revealsAtTheBaseRateWhenCloseBehind() {
        var r = StreamReveal()
        r.receive(String(repeating: "a", count: 40))
        r.advance(by: 0.1, finished: false)
        #expect(r.shown == 8)  // 80 characters a second
        #expect(r.isBehind)
    }

    @Test func speedsUpToKeepUpWithABigBurst() {
        var r = StreamReveal()
        r.receive(String(repeating: "a", count: 700))
        r.advance(by: 0.1, finished: false)
        #expect(r.shown == 100)  // 700 / 0.7 s
    }

    @Test func finishesFasterOnceTheStreamEnds() {
        var r = StreamReveal()
        r.receive(String(repeating: "a", count: 300))
        r.advance(by: 0.1, finished: true)
        #expect(r.shown == 100)  // 300 / 0.3 s
    }

    @Test func neverRunsPastTheText() {
        var r = StreamReveal()
        r.receive("short")
        r.advance(by: 5, finished: true)
        #expect(r.visible == "short")
        #expect(!r.isBehind)
    }

    @Test func keepsItsPlaceWhenTheStreamGrows() {
        var r = StreamReveal()
        r.receive("Hello")
        r.advance(by: 1, finished: false)
        r.receive("Hello, world")
        #expect(r.visible == "Hello")
        #expect(r.isBehind)
    }

    @Test func startsOverWhenTheTextIsReplaced() {
        var r = StreamReveal()
        r.receive("First run of notes")
        r.advance(by: 1, finished: false)
        r.receive("Second")
        #expect(r.shown == 0)
    }

    @Test func showAllSkipsTheReveal() {
        var r = StreamReveal()
        r.showAll("Saved notes")
        #expect(r.visible == "Saved notes")
        #expect(!r.isBehind)
    }

    @Test func smallTicksAddUp() {
        var r = StreamReveal()
        r.receive(String(repeating: "a", count: 40))
        for _ in 0..<10 { r.advance(by: 1.0 / 120, finished: false) }
        #expect(r.shown == 6)  // 80 * 10/120 = 6.67, the rest carried over
    }
}
