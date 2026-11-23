import Foundation

/// Reads the Zoom desktop app's meeting window through macOS Accessibility:
/// `AccessibilityMeetingReader` with `ZoomProfile`. Kept as a name because
/// the app starts Zoom watching through it.
///
/// Zoom's window layout is not a public API and can change with any Zoom
/// update, so every miss is treated as "no names right now".
public struct ZoomReader: MeetingAppReader {
    public static let bundleID = ZoomProfile.bundleID
    private let reader = AccessibilityMeetingReader(profile: ZoomProfile(), bundleID: ZoomProfile.bundleID)

    public init() {}

    public func read() -> MeetingAppSnapshot? { reader.read() }
}
