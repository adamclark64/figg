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

/// The JSON body POSTed to the relay. App context goes in `appVersion` and
/// `extra`. Privacy rule: `extra` never carries meeting content, transcripts,
/// titles or calendar data.
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
}

/// Builds the browser fallback: a prefilled new-issue URL used when no relay
/// endpoint is configured or the relay is unreachable. Text only; screenshots
/// cannot ride a URL.
public enum GitHubIssueURL {
    public static let defaultRepo = "adamclark64/figg"

    public static func url(for payload: BugReportPayload, repo: String = defaultRepo) -> URL {
        let firstLine = payload.description.split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
        let title = "\(payload.type.titlePrefix) \(String(firstLine.prefix(72)))"

        var contextLines = ["- **Type:** \(payload.type.rawValue)"]
        if !payload.appVersion.isEmpty { contextLines.append("- **App version:** \(payload.appVersion)") }
        for key in payload.extra.keys.sorted() {
            contextLines.append("- **\(key):** \(payload.extra[key] ?? "")")
        }
        if !payload.email.isEmpty { contextLines.append("- **Reporter:** \(payload.email)") }

        let body = [
            "_Reported from figg (relay unavailable, filed via browser)._",
            "",
            payload.description,
            "",
            "---",
            "### Context",
            contextLines.joined(separator: "\n"),
        ].joined(separator: "\n")

        var components = URLComponents(string: "https://github.com/\(repo)/issues/new")!
        components.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "body", value: body),
            URLQueryItem(name: "labels", value: "\(payload.type.rawValue),user-report,macos"),
        ]
        return components.url!
    }
}
