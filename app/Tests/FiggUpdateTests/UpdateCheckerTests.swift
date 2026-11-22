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

    @Test func carriesTheSignatureThrough() async throws {
        let (checker, _) = checker(#"{"version": "0.8.0", "dmg_url": "https://store.example.com/releases/figg-0.8.0.dmg", "size": 12345, "signature": "c2lnbmF0dXJl"}"#)
        #expect(try await checker.latest().signature == "c2lnbmF0dXJl")
    }

    @Test func aVersionFileWithoutASignatureStillParses() async throws {
        // The release is still reported, so the user is told the update was
        // refused (UpdateInstaller does that) instead of never seeing one.
        let (checker, _) = checker(#"{"version": "0.8.0", "dmg_url": "https://store.example.com/releases/figg-0.8.0.dmg", "size": 12345}"#)
        #expect(try await checker.latest().signature == nil)
    }

    @Test func fieldsThisVersionDoesNotKnowAreIgnored() async throws {
        // What lets a field be added to the file without breaking copies
        // already installed: 0.7.0 reads a file with "signature" in it the
        // same way this reads one with a field from the future.
        let (checker, _) = checker(#"{"version": "0.8.0", "dmg_url": "https://store.example.com/figg.dmg", "size": 1, "signature": "c2ln", "from_the_future": {"a": [1, 2]}}"#)
        #expect(try await checker.latest().version == "0.8.0")
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

    /// The fields every test below expects to come through untouched,
    /// whatever `notes` holds.
    private static let base = #""version": "0.19.2", "dmg_url": "https://store.example.com/releases/figg-0.19.2.dmg", "size": 12345, "signature": "c2ln""#

    private func expectTheReleaseIsOffered(_ release: ReleaseInfo) {
        #expect(release.version == "0.19.2")
        #expect(release.dmgURL.absoluteString == "https://store.example.com/releases/figg-0.19.2.dmg")
        #expect(release.dmgSize == 12345)
        #expect(release.signature == "c2ln")
    }

    @Test func parsesReleaseNotes() async throws {
        let (checker, _) = checker(####"{\####(Self.base), "notes": [{"version": "v0.19.2", "text": "### Bug Fixes\n\n* **widget:** keep the timer visible"}, {"version": "0.19.1", "text": "### Features\n\n* add a sample feature"}]}"####)
        let release = try await checker.latest()
        expectTheReleaseIsOffered(release)
        #expect(release.notes == [
            ReleaseNote(version: "0.19.2", text: "### Bug Fixes\n\n* **widget:** keep the timer visible"),
            ReleaseNote(version: "0.19.1", text: "### Features\n\n* add a sample feature"),
        ])
    }

    @Test func aVersionFileWithoutNotesHasNone() async throws {
        let (checker, _) = checker(#"{\#(Self.base)}"#)
        let release = try await checker.latest()
        expectTheReleaseIsOffered(release)
        #expect(release.notes.isEmpty)
    }

    @Test func malformedNotesAreDropped() async throws {
        // Notes can only add to the prompt: whatever is wrong with them, the
        // update is still offered with the same version, dmg and signature.
        for notes in [
            ####""notes": "### Bug Fixes""####,
            #""notes": {"version": "0.19.2", "text": "a fix"}"#,
            #""notes": null"#,
            #""notes": [{"version": "0.19.2"}]"#,
            #""notes": [{"version": 0.19, "text": "a fix"}]"#,
            #""notes": [{"version": "0.19.2", "text": "  \n "}]"#,
            #""notes": [{"version": "next", "text": "a fix"}]"#,
            #""notes": [1, "two", null, []]"#,
        ] {
            let (checker, _) = checker(#"{\#(Self.base), \#(notes)}"#)
            let release = try await checker.latest()
            expectTheReleaseIsOffered(release)
            #expect(release.notes.isEmpty, "\(notes)")
        }

        // One good entry among bad ones is kept, in place.
        let (checker, _) = checker(#"{\#(Self.base), "notes": [{"version": "0.19.2"}, 7, {"version": "0.19.1", "text": "* a fix"}, {"version": "0.19.0", "text": ""}, {"text": "* orphan"}]}"#)
        let release = try await checker.latest()
        expectTheReleaseIsOffered(release)
        #expect(release.notes == [ReleaseNote(version: "0.19.1", text: "* a fix")])
    }

    @Test func notesNeverMakeTheFileUnreadable() async throws {
        // A huge note is carried as is (ReleaseNotes cuts what is shown) and
        // does not stop the file being read.
        let huge = String(repeating: "a", count: 1_000_000)
        let (checker, _) = checker(#"{\#(Self.base), "notes": [{"version": "0.19.2", "text": "\#(huge)"}]}"#)
        let release = try await checker.latest()
        expectTheReleaseIsOffered(release)
        #expect(release.notes.count == 1)
        #expect(release.notes.first?.text.count == 1_000_000)
    }
}
