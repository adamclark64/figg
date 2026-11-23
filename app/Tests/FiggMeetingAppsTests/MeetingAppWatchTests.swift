@testable import FiggMeetingApps
import Testing

@Suite struct MeetingAppWatchTests {
    @Test func namesOnlyStartsWithNamesAndTodaysBanner() {
        let p = MeetingAppWatch.plan(names: true, skipMuted: false)
        #expect(p.start)
        #expect(p.names)
        #expect(p.bannerText == MeetingAppWatch.namesText("Zoom"))
        #expect(p.bannerText?.contains("\"Them 1\"") == true)
        #expect(p.bannerText?.contains("muted") == false)
    }

    @Test func muteOnlyStartsWithoutNames() {
        let p = MeetingAppWatch.plan(names: false, skipMuted: true)
        #expect(p.start)
        #expect(!p.names)
        #expect(p.bannerText == MeetingAppWatch.muteText("Zoom"))
        #expect(p.bannerText?.hasPrefix("figg can leave out what your mic hears while you are muted on Zoom") == true)
        #expect(p.bannerText?.contains("Them 1") == false)
    }

    @Test func bothStartsWithNamesAndNamesBoth() {
        let p = MeetingAppWatch.plan(names: true, skipMuted: true)
        #expect(p.start)
        #expect(p.names)
        #expect(p.bannerText == MeetingAppWatch.bothText("Zoom"))
        #expect(p.bannerText?.contains("names") == true)
        #expect(p.bannerText?.contains("muted") == true)
    }

    @Test func neitherDoesNotStart() {
        let p = MeetingAppWatch.plan(names: false, skipMuted: false)
        #expect(!p.start)
        #expect(!p.names)
        #expect(p.bannerText == nil)
    }

    @Test func bannerNamesTheMeetingApp() {
        let p = MeetingAppWatch.plan(names: true, skipMuted: true, app: "Google Meet")
        #expect(p.bannerText?.contains("Google Meet's names") == true)
        #expect(p.bannerText?.contains("muted on Google Meet") == true)
        #expect(p.bannerText?.contains("Zoom") == false)
    }

    @Test func everyBannerSaysNothingLeavesTheMac() {
        for (n, m) in [(true, false), (false, true), (true, true)] {
            let text = MeetingAppWatch.plan(names: n, skipMuted: m).bannerText
            #expect(text?.hasSuffix("nothing leaves this Mac.") == true)
            #expect(text?.contains("Accessibility") == true)
        }
    }
}
