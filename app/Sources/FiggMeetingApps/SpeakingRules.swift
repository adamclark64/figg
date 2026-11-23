import Foundation

/// The "who is talking" and "am I muted" choices every profile shares, so
/// apps that show different cues still decide the same way.
public enum SpeakingRules {
    /// The remote person speaking now, strongest evidence first:
    ///
    /// 1. `cue`, the person the app itself marks as speaking, unless that is
    ///    you or they are muted.
    /// 2. You are known and exactly one other person is unmuted: any sound
    ///    on the call can only be theirs.
    /// 3. With `oneToOne`, you are known and there is exactly one other
    ///    person, not shown as muted. For apps that show no mute state.
    ///
    /// `people` is everyone read from the window, duplicates kept: two
    /// people with your name (a second device of yours) make "the others"
    /// unclear, so rules 2 and 3 then give nil.
    public static func speaking(cue: Participant?, people: [Participant], selfName: String?, oneToOne: Bool = false) -> String? {
        if let cue, cue.name != selfName, cue.muted != true { return cue.name }
        guard let selfName, people.filter({ $0.name == selfName }).count <= 1 else { return nil }
        var seen = Set<String>()
        let others = people.filter { $0.name != selfName && seen.insert($0.name).inserted }
        let unmuted = others.filter { $0.muted == false }
        if unmuted.count == 1 { return unmuted[0].name }
        if oneToOne, others.count == 1, others[0].muted != true { return others[0].name }
        return nil
    }

    /// One answer from several readings of the same thing (a toolbar button,
    /// your own tile): nil when two of them disagree, else the first that
    /// answers. A stray label can never be enough to say you are muted.
    public static func agree(_ answers: Bool?...) -> Bool? {
        let known = answers.compactMap { $0 }
        guard let first = known.first, known.allSatisfy({ $0 == first }) else { return nil }
        return first
    }
}
