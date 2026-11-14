import FiggNotes
import FiggStore
import Foundation

public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPClient: HTTPClient {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AtlassianError.badResponse(0, "No HTTP response") }
        return (data, http)
    }
}

public struct AtlassianConfig: Sendable, Equatable {
    /// e.g. https://your-site.atlassian.net
    public var siteURL: URL
    public var email: String
    public var apiToken: String
    public var confluenceSpaceKey: String
    public var jiraProjectKey: String

    public init(siteURL: URL, email: String, apiToken: String, confluenceSpaceKey: String, jiraProjectKey: String) {
        self.siteURL = siteURL
        self.email = email
        self.apiToken = apiToken
        self.confluenceSpaceKey = confluenceSpaceKey
        self.jiraProjectKey = jiraProjectKey
    }
}

public enum AtlassianError: LocalizedError, Equatable {
    case notConfigured(String)
    case badResponse(Int, String)

    public var errorDescription: String? {
        switch self {
        case let .notConfigured(what): return "Set \(what) in Settings > Sharing first."
        case let .badResponse(code, body): return "Atlassian returned \(code): \(body.prefix(300))"
        }
    }
}

/// Publishes notes to Confluence and creates Jira tickets, with Basic auth
/// (email + API token). The token comes from the Keychain, never disk.
public struct AtlassianClient: Sendable {
    public let config: AtlassianConfig
    public let http: HTTPClient

    public init(config: AtlassianConfig, http: HTTPClient = URLSessionHTTPClient()) {
        self.config = config
        self.http = http
    }

    func request(_ path: String, body: [String: Any]) throws -> URLRequest {
        var req = URLRequest(url: config.siteURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        let auth = Data("\(config.email):\(config.apiToken)".utf8).base64EncodedString()
        req.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return req
    }

    func send(_ req: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await http.send(req)
        guard (200..<300).contains(response.statusCode) else {
            throw AtlassianError.badResponse(response.statusCode, String(decoding: data, as: UTF8.self))
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: Confluence

    func confluenceRequest(for meeting: Meeting) throws -> URLRequest {
        guard !config.confluenceSpaceKey.isEmpty else { throw AtlassianError.notConfigured("a Confluence space key") }
        let date = meeting.createdAt.formatted(.iso8601.year().month().day())
        return try request("wiki/rest/api/content", body: [
            "type": "page",
            // Confluence titles must be unique per space; the date keeps
            // recurring meetings apart.
            "title": "\(meeting.displayTitle) (\(date))",
            "space": ["key": config.confluenceSpaceKey],
            "body": ["storage": ["value": Formatters.confluenceStorage(meeting), "representation": "storage"]],
        ])
    }

    /// Creates a page and returns its web URL.
    public func publishToConfluence(_ meeting: Meeting) async throws -> URL {
        let json = try await send(try confluenceRequest(for: meeting))
        let links = json["_links"] as? [String: Any]
        if let base = links?["base"] as? String, let webui = links?["webui"] as? String, let url = URL(string: base + webui) {
            return url
        }
        return config.siteURL.appendingPathComponent("wiki")
    }

    // MARK: Jira

    func jiraRequest(for item: ActionItem, meeting: Meeting) throws -> URLRequest {
        guard !config.jiraProjectKey.isEmpty else { throw AtlassianError.notConfigured("a Jira project key") }
        let date = meeting.createdAt.formatted(date: .abbreviated, time: .omitted)
        return try request("rest/api/3/issue", body: [
            "fields": [
                "project": ["key": config.jiraProjectKey],
                "issuetype": ["name": "Task"],
                "summary": String(item.summary.prefix(250)),
                "description": Self.adf(paragraphs: [
                    item.task,
                    "Action item from \"\(meeting.displayTitle)\" on \(date)" + (item.owner.map { ", owner: \($0)" } ?? "") + ". Created by figg.",
                ]),
            ],
        ])
    }

    /// Creates one Task per item; returns the new issue keys in order.
    public func createJiraIssues(_ items: [ActionItem], meeting: Meeting) async throws -> [String] {
        var keys: [String] = []
        for item in items {
            let json = try await send(try jiraRequest(for: item, meeting: meeting))
            if let key = json["key"] as? String { keys.append(key) }
        }
        return keys
    }

    /// Minimal Atlassian Document Format: one paragraph per string.
    static func adf(paragraphs: [String]) -> [String: Any] {
        [
            "type": "doc",
            "version": 1,
            "content": paragraphs.map { ["type": "paragraph", "content": [["type": "text", "text": $0]]] },
        ]
    }
}
