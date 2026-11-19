import Foundation

/// How the dictated text goes into the app in front. None of them use the
/// clipboard: the user's clipboard is left exactly as it was.
public enum InsertionMethod: Equatable, Sendable {
    /// Replace the focused field's selection through Accessibility. Exact and
    /// instant in native Cocoa apps.
    case accessibility
    /// Type the text as keystrokes. Works in browsers, Electron apps and
    /// terminals, whose fields ignore (or pretend to accept) the AX write.
    case keystrokes
    /// Do not put it anywhere; it stays in figg's history.
    case none(NotInsertedReason)
}

public enum NotInsertedReason: String, Equatable, Sendable {
    case passwordField
    case noPermission
    case noFocusedApp
}

/// What figg knows about the focused element when it is time to insert.
public struct FocusedField: Equatable, Sendable {
    public var bundleID: String?
    /// AXRole and AXSubrole of the focused element, when Accessibility can see one.
    public var role: String?
    public var subrole: String?

    public init(bundleID: String?, role: String? = nil, subrole: String? = nil) {
        self.bundleID = bundleID
        self.role = role
        self.subrole = subrole
    }

    public var isPasswordField: Bool {
        subrole == "AXSecureTextField" || role == "AXSecureTextField"
    }
}

/// Picks an insertion method. The AX write is tried first only in apps
/// where it is known to work; elsewhere figg types. A failed AX write falls
/// back to typing (see `TextInserter`).
public enum InsertionRouter {
    /// Apps whose text fields need typed keystrokes: browsers, Electron and
    /// other web-view apps, terminals. Matched as a bundle ID prefix.
    public static let keystrokeApps: [String] = [
        "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser",
        "org.mozilla.firefox", "com.operasoftware", "com.vivaldi", "com.apple.Safari",
        "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.microsoft.VSCode", "com.todesktop",
        "com.anthropic.claudefordesktop", "com.openai.chat", "md.obsidian", "notion.id",
        "com.figma.Desktop", "com.linear", "com.spotify.client", "us.zoom.xos", "com.microsoft.teams",
        "com.electron", "com.github.GitHubClient",
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "io.alacritty",
    ]

    public static func method(for field: FocusedField, trusted: Bool) -> InsertionMethod {
        guard trusted else { return .none(.noPermission) }
        guard let bundleID = field.bundleID else { return .none(.noFocusedApp) }
        if field.isPasswordField { return .none(.passwordField) }
        if keystrokeApps.contains(where: { bundleID.hasPrefix($0) }) { return .keystrokes }
        // No text element visible to AX: typing still reaches whatever has focus.
        guard field.role != nil else { return .keystrokes }
        return .accessibility
    }

    /// Whether a field's value after the AX write shows the text went in.
    /// Some fields report success and change nothing.
    public static func axWriteTookEffect(before: String?, after: String?, inserted: String) -> Bool {
        guard let after else { return false }
        if let before, before == after { return false }
        return after.contains(inserted)
    }
}

/// Splits text into pieces small enough for one synthetic key event.
/// CGEvent carries at most 20 UTF-16 units per event; pieces never split a
/// character (emoji, accented letters).
public enum KeystrokeChunks {
    public static func split(_ text: String, maxUTF16: Int = 20) -> [String] {
        var out: [String] = []
        var current = ""
        var units = 0
        for ch in text {
            let n = ch.utf16.count
            if units + n > maxUTF16, !current.isEmpty {
                out.append(current)
                current = ""
                units = 0
            }
            current.append(ch)
            units += n
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}

/// Final touches on transcribed text before it is inserted.
public enum DictationText {
    /// Joins segments, squeezes whitespace and adds a leading space when the
    /// text before the cursor ends in a letter or punctuation, so a second
    /// dictation does not run into the first.
    public static func prepare(_ segments: [String], precedingCharacter: Character? = nil) -> String {
        let joined = segments.joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !joined.isEmpty else { return "" }
        if let prev = precedingCharacter, !prev.isWhitespace, !"([{\"'".contains(prev) {
            return " " + joined
        }
        return joined
    }
}
