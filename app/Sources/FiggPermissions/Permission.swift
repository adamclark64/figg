import Foundation

/// The macOS privacy permissions figg uses, in the order Settings lists them.
public enum Permission: String, CaseIterable, Identifiable, Sendable {
    case microphone
    case systemAudio
    case accessibility
    case calendar
    case screenRecording

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .microphone: "Microphone"
        case .systemAudio: "System Audio Recording"
        case .accessibility: "Accessibility"
        case .calendar: "Calendars"
        case .screenRecording: "Screen Recording"
        }
    }

    /// What figg does with it, in one line.
    public var purpose: String {
        switch self {
        case .microphone: "Records your side of the meeting, and dictation."
        case .systemAudio: "Records the other people on the call. Without it their side is silent."
        case .accessibility: "Dictation: notices the key in other apps and types the text. Also Zoom speaker names."
        case .calendar: "Meeting titles, attendee names and the brief before a meeting. Optional."
        case .screenRecording: "The widget's screenshot button. Optional."
        }
    }

    /// The name `tccutil reset` takes (kTCCService without the prefix).
    public var tccService: String {
        switch self {
        case .microphone: "Microphone"
        case .systemAudio: "AudioCapture"
        case .accessibility: "Accessibility"
        case .calendar: "Calendar"
        case .screenRecording: "ScreenCapture"
        }
    }

    /// The Privacy & Security pane that lists it.
    public var settingsURL: URL {
        let anchor = switch self {
        case .microphone: "Privacy_Microphone"
        case .systemAudio, .screenRecording: "Privacy_ScreenCapture"
        case .accessibility: "Privacy_Accessibility"
        case .calendar: "Privacy_Calendars"
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
    /// the switch in System Settings. `askedBefore` is true once figg has
    /// shown this prompt and it still reads as never asked: macOS reports an
    /// entry left by a differently signed copy that way (Screen Recording
    /// does), and asking again shows nothing, so the row offers Fix instead.
    public static func next(for status: PermissionStatus, fixedThisLaunch: Bool, askedBefore: Bool = false) -> PermissionStep {
        if fixedThisLaunch, status != .granted { return .openSettings }
        switch status {
        case .granted: return .none
        case .notAsked: return askedBefore ? .fix : .ask
        case .denied: return .fix
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

/// The permissions figg has shown a prompt for, kept between launches so a
/// prompt that macOS silently skips turns into Fix rather than another
/// Allow that does nothing. State, not a setting, so not config.yaml.
public struct AskedPermissions: Sendable {
    public let url: URL

    public init(in appSupport: URL) {
        url = appSupport.appendingPathComponent("asked-permissions.txt")
    }

    public func load() -> Set<Permission> {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Set(text.split(whereSeparator: \.isNewline).compactMap { Permission(rawValue: String($0)) })
    }

    public func record(_ permission: Permission) {
        var asked = load()
        guard asked.insert(permission).inserted else { return }
        let text = Permission.allCases.filter(asked.contains).map(\.rawValue).joined(separator: "\n")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
