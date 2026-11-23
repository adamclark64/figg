/// Decides whether figg watches a meeting app's window during a recording,
/// and what the one-time Accessibility banner says. Two settings need the
/// watcher (naming speakers, and skipping the mic while muted), so the rule
/// and the banner wording live here, where they are tested, rather than in
/// AppModel.
public enum MeetingAppWatch {
    public struct Plan: Equatable, Sendable {
        /// Start the watcher at all.
        public var start: Bool
        /// Read names (participants, the speaker, the self name), not only mute state.
        public var names: Bool
        /// The banner shown once when Accessibility is missing; nil when nothing needs it.
        public var bannerText: String?

        public init(start: Bool, names: Bool, bannerText: String?) {
            self.start = start
            self.names = names
            self.bannerText = bannerText
        }
    }

    static func namesText(_ app: String) -> String {
        "figg can put \(app)'s names on the people talking, instead of \"Them 1\", \"Them 2\". It needs Accessibility permission to read \(app)'s window; nothing leaves this Mac."
    }

    static func muteText(_ app: String) -> String {
        "figg can leave out what your mic hears while you are muted on \(app). It needs Accessibility permission to read \(app)'s window; nothing leaves this Mac."
    }

    static func bothText(_ app: String) -> String {
        "figg can put \(app)'s names on the people talking and leave out what your mic hears while you are muted on \(app). It needs Accessibility permission to read \(app)'s window; nothing leaves this Mac."
    }

    /// `names` is `transcription.meeting_app_names`, `skipMuted` is
    /// `transcription.skip_mic_when_muted`. Either one starts the watcher.
    /// `app` is the meeting app's display name, for the banner.
    public static func plan(names: Bool, skipMuted: Bool, app: String = "Zoom") -> Plan {
        switch (names, skipMuted) {
        case (true, true): return Plan(start: true, names: true, bannerText: bothText(app))
        case (true, false): return Plan(start: true, names: true, bannerText: namesText(app))
        case (false, true): return Plan(start: true, names: false, bannerText: muteText(app))
        case (false, false): return Plan(start: false, names: false, bannerText: nil)
        }
    }
}
