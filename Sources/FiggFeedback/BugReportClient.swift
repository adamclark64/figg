import FiggExport
import Foundation

/// What the sheet shows after a send attempt.
public enum BugReportResult: Equatable, Sendable {
    /// The relay filed the issue. Number and URL come from GitHub.
    case filed(number: Int?, url: URL?)
    /// Validation, relay or network failure, already mapped to user text.
    /// `offerBrowserFallback` is true when the relay could not be reached at
    /// all, so filing a text-only issue in the browser would still work.
    case failed(message: String, offerBrowserFallback: Bool)
}

/// POSTs a report to the hosted relay (relay/api/bug-report.js). The app
/// holds no GitHub token (hard rule 2); the relay holds it server-side.
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
                           offerBrowserFallback: false)
        }
        return .filed(number: reply?.number, url: reply?.url.flatMap(URL.init(string:)))
    }
}
