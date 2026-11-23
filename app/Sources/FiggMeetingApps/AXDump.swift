import AppKit
import Foundation

/// Saves what a profile sees of a running meeting app, for making test
/// fixtures: `open build/Figg.app --args --ax-dump <profile id>` (inside the
/// app, so figg's own Accessibility permission applies).
///
/// The dump is scrubbed before it is written: every `replacements` pair
/// ("Real Name" to "Person A") is applied to all text, `value` text (text
/// fields, captions, messages) becomes x's of the same length unless
/// `keepValues` or it is a short text holding a replaced name,
/// and URL paths keep their shape with letters and digits as x. It is
/// still for a person to read before it is committed: a name the
/// replacements missed stays in.
public enum AXDump {
    public static func path(for profileID: String) -> String { "/tmp/figg-ax-\(profileID).json" }

    /// Parses `--ax-dump <id> [--replace "Real=Fake"]... [--keep-values]`;
    /// nil when there is no `--ax-dump`.
    public static func arguments(_ args: [String]) -> (id: String, replacements: [(String, String)], keepValues: Bool)? {
        guard let i = args.firstIndex(of: "--ax-dump"), args.indices.contains(i + 1) else { return nil }
        var replacements: [(String, String)] = []
        for (j, a) in args.enumerated() where a == "--replace" && args.indices.contains(j + 1) {
            let pair = args[j + 1].split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2, !pair[0].isEmpty { replacements.append((pair[0], pair[1])) }
        }
        return (args[i + 1], replacements, args.contains("--keep-values"))
    }

    /// Captures with the profile, scrubs, and writes `path(for:)`. Returns a
    /// line saying what happened.
    @discardableResult
    public static func run(profileID: String, replacements: [(String, String)], keepValues: Bool = false,
                           registry: MeetingAppRegistry = MeetingAppRegistry()) -> String {
        guard let profile = registry.profile(id: profileID) else {
            return "no profile \"\(profileID)\"; known: \(registry.profiles.map(\.id).joined(separator: ", "))"
        }
        guard AccessibilityAccess.isGranted else { return "figg has no Accessibility permission" }
        guard let capture = AccessibilityMeetingReader(profile: profile).capture() else {
            return "\(profile.displayName): no meeting window found (is the app running, with a call open?)"
        }
        let clean = scrub(capture, replacements: replacements, keepValues: keepValues)
        do {
            try clean.encoded().write(to: URL(fileURLWithPath: path(for: profileID)), options: .atomic)
        } catch {
            return "could not write \(path(for: profileID)): \(error.localizedDescription)"
        }
        let count = clean.tree.all().count
        let snapshot = profile.snapshot(from: clean).map { "\($0.participants.count) participants, speaking: \($0.speaking ?? "none"), self muted: \($0.selfMuted.map(String.init) ?? "unknown")" } ?? "no snapshot"
        return "wrote \(path(for: profileID)): \(count) nodes; \(snapshot). Read it before committing it."
    }

    public static func scrub(_ capture: MeetingAppCapture, replacements: [(String, String)], keepValues: Bool) -> MeetingAppCapture {
        func text(_ s: String?) -> String? {
            guard var s else { return nil }
            for (real, fake) in replacements { s = s.replacingOccurrences(of: real, with: fake) }
            return s
        }
        func node(_ n: AXNode) -> AXNode {
            var n = n
            n.title = text(n.title)
            n.description = text(n.description)
            n.roleDescription = text(n.roleDescription)
            n.identifier = text(n.identifier)
            n.domID = text(n.domID)
            // Values are blanked, except a short one that was a replaced name
            // (static text holds names in its value, and fixtures need them).
            let value = text(n.value)
            let isName = value.map { v in v.count <= 60 && replacements.contains { v.contains($0.1) } } ?? false
            n.value = keepValues || isName ? value : n.value.map(blank)
            n.url = n.url.map(scrubURL)
            n.children = n.children.map(node)
            return n
        }
        var out = capture
        out.tree = node(capture.tree)
        out.otherWindows = capture.otherWindows.map(node)
        return out
    }

    static func blank(_ s: String) -> String {
        String(s.map { $0.isWhitespace ? $0 : "x" })
    }

    /// Keeps scheme and host, so a profile can still match the URL, and
    /// turns the path's letters and digits into x (a meeting code stays
    /// "xxx-xxxx-xxx"). Query and fragment are dropped.
    static func scrubURL(_ s: String) -> String {
        guard let c = URLComponents(string: s), let scheme = c.scheme, let host = c.host else { return blank(s) }
        let path = String(c.path.map { $0.isLetter || $0.isNumber ? "x" : $0 })
        return "\(scheme)://\(host)\(path)"
    }
}
