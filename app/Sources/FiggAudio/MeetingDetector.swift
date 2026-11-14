import Foundation

/// Turns "which apps hold the mic" samples into meeting start/end prompts.
/// Pure logic (no Core Audio, no clock of its own) so it is unit-tested.
///
/// - Start: a non-ignored app has held the mic for `startDelay` while figg
///   is not recording. Prompted once per mic session: if the user says "not
///   now", the same app is not offered again until it releases the mic.
/// - End: figg is recording, and the app that held the mic when recording
///   began has released it for `endDelay`.
public struct MeetingDetector: Sendable {
    public enum Event: Equatable, Sendable {
        case started(app: String)
        case ended(app: String)
    }

    public var ignored: Set<String>
    public var startDelay: TimeInterval
    public var endDelay: TimeInterval

    /// When each app currently holding the mic was first seen.
    private var since: [String: Date] = [:]
    /// Apps already offered during their current mic session.
    private var offered: Set<String> = []
    /// The meeting app being recorded, and when it was last seen.
    private var meetingApp: String?
    private var meetingAppLastSeen: Date?
    private var endSent = false

    public static let defaultIgnored: Set<String> = [
        "dev.adamclark.figg",
        "com.FluidApp.app",                 // FluidVoice dictation
        "com.electron.wispr-flow",          // Wispr Flow dictation
        "com.apple.CoreSpeech", "com.apple.corespeechd",
        "com.apple.assistantd", "com.apple.Siri",
        "com.apple.SpeechRecognitionCore.speechrecognitiond",
        "com.apple.dictation", "com.apple.VoiceMemos",
    ]

    public init(ignored: Set<String> = defaultIgnored, startDelay: TimeInterval = 3, endDelay: TimeInterval = 10) {
        self.ignored = ignored
        self.startDelay = startDelay
        self.endDelay = endDelay
    }

    /// Feed one sample. Returns at most one event.
    public mutating func update(apps raw: Set<String>, isRecording: Bool, now: Date = Date()) -> Event? {
        let apps = raw.subtracting(ignored)

        for app in apps where since[app] == nil { since[app] = now }
        for app in Array(since.keys) where !apps.contains(app) {
            since[app] = nil
            offered.remove(app)  // a new mic session can be offered again
        }

        if isRecording {
            if meetingApp == nil {
                // Recording started (by prompt or by hand): follow the app holding the mic longest.
                meetingApp = apps.min { (since[$0] ?? now) < (since[$1] ?? now) }
                endSent = false
            }
            if let app = meetingApp {
                if apps.contains(app) {
                    meetingAppLastSeen = now
                } else if !endSent, now.timeIntervalSince(meetingAppLastSeen ?? now) >= endDelay {
                    endSent = true
                    return .ended(app: app)
                }
            }
            return nil
        }

        meetingApp = nil
        meetingAppLastSeen = nil
        let ready = apps
            .filter { !offered.contains($0) && now.timeIntervalSince(since[$0] ?? now) >= startDelay }
            .sorted()
        guard let app = ready.first else { return nil }
        offered.insert(app)
        return .started(app: app)
    }
}

public extension MeetingDetector {
    /// Browser and Electron helpers report their own bundle IDs
    /// (com.google.Chrome.helper); map them back to the app.
    static func parentBundleID(_ id: String) -> String {
        for suffix in [".helper.renderer", ".helper.Renderer", ".helper.plugin", ".helper", ".Helper"] where id.hasSuffix(suffix) {
            return String(id.dropLast(suffix.count))
        }
        return id
    }
}
