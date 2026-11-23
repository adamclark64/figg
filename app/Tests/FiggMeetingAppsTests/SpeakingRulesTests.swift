@testable import FiggMeetingApps
import Testing

@Suite struct SpeakingRulesTests {
    let sam = Participant(name: "Sam Lee", muted: false)
    let bill = Participant(name: "Bill Ortiz", muted: false)
    let nora = Participant(name: "Nora Hale", muted: true)

    @Test func appCueComesFirst() {
        #expect(SpeakingRules.speaking(cue: nora.with(muted: false), people: [sam, bill, nora], selfName: "Sam Lee") == "Nora Hale")
    }

    @Test func cueThatIsYouOrMutedIsIgnored() {
        // Falls through to rule 2: Bill is the only other unmuted person.
        #expect(SpeakingRules.speaking(cue: sam, people: [sam, bill, nora], selfName: "Sam Lee") == "Bill Ortiz")
        #expect(SpeakingRules.speaking(cue: nora, people: [sam, bill, nora], selfName: "Sam Lee") == "Bill Ortiz")
        #expect(SpeakingRules.speaking(cue: sam, people: [sam], selfName: "Sam Lee") == nil)
    }

    @Test func onlyOneOtherUnmuted() {
        #expect(SpeakingRules.speaking(cue: nil, people: [sam, bill, nora], selfName: "Sam Lee") == "Bill Ortiz")
        #expect(SpeakingRules.speaking(cue: nil, people: [sam, bill, nora.with(muted: false)], selfName: "Sam Lee") == nil)
        #expect(SpeakingRules.speaking(cue: nil, people: [sam, bill, nora], selfName: nil) == nil)
    }

    @Test func twoOfYouIsUnclear() {
        #expect(SpeakingRules.speaking(cue: nil, people: [sam, sam, bill], selfName: "Sam Lee") == nil)
    }

    @Test func oneToOneOnlyWhenAsked() {
        let quiet = Participant(name: "Bill Ortiz", muted: nil)
        #expect(SpeakingRules.speaking(cue: nil, people: [sam, quiet], selfName: "Sam Lee") == nil)
        #expect(SpeakingRules.speaking(cue: nil, people: [sam, quiet], selfName: "Sam Lee", oneToOne: true) == "Bill Ortiz")
        #expect(SpeakingRules.speaking(cue: nil, people: [sam, nora], selfName: "Sam Lee", oneToOne: true) == nil)
        #expect(SpeakingRules.speaking(cue: nil, people: [sam, quiet, nora.with(muted: nil)], selfName: "Sam Lee", oneToOne: true) == nil)
    }

    @Test func agreeNeedsNoDisagreement() {
        #expect(SpeakingRules.agree(true, nil) == true)
        #expect(SpeakingRules.agree(nil, false) == false)
        #expect(SpeakingRules.agree(true, false) == nil)
        #expect(SpeakingRules.agree(nil, nil) == nil)
        #expect(SpeakingRules.agree(true, true, true) == true)
    }
}

extension Participant {
    func with(muted: Bool?) -> Participant { Participant(name: name, muted: muted) }
}

@Suite struct TimelineOthersTests {
    @Test func othersAndWhoIsTalkingNow() {
        let t = SpeakerTimeline(app: "slack", spans: [.init(start: 10, end: 12, name: "Bill Ortiz")],
                                participants: ["Sam Lee", "Bill Ortiz", "Nora Hale"], selfName: "Sam Lee")
        #expect(t.others(at: 11).people == ["Bill Ortiz", "Nora Hale"])
        #expect(t.others(at: 11).speaking == "Bill Ortiz")
        #expect(t.others(at: 13).speaking == "Bill Ortiz")
        #expect(t.others(at: 20).speaking == nil)
        #expect(SpeakerTimeline(app: "meet").others(at: 0).people.isEmpty)
    }
}
