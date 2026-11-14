@testable import FiggExport
import FiggNotes
import FiggStore
import Foundation
import Testing

let notes = """
## Summary
We agreed to **ship Friday**.
## Notes
- Pricing *stays* flat
  - revisit in `Q3`
## Action items
- [ ] Ben: send deck
"""

let sample = Meeting(title: "Sync & plan", createdAt: Date(timeIntervalSince1970: 1_767_225_600), status: .ready, userNotes: "", enhancedNotes: notes)

@Suite struct FormatterTests {
    @Test func slackConvertsMarkdown() {
        let s = Formatters.slack(sample)
        #expect(s.hasPrefix("*Sync & plan* · "))
        #expect(s.contains("\n*Summary*\nWe agreed to *ship Friday*."))
        #expect(s.contains("• Pricing _stays_ flat"))
        #expect(s.contains("    • revisit in `Q3`"))
        #expect(s.contains("☐ Ben: send deck"))
    }

    @Test func confluenceStorageIsWellFormedXHTML() throws {
        let html = Formatters.confluenceStorage(sample)
        #expect(html.contains("<h3>Summary</h3>"))
        #expect(html.contains("<strong>ship Friday</strong>"))
        #expect(html.contains("<ul><li>Pricing <em>stays</em> flat<ul><li>revisit in <code>Q3</code></li></ul></li></ul>"))
        #expect(html.contains("<ac:task-status>incomplete</ac:task-status><ac:task-body>Ben: send deck</ac:task-body>"))
        // Storage format must parse as XML (namespaces declared for the ac: prefix).
        let wrapped = "<root xmlns:ac=\"http://atlassian.com/content\">\(html)</root>"
        _ = try XMLDocument(xmlString: wrapped)
    }

    @Test func escapesHTML() {
        let m = Meeting(title: "x", userNotes: "a < b & c")
        #expect(Formatters.confluenceStorage(m).contains("<p>a &lt; b &amp; c</p>"))
    }

    @Test func markdownFallsBackToUserNotes() {
        let m = Meeting(title: "Raw", userNotes: "- my note")
        #expect(Formatters.markdown(m).hasSuffix("- my note"))
    }
}

final class FakeHTTP: HTTPClient, @unchecked Sendable {
    var sent: [URLRequest] = []
    var status = 200
    var body = #"{"key":"PROJ-1"}"#

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        sent.append(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@Suite struct AtlassianTests {
    let config = AtlassianConfig(siteURL: URL(string: "https://example.atlassian.net")!, email: "me@example.com", apiToken: "tok", confluenceSpaceKey: "DOCS", jiraProjectKey: "PROJ")

    @Test func jiraRequestShape() async throws {
        let http = FakeHTTP()
        let client = AtlassianClient(config: config, http: http)
        let items = ActionItems.parse(notes)
        let keys = try await client.createJiraIssues(items, meeting: sample)
        #expect(keys == ["PROJ-1"])
        let req = http.sent[0]
        #expect(req.url?.absoluteString == "https://example.atlassian.net/rest/api/3/issue")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("me@example.com:tok".utf8).base64EncodedString())
        let json = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        let fields = json["fields"] as! [String: Any]
        #expect(fields["summary"] as? String == "Ben: send deck")
        #expect((fields["project"] as? [String: String])?["key"] == "PROJ")
        #expect((fields["description"] as? [String: Any])?["type"] as? String == "doc")
    }

    @Test func confluenceRequestAndURL() async throws {
        let http = FakeHTTP()
        http.body = #"{"_links":{"base":"https://example.atlassian.net/wiki","webui":"/spaces/DOCS/pages/1"}}"#
        let url = try await AtlassianClient(config: config, http: http).publishToConfluence(sample)
        #expect(url.absoluteString == "https://example.atlassian.net/wiki/spaces/DOCS/pages/1")
        let json = try JSONSerialization.jsonObject(with: http.sent[0].httpBody!) as! [String: Any]
        #expect((json["space"] as? [String: String])?["key"] == "DOCS")
        #expect((json["title"] as? String)?.hasPrefix("Sync & plan (") == true)
    }

    @Test func surfacesErrors() async {
        let http = FakeHTTP()
        http.status = 400
        http.body = "bad project"
        await #expect(throws: AtlassianError.badResponse(400, "bad project")) {
            try await AtlassianClient(config: config, http: http).createJiraIssues(ActionItems.parse(notes), meeting: sample)
        }
    }

    @Test func requiresProjectKey() async {
        var c = config
        c.jiraProjectKey = ""
        await #expect(throws: AtlassianError.notConfigured("a Jira project key")) {
            try await AtlassianClient(config: c, http: FakeHTTP()).createJiraIssues(ActionItems.parse(notes), meeting: sample)
        }
    }
}
