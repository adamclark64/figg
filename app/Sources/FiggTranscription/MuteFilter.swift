import FiggMeetingApps
import FiggStore
import Foundation

/// Leaves out what the mic heard while you were muted in the meeting app.
///
/// Zoom's mute only stops Zoom sending your voice; figg's mic still hears
/// the room. When you mute to talk to someone beside you, that talk is not
/// part of the meeting, so mic lines that fall mostly inside a muted
/// stretch are dropped. A line only partly muted (a reply that starts a
/// moment before Zoom shows you unmuted) is kept whole. Call audio ("Them")
/// is never dropped.
///
/// With no muted stretches every function returns its input unchanged.
public enum MuteFilter {
    /// Share of a mic line that must be muted for it to be dropped.
    public static let minShare = 0.5

    /// True for a mic line at least `minShare` inside the muted stretches.
    public static func isMuted(_ line: TranscriptLine, timeline: SpeakerTimeline) -> Bool {
        line.speaker == .me && timeline.mutedShare(start: line.start, end: line.end) >= minShare
    }

    /// The lines without the muted mic lines.
    public static func drop(_ lines: [TranscriptLine], muted: SpeakerTimeline?) -> [TranscriptLine] {
        guard let muted, !muted.muted.isEmpty else { return lines }
        return lines.filter { !isMuted($0, timeline: muted) }
    }

    /// The turns with their muted parts cut out (a turn can split in two or
    /// vanish). Used only to choose which mic voice is "Me", so talk while
    /// muted does not count towards it.
    /// - Parameter offset: converts turn times to meeting time, as in
    ///   `SpeakerLabels.apply`.
    public static func unmutedTurns(_ turns: [SpeakerTurn], muted: SpeakerTimeline?, offset: Double) -> [SpeakerTurn] {
        guard let muted, !muted.muted.isEmpty else { return turns }
        let stretches = muted.muted
            .map { (start: $0.start - offset, end: $0.end - offset) }
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }
        var out: [SpeakerTurn] = []
        for turn in turns {
            var from = turn.start
            for s in stretches where s.end > from && s.start < turn.end {
                if s.start > from { out.append(SpeakerTurn(start: from, end: s.start, speaker: turn.speaker)) }
                from = max(from, s.end)
            }
            if turn.end > from { out.append(SpeakerTurn(start: from, end: turn.end, speaker: turn.speaker)) }
        }
        return out
    }
}
