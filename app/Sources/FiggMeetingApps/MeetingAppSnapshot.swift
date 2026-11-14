import Foundation

/// One person shown in a meeting app's window.
public struct Participant: Sendable, Equatable, Codable {
    public var name: String
    /// nil when the app does not say.
    public var muted: Bool?

    public init(name: String, muted: Bool? = nil) {
        self.name = name
        self.muted = muted
    }
}

/// What a meeting app's window says at one moment: who is on the call and
/// who, if anyone, the app itself shows as talking.
public struct MeetingAppSnapshot: Sendable, Equatable {
    /// Short app id, e.g. "zoom".
    public var app: String
    public var participants: [Participant]
    /// The person at this Mac, as the app names them, if it says.
    public var selfName: String?
    /// The remote person the app shows as speaking, or nil when it is not clear.
    public var speaking: String?

    public init(app: String, participants: [Participant], selfName: String? = nil, speaking: String? = nil) {
        self.app = app
        self.participants = participants
        self.selfName = selfName
        self.speaking = speaking
    }
}

/// Reads one meeting app's window. A reader that cannot see a meeting (the
/// app is closed, no Accessibility permission, the window changed) returns
/// nil; it never throws, because names are a nice-to-have and must not get
/// in the way of recording.
public protocol MeetingAppReader: Sendable {
    func read() -> MeetingAppSnapshot?
}
