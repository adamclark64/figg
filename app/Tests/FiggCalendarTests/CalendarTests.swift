import FiggCalendar
import Foundation
import Testing

@Suite struct EventMatchingTests {
    let noon = Date(timeIntervalSince1970: 1_767_225_600)  // fixed reference

    func event(_ title: String, startMin: Double, endMin: Double, allDay: Bool = false) -> CalendarEvent {
        CalendarEvent(id: title, title: title,
                      start: noon.addingTimeInterval(startMin * 60),
                      end: noon.addingTimeInterval(endMin * 60),
                      isAllDay: allDay)
    }

    @Test func currentPicksTheOverlappingEvent() {
        let events = [event("earlier", startMin: -120, endMin: -60), event("now", startMin: -10, endMin: 20)]
        #expect(events.current(at: noon)?.title == "now")
    }

    @Test func currentMatchesWithinGraceOnly() {
        let soon = [event("soon", startMin: 4, endMin: 34)]
        #expect(soon.current(at: noon)?.title == "soon")  // joining 4 min early
        #expect(soon.current(at: noon, grace: 60) == nil)  // 1 min of grace is not enough
        #expect([event("later", startMin: 30, endMin: 60)].current(at: noon) == nil)
    }

    @Test func currentPrefersTheNestedEventOverTheBlock() {
        let events = [event("focus block", startMin: -120, endMin: 120), event("1:1", startMin: -5, endMin: 25)]
        #expect(events.current(at: noon)?.title == "1:1")
    }

    @Test func allDayEventsNeverMatch() {
        let events = [event("holiday", startMin: -600, endMin: 600, allDay: true)]
        #expect(events.current(at: noon) == nil)
        #expect(events.next(after: noon) == nil)
    }

    @Test func nextPicksTheSoonestWithinTheWindow() {
        let events = [
            event("tomorrow", startMin: 26 * 60, endMin: 27 * 60),
            event("in an hour", startMin: 60, endMin: 90),
            event("afternoon", startMin: 150, endMin: 180),
        ]
        #expect(events.next(after: noon)?.title == "in an hour")
        #expect(events.next(after: noon, window: 30 * 60) == nil)
    }

    @Test func nextIncludesTheMeetingRunningNow() {
        let events = [event("running", startMin: -10, endMin: 20)]
        #expect(events.next(after: noon)?.title == "running")
    }
}
