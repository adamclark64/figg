import AppKit
import ApplicationServices
import Foundation

/// Reads the Zoom desktop app's meeting window through macOS Accessibility.
/// Needs the Accessibility permission; without it, or without a Zoom
/// meeting open, `read()` returns nil. Nothing is sent anywhere: this only
/// looks at labels Zoom already shows on screen.
///
/// Besides the video tiles it collects the buttons whose label starts with
/// "Mute" or "Unmute", so `ZoomReading` can tell whether you are muted.
///
/// Zoom's window layout is not a public API and can change with any Zoom
/// update, so every miss is treated as "no names right now".
public struct ZoomReader: MeetingAppReader {
    public static let bundleID = "us.zoom.xos"
    /// The meeting window's AXIdentifier (stable across title changes like "Zoom Meeting  40-minutes").
    static let meetingWindowID = "zm.meeting.window.main"

    public init() {}

    public func read() -> MeetingAppSnapshot? {
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        // A hung Zoom must not hang the poll: give up on any call after 250 ms.
        AXUIElementSetMessagingTimeout(root, 0.25)
        let windows: [AXUIElement] = AX.value(root, kAXWindowsAttribute) ?? []
        guard let meeting = windows.first(where: { AX.string($0, "AXIdentifier") == Self.meetingWindowID }) else { return nil }

        var tiles: [ZoomReading.Tile] = []
        var buttons: [ZoomReading.Button] = []
        let windowTop = AX.position(meeting).y
        var visited = 0
        func walk(_ e: AXUIElement, depth: Int, inPanel: Bool) {
            visited += 1
            // Zoom's toolbar buttons nest inside themselves; cap the walk.
            guard visited < 4000 else { return }
            if let rd = AX.string(e, kAXRoleDescriptionAttribute), rd.hasPrefix("Video") {
                if let label = AX.string(e, kAXDescriptionAttribute) {
                    let size = AX.size(e)
                    tiles.append(.init(label: label, width: size.width, height: size.height))
                }
                return
            }
            let description = AX.string(e, kAXDescriptionAttribute)
            let title = AX.string(e, kAXTitleAttribute)
            if AX.string(e, kAXRoleAttribute) == (kAXButtonRole as String) {
                // The position is only needed for a possible mute button.
                if let label = description ?? title, ZoomReading.isMuteLabel(label) {
                    buttons.append(.init(label: label, y: AX.position(e).y - windowTop, inParticipantsPanel: inPanel))
                }
                // A button's children repeat its own label; do not descend.
                return
            }
            let panel = inPanel || [description, title].contains { $0?.hasPrefix("Participants") == true }
            guard depth < 8, let kids: [AXUIElement] = AX.value(e, kAXChildrenAttribute) else { return }
            for k in kids { walk(k, depth: depth + 1, inPanel: panel) }
        }
        walk(meeting, depth: 0, inPanel: false)
        let window = AX.size(meeting)
        return ZoomReading.snapshot(tiles: tiles, windowWidth: window.width, windowHeight: window.height,
                                    selfName: selfName(windows), buttons: buttons)
    }

    /// Your Zoom name from the main window's account button, if it is shown.
    private func selfName(_ windows: [AXUIElement]) -> String? {
        for w in windows where AX.string(w, "AXIdentifier") != Self.meetingWindowID {
            let kids: [AXUIElement] = AX.value(w, kAXChildrenAttribute) ?? []
            for k in kids {
                if let d = AX.string(k, kAXDescriptionAttribute), let name = ZoomReading.selfName(fromAccountButton: d) { return name }
            }
        }
        return nil
    }
}

/// Whether figg may read other apps' windows, and asking for it.
public enum AccessibilityAccess {
    public static var isGranted: Bool { AXIsProcessTrusted() }

    /// Shows macOS's own prompt (once per app) that opens Privacy & Security >
    /// Accessibility, and adds figg to that list.
    public static func request() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    public static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Small typed wrappers over the AX C API.
enum AX {
    static func value<T>(_ e: AXUIElement, _ attribute: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success else { return nil }
        return v as? T
    }

    static func string(_ e: AXUIElement, _ attribute: String) -> String? {
        let s: String? = value(e, attribute)
        return s?.isEmpty == false ? s : nil
    }

    /// Top-left corner in screen points (y grows downwards), or zero.
    static func position(_ e: AXUIElement) -> CGPoint {
        var v: CFTypeRef?
        var point = CGPoint.zero
        if AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &v) == .success, let v,
           CFGetTypeID(v) == AXValueGetTypeID() {
            AXValueGetValue(v as! AXValue, .cgPoint, &point)
        }
        return point
    }

    static func size(_ e: AXUIElement) -> CGSize {
        var v: CFTypeRef?
        var size = CGSize.zero
        if AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &v) == .success, let v,
           CFGetTypeID(v) == AXValueGetTypeID() {
            AXValueGetValue(v as! AXValue, .cgSize, &size)
        }
        return size
    }
}
