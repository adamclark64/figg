import CoreGraphics
@testable import FiggFeedback
import FiggExport
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// Fake relay: either returns a canned status/body or throws, so every error
/// path is testable without a network.
final class FakeHTTP: HTTPClient, @unchecked Sendable {
    var sent: [URLRequest] = []
    var status = 200
    var body = #"{"number":12,"url":"https://github.com/adamclark64/figg/issues/12"}"#
    var error: Error?

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        sent.append(request)
        if let error { throw error }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

let endpoint = URL(string: "https://relay.example.com/api/bug-report")!

func samplePayload(screenshots: [Screenshot] = []) -> BugReportPayload {
    BugReportPayload(
        type: .bug,
        description: "The sidebar is empty\nafter restart",
        email: "me@example.com",
        appVersion: "0.5.0 (42)",
        extra: ["macOS": "macOS 26.1", "hardware": "Mac16,8", "engine": "parakeet"],
        screenshots: screenshots)
}

@Suite struct PayloadTests {
    @Test func encodesTheRelayContract() throws {
        let shot = Screenshot(name: "x.jpg", mime: "image/jpeg", base64: "data:image/jpeg;base64,AAAA")
        let data = try JSONEncoder().encode(samplePayload(screenshots: [shot]))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "bug")
        #expect(json["description"] as? String == "The sidebar is empty\nafter restart")
        #expect(json["email"] as? String == "me@example.com")
        #expect(json["appVersion"] as? String == "0.5.0 (42)")
        #expect((json["extra"] as? [String: String])?["engine"] == "parakeet")
        let shots = json["screenshots"] as! [[String: Any]]
        #expect(shots.count == 1)
        #expect(shots[0]["mime"] as? String == "image/jpeg")
        #expect((shots[0]["base64"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true)
        // The payload carries no page URL.
        #expect(json["url"] == nil)
        #expect(json["userAgent"] == nil)
        #expect(json["viewport"] == nil)
    }

    @Test func validation() {
        #expect(samplePayload().validationErrorCode == nil)
        var empty = samplePayload()
        empty.description = "  \n "
        #expect(empty.validationErrorCode == "missing_description")
        let shot = Screenshot(name: "x.jpg", mime: "image/jpeg", base64: "d")
        let many = samplePayload(screenshots: [shot, shot, shot, shot])
        #expect(many.validationErrorCode == "too_many_screenshots")
        #expect(samplePayload(screenshots: [shot, shot, shot]).validationErrorCode == nil)
    }

    @Test func errorMessages() {
        #expect(BugReportErrorMessage.message(for: "bug_reporting_unconfigured")
            == "Bug reporting isn't configured yet (missing GitHub token). Try again later.")
        #expect(BugReportErrorMessage.message(for: "screenshot_too_large")
            == "A screenshot is too large. Please attach smaller images.")
        #expect(BugReportErrorMessage.message(for: "too_many_screenshots") == "Attach at most 3 screenshots.")
        #expect(BugReportErrorMessage.message(for: "screenshots_must_be_images") == "Only image files can be attached.")
        #expect(BugReportErrorMessage.message(for: "missing_description") == "Please describe the issue.")
        #expect(BugReportErrorMessage.message(for: "rate_limited")
            == "Too many reports in a short time. Please try again later.")
        #expect(BugReportErrorMessage.message(for: "whatever")
            == "Something went wrong filing the report. Please try again.")
        #expect(BugReportErrorMessage.message(for: nil)
            == "Something went wrong filing the report. Please try again.")
    }
}

@Suite struct FallbackURLTests {
    @Test func buildsAPrefilledIssueURL() throws {
        let url = GitHubIssueURL.url(for: samplePayload())
        #expect(url.absoluteString.hasPrefix("https://github.com/adamclark64/figg/issues/new?"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value ?? "") })
        #expect(items["title"] == "[Figg bug] The sidebar is empty")
        #expect(items["labels"] == "bug,user-report,macos")
        let body = try #require(items["body"])
        #expect(body.contains("The sidebar is empty\nafter restart"))
        #expect(body.contains("- **engine:** parakeet"))
        #expect(body.contains("- **Reporter:** me@example.com"))
        // The raw query must be percent-encoded: no literal spaces or newlines.
        let query = try #require(url.query)
        #expect(!query.contains(" "))
        #expect(!query.contains("\n"))
    }

    @Test func truncatesLongTitlesAndUsesTypePrefix() {
        var p = samplePayload()
        p.type = .enhancement
        p.description = String(repeating: "a", count: 200)
        let items = URLComponents(url: GitHubIssueURL.url(for: p), resolvingAgainstBaseURL: false)!.queryItems!
        let title = items.first { $0.name == "title" }!.value!
        #expect(title == "[Feature request] " + String(repeating: "a", count: 72))
    }
}

