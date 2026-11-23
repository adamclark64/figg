import Foundation

/// Picks which meeting app to watch for a recording. Pure: the caller gives
/// it the apps holding the mic, the running apps and a way to summarise an
/// app's windows, so the choice is tested without any app open.
public struct MeetingAppRegistry: Sendable {
    /// In fallback order (used when nothing on the mic is a meeting app).
    public var profiles: [MeetingAppProfile]

    /// Every profile figg ships.
    public static let all: [MeetingAppProfile] = [ZoomProfile(), TeamsProfile(), MeetProfile(), SlackHuddleProfile()]

    public init(profiles: [MeetingAppProfile] = MeetingAppRegistry.all) {
        self.profiles = profiles
    }

    public struct Choice: Sendable {
        public var profile: MeetingAppProfile
        /// The app to read: for a web meeting, which browser.
        public var bundleID: String
        public var target: AXTarget
    }

    public func profile(id: String) -> MeetingAppProfile? {
        profiles.first { $0.id == id }
    }

    /// The bundle ID of the app a helper process belongs to: Chromium
    /// browsers and Electron apps hold the mic from a helper such as
    /// "com.google.Chrome.helper" or "com.google.Chrome.helper.Renderer".
    public static func owningApp(of bundleID: String) -> String {
        // Only a whole ".helper" component counts, so "com.example.helperapp" stays.
        let parts = bundleID.split(separator: ".", omittingEmptySubsequences: false)
        guard let i = parts.firstIndex(where: { $0.lowercased() == "helper" }), i > 0 else { return bundleID }
        return parts[..<i].joined(separator: ".")
    }

    /// The meeting to watch, or nil.
    ///
    /// 1. Apps holding the mic, in the order given (longest-held first when
    ///    the caller knows it), each mapped from a helper to its app: the
    ///    first enabled profile that reads that app and finds a meeting in
    ///    its windows wins.
    /// 2. Nothing on the mic is a meeting (recording started by hand, or a
    ///    call not joined yet): the first profile, in `profiles` order, with
    ///    a running app that shows a meeting.
    ///
    /// - Parameters:
    ///   - enabled: profile ids figg may read (`transcription.meeting_apps`).
    ///   - windows: summaries of a running app's windows, for `profile`'s
    ///     needs (web areas only when it reads web content).
    public func choose(micHolders: [String], running: Set<String>, enabled: Set<String>,
                       windows: (_ bundleID: String, _ profile: MeetingAppProfile) -> [AXWindowSummary]) -> Choice? {
        let usable = profiles.filter { enabled.contains($0.id) }
        var tried = Set<String>()
        func attempt(_ profile: MeetingAppProfile, _ app: String) -> Choice? {
            guard tried.insert(profile.id + "|" + app.lowercased()).inserted else { return nil }
            return profile.target(in: windows(app, profile)).map { Choice(profile: profile, bundleID: app, target: $0) }
        }
        for holder in micHolders {
            let app = Self.owningApp(of: holder)
            for p in usable where p.reads(bundleID: app) {
                if let c = attempt(p, app) { return c }
            }
        }
        for p in usable {
            for app in running.sorted() where p.reads(bundleID: app) {
                if let c = attempt(p, app) { return c }
            }
        }
        return nil
    }
}
