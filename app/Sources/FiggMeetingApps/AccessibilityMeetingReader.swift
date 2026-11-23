import AppKit
import ApplicationServices
import Foundation

/// Reads one meeting app through macOS Accessibility using a
/// `MeetingAppProfile`: finds the profile's target window (or web area),
/// copies it with `AXTreeCapture`, and lets the profile make the snapshot.
/// Without Accessibility permission, the app, or a meeting window, `read()`
/// returns nil. Nothing leaves the Mac: this only copies labels the app
/// already shows on screen.
public struct AccessibilityMeetingReader: MeetingAppReader {
    public let profile: MeetingAppProfile
    /// The app to read; nil reads the first running app the profile supports.
    public let bundleID: String?

    public init(profile: MeetingAppProfile, bundleID: String? = nil) {
        self.profile = profile
        self.bundleID = bundleID
    }

    public func read() -> MeetingAppSnapshot? {
        capture().flatMap(profile.snapshot(from:))
    }

    /// The copy the profile would see now, or nil. Also used by `--ax-dump`.
    public func capture() -> MeetingAppCapture? {
        guard AXIsProcessTrusted(), let app = runningApp() else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        // A hung app must not hang the poll: give up on any call after 250 ms.
        AXUIElementSetMessagingTimeout(root, 0.25)
        // Asks Chromium and Electron to build their web Accessibility tree;
        // a no-op once it is on.
        for name in profile.accessibilitySwitches(for: app.bundleIdentifier ?? "") {
            AXUIElementSetAttributeValue(root, name as CFString, kCFBooleanTrue)
        }
        let policy = profile.policy
        let windows = AXTreeCapture.windows(of: root, findsWebAreas: policy.findsWebAreas)
        guard let target = profile.target(in: windows.summaries), let element = windows.element(for: target) else { return nil }
        let origin = AX.position(element)
        let tree = AXTreeCapture.copy(element, policy: policy, origin: origin)
        var others: [AXNode] = []
        if let depth = policy.otherWindowsDepth {
            let targetWindow: Int
            switch target {
            case .window(let i), .webArea(let i, _): targetWindow = i
            }
            let shallow = CapturePolicy(maxNodes: 200, maxDepth: depth)
            for (i, w) in windows.elements.enumerated() where i != targetWindow {
                others.append(AXTreeCapture.copy(w, policy: shallow, origin: AX.position(w)))
            }
        }
        let size = AX.size(element)
        return MeetingAppCapture(tree: tree, width: size.width, height: size.height, otherWindows: others)
    }

    private func runningApp() -> NSRunningApplication? {
        if let bundleID {
            return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        }
        for id in profile.bundleIDs.sorted() {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first { return app }
        }
        return nil
    }
}

extension MeetingAppRegistry {
    /// Picks the meeting to watch from what is open on this Mac now: the
    /// running apps, and each candidate's windows read through
    /// Accessibility (only titles, identifiers and web area URLs). Slow
    /// apps cost up to 250 ms a call, so call it off the main thread.
    /// Sets each candidate's web accessibility switch first; Chromium needs
    /// about 2 s after that, so an early miss is worth retrying.
    public func chooseRunning(micHolders: [String], enabled: Set<String>) -> Choice? {
        guard AXIsProcessTrusted() else { return nil }
        let supported = profiles.filter { enabled.contains($0.id) }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
            .filter { id in supported.contains { $0.reads(bundleID: id) } })
        return choose(micHolders: micHolders, running: running, enabled: enabled) { bundleID, profile in
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return [] }
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.25)
            for name in profile.accessibilitySwitches(for: bundleID) {
                AXUIElementSetAttributeValue(root, name as CFString, kCFBooleanTrue)
            }
            return AXTreeCapture.windows(of: root, findsWebAreas: profile.policy.findsWebAreas).summaries
        }
    }

    /// The display name of the first enabled meeting app running now, for
    /// the Accessibility banner (which cannot look inside windows yet).
    public func runningAppName(micHolders: [String], enabled: Set<String>) -> String? {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let usable = profiles.filter { enabled.contains($0.id) }
        for holder in micHolders.map(Self.owningApp) {
            if let p = usable.first(where: { $0.reads(bundleID: holder) }) { return p.displayName }
        }
        // Browsers, Slack and Teams stay open all day, so only Zoom running
        // is a sign of a meeting on its own (as before other apps existed).
        return usable.first { p in p.id == "zoom" && running.contains { p.reads(bundleID: $0) } }?.displayName
    }
}
