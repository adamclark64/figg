import Foundation

/// The three kinds of report the sheet offers. Raw values double as GitHub
/// labels on the filed issue, so they must stay `bug` / `enhancement` /
/// `question` (GitHub's default label names).
public enum ReportType: String, Codable, CaseIterable, Equatable, Sendable {
    case bug
    case enhancement
    case question

    /// Tab title in the sheet.
    public var tabLabel: String {
        switch self {
        case .bug: return "Bug"
        case .enhancement: return "Feature"
        case .question: return "Question"
        }
    }

    /// Sheet heading while composing.
    public var heading: String {
        switch self {
        case .bug: return "Report a bug"
        case .enhancement: return "Request a feature"
        case .question: return "Question / feedback"
        }
    }

    /// Label above the description field.
    public var fieldLabel: String {
        switch self {
        case .bug: return "What happened?"
        case .enhancement: return "What would you like?"
        case .question: return "Your message"
        }
    }

    /// Placeholder and hint text for the description field.
    public var prompt: String {
        switch self {
        case .bug: return "Describe the bug, what you expected, and how to reproduce it"
        case .enhancement: return "Describe the feature or improvement you'd like to see"
        case .question: return "Ask your question or share your feedback"
        }
    }

    /// Issue title prefix, matching what the relay writes.
    public var titlePrefix: String {
        switch self {
        case .bug: return "[Figg bug]"
        case .enhancement: return "[Feature request]"
        case .question: return "[Question]"
        }
    }
}

/// One downscaled screenshot, ready to send. `base64` is a full data URL
/// (`data:image/jpeg;base64,...`), the shape the relay accepts.
public struct Screenshot: Codable, Equatable, Sendable {
    public var name: String
    public var mime: String
    public var base64: String

    public init(name: String, mime: String, base64: String) {
        self.name = name
        self.mime = mime
        self.base64 = base64
    }
}

/// One report: what the issue link is built from, and the JSON body POSTed
/// to a relay when one is set. App context goes in `appVersion` and `extra`.
/// Privacy rule: `extra` never carries meeting content, transcripts, titles
/// or calendar data.
public struct BugReportPayload: Codable, Equatable, Sendable {
    public var type: ReportType
    public var description: String
    public var email: String
    public var appVersion: String
    public var extra: [String: String]
    public var screenshots: [Screenshot]

    public init(type: ReportType, description: String, email: String = "",
                appVersion: String = "", extra: [String: String] = [:],
                screenshots: [Screenshot] = []) {
        self.type = type
        self.description = description
        self.email = email
        self.appVersion = appVersion
        self.extra = extra
        self.screenshots = screenshots
    }

    public static let maxScreenshots = 3

    /// The relay's error code for an invalid payload, or nil when sendable.
    /// Using the relay's own codes keeps one message map for both sides.
    public var validationErrorCode: String? {
        if description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "missing_description"
        }
        if screenshots.count > Self.maxScreenshots { return "too_many_screenshots" }
        return nil
    }
}

/// Maps the relay's error codes to what the sheet shows. Codes come from
/// relay/api/bug-report.js; unknown codes get the generic line.
public enum BugReportErrorMessage {
    public static func message(for code: String?) -> String {
        switch code {
        case "bug_reporting_unconfigured":
            return "Bug reporting isn't configured yet (missing GitHub token). Try again later."
        case "screenshot_too_large":
            return "A screenshot is too large. Please attach smaller images."
        case "too_many_screenshots":
            return "Attach at most \(BugReportPayload.maxScreenshots) screenshots."
        case "screenshots_must_be_images":
            return "Only image files can be attached."
        case "missing_description":
            return "Please describe the issue."
        case "rate_limited":
            return "Too many reports in a short time. Please try again later."
        default:
            return "Something went wrong filing the report. Please try again."
        }
    }

    public static let networkFailure = "Couldn't reach the server. Please try again."

    /// A pasted or copied picture the decoder could not read.
    public static let unreadableImage = "Couldn't read that image. Try a PNG or JPEG."
}

/// Builds the prefilled new-issue link that Report a Bug opens in the
/// browser. This is how a report is filed unless someone hosts the relay: it
/// needs no setup and no token, and the reporter reads the issue before
/// submitting it. A link cannot hold a picture; `ScreenshotHandoff` carries
/// the screenshots.
public enum GitHubIssueURL {
    public static let defaultRepo = "adamclark64/figg"

