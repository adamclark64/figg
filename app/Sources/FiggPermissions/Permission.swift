import Foundation

/// The macOS privacy permissions figg uses, in the order Settings lists them.
public enum Permission: String, CaseIterable, Identifiable, Sendable {
    case microphone
    case systemAudio
    case accessibility
    case screenRecording

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .microphone: "Microphone"
        case .systemAudio: "System Audio Recording"
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        }
    }

    /// What figg does with it, in one line.
    public var purpose: String {
        switch self {
        case .microphone: "Records your side of the meeting, and dictation."
        case .systemAudio: "Records the other people on the call. Without it their side is silent."
        case .accessibility: "Dictation: notices the key in other apps and types the text. Also Zoom speaker names."
        case .screenRecording: "The widget's screenshot button. Optional."
        }
    }

    /// The name `tccutil reset` takes (kTCCService without the prefix).
    public var tccService: String {
        switch self {
        case .microphone: "Microphone"
        case .systemAudio: "AudioCapture"
        case .accessibility: "Accessibility"
        case .screenRecording: "ScreenCapture"
        }
    }

    /// The Privacy & Security pane that lists it.
    public var settingsURL: URL {
        let anchor = switch self {
        case .microphone: "Privacy_Microphone"
        case .systemAudio, .screenRecording: "Privacy_ScreenCapture"
        case .accessibility: "Privacy_Accessibility"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    /// macOS only applies these to a running app after it is reopened.
    public var needsRelaunch: Bool { self == .screenRecording || self == .systemAudio }
}

public enum PermissionStatus: Equatable, Sendable {
    case granted
    /// Never asked, so asking shows macOS's prompt.
    case notAsked
    /// Refused, switched off, or held by an entry macOS no longer matches to
    /// this copy of figg. These look the same from inside the app.
    case denied
}

/// The one button a permission row shows.
public enum PermissionStep: Equatable, Sendable {
    case none
    /// Show macOS's prompt.
    case ask
    /// Clear figg's entry for this permission, then ask again. This is what
    /// fixes an entry left from a differently signed copy, which System
    /// Settings shows as on while macOS refuses it.
    case fix
    /// The prompt has had its turn; the switch is in System Settings.
    case openSettings

    public var label: String {
        switch self {
        case .none: ""
        case .ask: "Allow"
        case .fix: "Fix"
        case .openSettings: "Open System Settings"
        }
    }

    /// Picks the step for a row. `fixedThisLaunch` is true once this row's
    /// fix has run: asking again would only repeat it, so the next step is
    /// the switch in System Settings.
    public static func next(for status: PermissionStatus, fixedThisLaunch: Bool) -> PermissionStep {
        switch status {
        case .granted: .none
        case .notAsked: fixedThisLaunch ? .openSettings : .ask
        case .denied: fixedThisLaunch ? .openSettings : .fix
        }
    }
}

/// The `tccutil` command that clears one permission for one app. Only figg's
/// own bundle ID is ever passed, so nothing else's permissions change.
public struct PermissionReset: Equatable, Sendable {
    public let executable = "/usr/bin/tccutil"
    public let arguments: [String]

    public init(_ permission: Permission, bundleID: String) {
        arguments = ["reset", permission.tccService, bundleID]
    }
}