@Suite struct DownscaleTests {
    /// A flat test image of the given size, PNG-encoded.
    func pngData(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.5, green: 0.2, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    func decodedSize(of screenshot: Screenshot) throws -> (Int, Int) {
        let prefix = "data:image/jpeg;base64,"
        #expect(screenshot.base64.hasPrefix(prefix))
        let data = try #require(Data(base64Encoded: String(screenshot.base64.dropFirst(prefix.count))))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (props[kCGImagePropertyPixelWidth] as! Int, props[kCGImagePropertyPixelHeight] as! Int)
    }

    @Test func downscalesLongEdgeTo1600() throws {
        let shot = try #require(ImageDownscaler.screenshot(from: pngData(width: 3200, height: 1800), name: "big.png"))
        let (w, h) = try decodedSize(of: shot)
        #expect(w == 1600)
        #expect(h == 900)
        #expect(shot.name == "big.jpg")
        #expect(shot.mime == "image/jpeg")
    }

    @Test func neverUpscalesSmallImages() throws {
        let shot = try #require(ImageDownscaler.screenshot(from: pngData(width: 320, height: 200), name: "small.png"))
        let (w, h) = try decodedSize(of: shot)
        #expect(w <= 320)
        #expect(h <= 200)
    }

    @Test func rejectsNonImageData() {
        #expect(ImageDownscaler.screenshot(from: Data("not an image".utf8), name: "x.txt") == nil)
        #expect(ImageDownscaler.screenshot(from: Data(), name: "empty") == nil)
    }
}

@Suite struct ClientTests {
    @Test func successReturnsIssueNumberAndURL() async {
        let http = FakeHTTP()
        let result = await BugReportClient(endpoint: endpoint, http: http).send(samplePayload())
        #expect(result == .filed(number: 12, url: URL(string: "https://github.com/adamclark64/figg/issues/12")))
        #expect(http.sent[0].url == endpoint)
        #expect(http.sent[0].httpMethod == "POST")
        #expect(http.sent[0].value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test(arguments: [
        (503, "bug_reporting_unconfigured", "Bug reporting isn't configured yet (missing GitHub token). Try again later."),
        (413, "screenshot_too_large", "A screenshot is too large. Please attach smaller images."),
        (400, "too_many_screenshots", "Attach at most 3 screenshots."),
        (400, "screenshots_must_be_images", "Only image files can be attached."),
        (400, "missing_description", "Please describe the issue."),
        (429, "rate_limited", "Too many reports in a short time. Please try again later."),
        (502, "issue_create_failed", "Something went wrong filing the report. Please try again."),
    ])
    func relayErrorsMapToMessages(status: Int, code: String, message: String) async {
        let http = FakeHTTP()
        http.status = status
        http.body = #"{"error":"\#(code)"}"#
        let result = await BugReportClient(endpoint: endpoint, http: http).send(samplePayload())
        #expect(result == .failed(message: message, offerBrowserFallback: false))
    }

    @Test func networkFailureOffersTheBrowserFallback() async {
        let http = FakeHTTP()
        http.error = URLError(.notConnectedToInternet)
        let result = await BugReportClient(endpoint: endpoint, http: http).send(samplePayload())
        #expect(result == .failed(message: "Couldn't reach the server. Please try again.", offerBrowserFallback: true))
    }

    @Test func nonJSONErrorBodyGetsTheGenericMessage() async {
        let http = FakeHTTP()
        http.status = 500
        http.body = "<html>gateway error</html>"
        let result = await BugReportClient(endpoint: endpoint, http: http).send(samplePayload())
        #expect(result == .failed(message: "Something went wrong filing the report. Please try again.",
                                  offerBrowserFallback: false))
    }

    @Test func invalidPayloadNeverReachesTheNetwork() async {
        let http = FakeHTTP()
        var p = samplePayload()
        p.description = ""
        let result = await BugReportClient(endpoint: endpoint, http: http).send(p)
        #expect(result == .failed(message: "Please describe the issue.", offerBrowserFallback: false))
        #expect(http.sent.isEmpty)
    }
}

@Suite struct ContextTests {
    @Test func versionAndHardwareLookSane() {
        #expect(ReportContext.macOSVersion.hasPrefix("macOS "))
        // Hardware model is best-effort; when present it looks like "Mac16,8".
        let model = ReportContext.hardwareModel
        #expect(model.isEmpty || model.contains("Mac"))
    }
}
