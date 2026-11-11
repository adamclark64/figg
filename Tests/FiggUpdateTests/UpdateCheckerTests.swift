import FiggExport
import FiggUpdate
import Foundation
import Testing

/// Canned-response HTTPClient, same shape as FiggExportTests' FakeHTTP.
final class FakeHTTP: HTTPClient, @unchecked Sendable {
    var status = 200
    var body = Data()
    private(set) var requests: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (body, resp)
    }
}

@Suite struct UpdateCheckerTests {
    static let feed = URL(string: "https://store.example.com/latest.json")!

    private func checker(_ body: String, status: Int = 200) -> (UpdateChecker, FakeHTTP) {
        let http = FakeHTTP()
        http.status = status
        http.body = Data(body.utf8)
        return (UpdateChecker(feed: Self.feed, http: http), http)
    }

    @Test func parsesTheVersionFile() async throws {
        let (checker, http) = checker(#"{"version": "0.5.1", "dmg_url": "https://store.example.com/releases/figg-0.5.1.dmg", "size": 12345}"#)
        let release = try await checker.latest()
        #expect(release.version == "0.5.1")
        #expect(release.dmgURL.absoluteString == "https://store.example.com/releases/figg-0.5.1.dmg")
        #expect(release.dmgSize == 12345)
        #expect(http.requests.first?.url == Self.feed)
    }

    @Test func asksNothingOfGitHubAndSendsNoCredentials() async throws {
        // The check never goes to GitHub.
        let (checker, http) = checker(#"{"version": "0.5.1", "dmg_url": "https://store.example.com/figg.dmg", "size": 1}"#)
        _ = try await checker.latest()
        #expect(http.requests.count == 1)
        let request = try #require(http.requests.first)
        #expect(request.url?.host != "api.github.com")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func aLeadingVOnTheVersionIsDropped() async throws {
        let (checker, _) = checker(#"{"version": "v0.6.0", "dmg_url": "https://store.example.com/figg.dmg", "size": 1}"#)
        #expect(try await checker.latest().version == "0.6.0")
    }

    @Test func missingVersionFileIsBadResponse() async {
        let (checker, _) = checker("", status: 404)
        await #expect(throws: UpdateError.badResponse(404)) { _ = try await checker.latest() }
    }

    @Test func unreadableVersionFileThrows() async {
        for body in ["", "not json", #"{"version": "0.5.1"}"#, #"{"version": "0.5.1", "dmg_url": "", "size": 1}"#] {
            let (checker, _) = checker(body)
            await #expect(throws: UpdateError.unreadableFeed) { _ = try await checker.latest() }
        }
    }

    @Test func aDmgAnywhereButTheStoreIsRefused() async {
        // It would be installed over the running app.
        for url in [
            "https://evil.example.net/figg.dmg",
            "http://store.example.com/figg.dmg",
            "https://store.example.com.evil.net/figg.dmg",
            "file:///tmp/figg.dmg",
        ] {
            let (checker, _) = checker(#"{"version": "9.9.9", "dmg_url": "\#(url)", "size": 1}"#)
            await #expect(throws: UpdateError.untrustedDownload) { _ = try await checker.latest() }
        }
    }

    @Test func semverCompare() {
        #expect(UpdateChecker.isNewer("0.4.0", than: "0.3.0"))
        #expect(UpdateChecker.isNewer("1.0.0", than: "0.9.9"))
        #expect(UpdateChecker.isNewer("0.3.10", than: "0.3.9"))
        #expect(UpdateChecker.isNewer("0.3.1.1", than: "0.3.1"))
        #expect(!UpdateChecker.isNewer("0.3.0", than: "0.3.0"))
        #expect(!UpdateChecker.isNewer("0.2.9", than: "0.3.0"))
        // Malformed or prerelease versions are never "newer": a dev build must
        // not see an update banner because its version string is odd.
        #expect(!UpdateChecker.isNewer("0.4.0-rc1", than: "0.3.0"))
        #expect(!UpdateChecker.isNewer("abc", than: "0.3.0"))
        #expect(!UpdateChecker.isNewer("", than: "0.3.0"))
        #expect(!UpdateChecker.isNewer("0.4.0", than: "garbage"))
    }

    @Test func defaultsToThePublicDownloadStore() {
        // The same store the website's download button uses.
        #expect(UpdateChecker().feed.absoluteString == "https://3gwgc5ir6t6yxpzh.public.blob.vercel-storage.com/latest.json")
    }
}