    /// GitHub answers a longer link with an error page, so a long
    /// description is cut to fit.
    public static let maxLength = 6000

    /// The Report a Bug window stays open after a cut with the whole report
    /// (`fullBody`) on the clipboard, so the note can point back at it.
    static let cutNote = "\n\n_(Cut short to fit in a link. The full report is on your clipboard: select everything here and paste over it. figg's Report a Bug window can copy it again.)_"

    /// The longest title GitHub is sent, in bytes. A first line of emoji or
    /// stacked accents is short in characters and long in the link.
    static let maxTitleBytes = 300

    /// A new-issue link, and whether the description was cut to make it.
    public struct Link: Equatable, Sendable {
        public var url: URL
        public var wasCut: Bool
    }

    /// The issue template in `.github/ISSUE_TEMPLATE` for a report type.
    /// The template is what labels the issue. The link carries no `labels`
    /// of its own: GitHub only takes those from someone who can already
    /// label issues in the repo.
    public static func template(for type: ReportType) -> String {
        switch type {
        case .bug: return "bug.md"
        case .enhancement: return "feature.md"
        case .question: return "question.md"
        }
    }

    public static func url(for payload: BugReportPayload, repo: String = defaultRepo) -> URL {
        link(for: payload, repo: repo).url
    }

    public static func link(for payload: BugReportPayload, repo: String = defaultRepo) -> Link {
        let whole = build(payload, description: payload.description, repo: repo)
        guard whole.absoluteString.utf8.count > maxLength else { return Link(url: whole, wasCut: false) }
        // What a character adds to the link depends on the text: one byte
        // for a Latin letter, nine for a Japanese one, more for an emoji.
        // So search for the longest start of the text that fits, not guess.
        let characters = Array(payload.description)
        var fits = 0
        var tooLong = characters.count
        var best = build(payload, description: cutNote, repo: repo)
        while tooLong - fits > 1 {
            let middle = (fits + tooLong) / 2
            let candidate = build(payload, description: String(characters[..<middle]) + cutNote, repo: repo)
            if candidate.absoluteString.utf8.count <= maxLength {
                fits = middle
                best = candidate
            } else {
                tooLong = middle
            }
        }
        return Link(url: best, wasCut: true)
    }

    /// The whole issue text, uncut. When the link could only hold the start
    /// of it, this is what the reporter pastes over the form.
    public static func fullBody(for payload: BugReportPayload) -> String {
        body(payload, description: payload.description)
    }

    static func title(for payload: BugReportPayload) -> String {
        // `isNewline` also splits a Windows line ending, which is a single
        // character and would otherwise ride into the title.
        var firstLine = String(payload.description.split(whereSeparator: \.isNewline).first ?? "").prefix(72)
        while firstLine.utf8.count > maxTitleBytes { firstLine.removeLast() }
        return "\(payload.type.titlePrefix) \(firstLine)"
    }

    private static func body(_ payload: BugReportPayload, description: String) -> String {
        var contextLines = ["- **Type:** \(payload.type.rawValue)"]
        if !payload.appVersion.isEmpty { contextLines.append("- **App version:** \(payload.appVersion)") }
        for key in payload.extra.keys.sorted() {
            contextLines.append("- **\(key):** \(payload.extra[key] ?? "")")
        }
        if !payload.email.isEmpty { contextLines.append("- **Reporter:** \(payload.email)") }

        var lines = [
            "_Reported from figg._",
            "",
            description,
            "",
            "---",
            "### Context",
            contextLines.joined(separator: "\n"),
        ]
        if !payload.screenshots.isEmpty {
            lines += ["", "### Screenshots", "_Paste your screenshots here._"]
        }
        return lines.joined(separator: "\n")
    }

    private static func build(_ payload: BugReportPayload, description: String, repo: String) -> URL {
        var components = URLComponents(string: "https://github.com/\(repo)/issues/new")!
        components.queryItems = [
            URLQueryItem(name: "template", value: template(for: payload.type)),
            URLQueryItem(name: "title", value: title(for: payload)),
            URLQueryItem(name: "body", value: body(payload, description: description)),
        ]
        // URLComponents leaves "+" and ";" as they are. GitHub reads "+" as
        // a space ("C++" would arrive as "C  "), and some servers split a
        // query at ";".
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
            .replacingOccurrences(of: ";", with: "%3B")
        return components.url!
    }
}
