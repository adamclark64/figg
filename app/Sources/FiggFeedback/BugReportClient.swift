import FiggExport
import Foundation

/// What the sheet shows after a send attempt.
public enum BugReportResult: Equatable, Sendable {
    /// The relay filed the issue. Number and URL come from GitHub.
    case filed(number: Int?, url: URL?)
    /// Validation, relay or network failure, already mapped to user text.
    /// `offerBrowserFallback` is true when the fault is the relay's (it
    /// could not be reached, or it answered with a server error or a rate
    /// limit), so filing the issue in the browser would still work.
    case failed(message: String, offerBrowserFallback: Bool)
}

/// Where Report a Bug sends a report, from `feedback.bug_report_endpoint`.
/// Empty (the default) is figg's hosted relay, so reporting needs no GitHub
/// account. A URL is a relay someone hosts themself. "browser" opens the
/// report as a GitHub issue in the browser instead (`GitHubIssueURL`).
public enum BugReportRelay {
    /// figg's own relay: api/ in the repo, deployed as the Vercel project
    /// `figg-api`. Every installed copy keeps this URL, so it never moves.
    /// Not a secret; the GitHub token lives on the relay.
    public static let hostedEndpoint = URL(string: "https://figg-api.vercel.app/v1/bug-report")!

    /// The setting that turns the relay off and files through the browser.
    public static let browserSetting = "browser"

    /// The relay to POST to, or nil to file the report in the browser. A
    /// value that is not a usable http(s) URL falls back to the hosted
    /// relay, so a typo never stops a report going out.
    public static func endpoint(forSetting raw: String) -> URL? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return hostedEndpoint }
        if value.lowercased() == browserSetting { return nil }
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host?.isEmpty == false
        else { return hostedEndpoint }
        return url
    }
}

/// POSTs a report to a relay (api/api/v1/bug-report.ts), figg's hosted one
/// unless `feedback.bug_report_endpoint` names another. The app holds no
/// GitHub token (hard rule 2); the relay holds it server-side.
public struct BugReportClient: Sendable {
    public let endpoint: URL
    let http: any HTTPClient

    public init(endpoint: URL, http: any HTTPClient = URLSessionHTTPClient()) {
        self.endpoint = endpoint
        self.http = http
    }

    public func send(_ payload: BugReportPayload) async -> BugReportResult {
        if let code = payload.validationErrorCode {
            return .failed(message: BugReportErrorMessage.message(for: code), offerBrowserFallback: false)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            return .failed(message: BugReportErrorMessage.message(for: nil), offerBrowserFallback: false)
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await http.send(request)
        } catch {
            return .failed(message: BugReportErrorMessage.networkFailure, offerBrowserFallback: true)
        }

        struct Reply: Decodable {
            var number: Int?
            var url: String?
            var error: String?
        }
        let reply = try? JSONDecoder().decode(Reply.self, from: data)

        guard (200..<300).contains(response.statusCode) else {
            return .failed(message: BugReportErrorMessage.message(for: reply?.error),
                           offerBrowserFallback: Self.relayAtFault(status: response.statusCode, code: reply?.error))
        }
        return .filed(number: reply?.number, url: reply?.url.flatMap(URL.init(string:)))
    }

    /// True when the browser would still work: a server error, a rate
    /// limit, or a 4xx that did not come from the relay's own checks (no
    /// error code, as when the deployment is missing and Vercel answers
    /// 404). A 4xx the relay explains is about the report itself, and the
    /// browser would not fix it.
    static func relayAtFault(status: Int, code: String?) -> Bool {
        if status >= 500 || status == 429 { return true }
        return code == nil
    }
}
