import FiggMeetingApps
import FiggStore
@testable import FiggTranscription
import Foundation
import Testing

@Suite struct MuteFilterTests {
    /// Muted from 10 s to 20 s of the recording.
    let timeline = SpeakerTimeline(app: "zoom", muted: [.init(start: 10, end: 20)])

    func line(_ speaker: Speaker, _ start: Double, _ end: Double, _ text: String = "sample words") -> TranscriptLine {
        TranscriptLine(meetingId: "m", speaker: speaker, start: start, end: end, text: text)
    }

    @Test func micLinesAtLeastHalfMutedAreMuted() {
        #expect(MuteFilter.isMuted(line(.me, 12, 15), timeline: timeline))        // inside
        #expect(MuteFilter.isMuted(line(.me, 8, 12), timeline: timeline))         // exactly half
        #expect(MuteFilter.isMuted(line(.me, 18, 21), timeline: timeline))        // two thirds
        #expect(!MuteFilter.isMuted(line(.me, 7, 11), timeline: timeline))        // a quarter
        #expect(!MuteFilter.isMuted(line(.me, 21, 25), timeline: timeline))       // outside
        #expect(!MuteFilter.isMuted(line(.me, 12, 12), timeline: timeline))       // zero length
    }

    @Test func callAudioIsNeverMuted() {
        for (start, end) in [(12.0, 15.0), (8.0, 12.0), (18.0, 21.0), (7.0, 11.0), (21.0, 25.0)] {
            #expect(!MuteFilter.isMuted(line(.them, start, end), timeline: timeline))
        }
    }

    @Test func dropKeepsCallLinesAndUnmutedMicLines() {
        let lines = [
            line(.me, 2, 5, "before"),
            line(.me, 12, 15, "inside"),
            line(.them, 12, 15, "call inside"),
            line(.me, 8, 12, "half"),
            line(.me, 7, 11, "a quarter"),
            line(.them, 18, 21, "call partly"),
            line(.me, 22, 25, "after"),
        ]
        let kept = MuteFilter.drop(lines, muted: timeline)
        #expect(kept.map(\.text) == ["before", "call inside", "a quarter", "call partly", "after"])
    }

    @Test func noStretchesReturnInputUnchanged() {
        let lines = [line(.me, 12, 15), line(.them, 12, 15)]
        #expect(MuteFilter.drop(lines, muted: nil) == lines)
        #expect(MuteFilter.drop(lines, muted: SpeakerTimeline(app: "zoom", spans: [.init(start: 0, end: 30, name: "Nora")])) == lines)
        let turns = [SpeakerTurn(start: 0, end: 30, speaker: "A")]
        #expect(MuteFilter.unmutedTurns(turns, muted: nil, offset: 0) == turns)
        #expect(MuteFilter.unmutedTurns(turns, muted: SpeakerTimeline(app: "zoom"), offset: 0) == turns)
    }

    @Test func unmutedTurnsSplitAndRemoveTurns() {
        let turns = [
            SpeakerTurn(start: 0, end: 30, speaker: "A"),     // split around the stretch
            SpeakerTurn(start: 12, end: 18, speaker: "B"),    // wholly muted: removed
            SpeakerTurn(start: 5, end: 15, speaker: "C"),     // cut at the stretch start
            SpeakerTurn(start: 18, end: 25, speaker: "D"),    // cut at the stretch end
            SpeakerTurn(start: 21, end: 24, speaker: "E"),    // untouched
        ]
        #expect(MuteFilter.unmutedTurns(turns, muted: timeline, offset: 0) == [
            SpeakerTurn(start: 0, end: 10, speaker: "A"),
            SpeakerTurn(start: 20, end: 30, speaker: "A"),
            SpeakerTurn(start: 5, end: 10, speaker: "C"),
            SpeakerTurn(start: 20, end: 25, speaker: "D"),
            SpeakerTurn(start: 21, end: 24, speaker: "E"),
        ])
    }

    @Test func unmutedTurnsUseTheOffsetAndSeveralStretches() {
        let twice = SpeakerTimeline(app: "zoom", muted: [.init(start: 102, end: 104), .init(start: 106, end: 108)])
        // Turn times are from 100 s of meeting time.
        let turns = [SpeakerTurn(start: 0, end: 10, speaker: "A")]
        #expect(MuteFilter.unmutedTurns(turns, muted: twice, offset: 100) == [
            SpeakerTurn(start: 0, end: 2, speaker: "A"),
            SpeakerTurn(start: 4, end: 6, speaker: "A"),
            SpeakerTurn(start: 8, end: 10, speaker: "A"),
        ])
    }
}
