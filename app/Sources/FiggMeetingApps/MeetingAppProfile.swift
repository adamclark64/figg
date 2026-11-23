import Foundation

/// One meeting app figg knows how to read: which running app and which of
/// its windows is the meeting, and how to turn a copy of that window into a
/// `MeetingAppSnapshot`. Pure (no Accessibility calls), so each profile is
/// tested on captured trees. `AccessibilityMeetingReader` does the copying.
///
/// Adding an app is one type conforming to this, plus fixtures; the watcher,
/// the timeline and the final pass take any profile's snapshots as they are.
public protocol MeetingAppProfile: Sendable {
    /// Short id saved in `speakers.json` and used in config ("zoom", "meet").
    var id: String { get }
    /// Shown to people: banners, Settings ("Zoom", "Google Meet").
    var displayName: String { get }
    /// Apps this profile can read. A web meeting lists every browser it supports.
    var bundleIDs: Set<String> { get }
    /// Chromium and Electron apps keep web content out of Accessibility
    /// until a client sets AXManualAccessibility; true makes the reader set it.
    var needsWebAccessibility: Bool { get }
    /// How much of the target to copy, and where positions are needed.
    var policy: CapturePolicy { get }
    /// The part of the app to copy, or nil when no window is a meeting.
    /// This is what keeps figg to the meeting's own window: nothing that is
    /// not the returned target is copied.
    func target(in windows: [AXWindowSummary]) -> AXTarget?
    /// What the window says now, or nil when it is not a meeting screen this
    /// profile understands. Never throws: a miss is a gap in the timeline.
    func snapshot(from capture: MeetingAppCapture) -> MeetingAppSnapshot?
}

extension MeetingAppProfile {
    public var needsWebAccessibility: Bool { false }

    /// Whether this profile reads the app with this bundle ID, ignoring case
    /// (helper processes are sometimes reported in lower case).
    public func reads(bundleID: String) -> Bool {
        bundleIDs.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }
}
