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
        // Nothing rides along beyond these fields.
        #expect(Set(json.keys) == ["type", "description", "email", "appVersion", "extra", "screenshots"])
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
        // The template labels the issue. A `labels` parameter is only for
        // people who can label in the repo, so the link has none.
        #expect(items["template"] == "bug.md")
        #expect(items["labels"] == nil)
        let body = try #require(items["body"])
        #expect(body.hasPrefix("_Reported from figg._\n"))
        #expect(body.contains("The sidebar is empty\nafter restart"))
        #expect(!body.contains("Screenshots"))
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
        #expect(items.first { $0.name == "template" }?.value == "feature.md")
    }

    @Test func everyReportTypeHasATemplate() {
        #expect(ReportType.allCases.map(GitHubIssueURL.template(for:)) == ["bug.md", "feature.md", "question.md"])
    }

    @Test func leavesAPlaceForScreenshotsWhenThereAreSome() throws {
        let shot = Screenshot(name: "x.jpg", mime: "image/jpeg", base64: "data:image/jpeg;base64,AAAA")
        let url = GitHubIssueURL.url(for: samplePayload(screenshots: [shot]))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        let body = try #require(items.first { $0.name == "body" }?.value)
        #expect(body.hasSuffix("### Screenshots\n_Paste your screenshots here._"))
        // The picture itself never rides the link.
        #expect(!url.absoluteString.contains("AAAA"))
    }

    // A character costs the link 1 byte in plain Latin, 6 in Cyrillic, 9 in
    // Japanese and 12 or more as an emoji; each must keep its start.
    @Test(arguments: [
        String(repeating: "a long line of plain words ", count: 400),
        String(repeating: "línea con acentos y emoji 🍪\n", count: 400),
        String(repeating: "サイドバーが空になりました。", count: 100),
        String(repeating: "Боковая панель пуста после перезапуска. ", count: 100),
        String(repeating: "🍪🥛", count: 600),
    ])
    func cutsALongDescriptionToFitALink(text: String) throws {
        var p = samplePayload()
        p.description = text
        let link = GitHubIssueURL.link(for: p)
        #expect(link.wasCut)
        let url = link.url
        #expect(url == GitHubIssueURL.url(for: p))
        #expect(url.absoluteString.utf8.count <= GitHubIssueURL.maxLength)
        // As much as fits is kept: little of the link is left unused.
        #expect(url.absoluteString.utf8.count > GitHubIssueURL.maxLength - 100)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        let body = try #require(items.first { $0.name == "body" }?.value)
        #expect(body.contains("Cut short to fit in a link"))
        // What is left is the start of the text, and the context survives.
        #expect(body.contains(String(text.prefix(100))))
        #expect(body.contains("- **engine:** parakeet"))
    }

    @Test func aPlusSignStaysAPlusSign() throws {
        var p = samplePayload()
        p.description = "C++ crash when 1 + 1"
        let url = GitHubIssueURL.url(for: p)
        // GitHub reads a bare "+" in a link as a space.
        #expect(!url.absoluteString.contains("+"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(items.first { $0.name == "title" }?.value == "[Figg bug] C++ crash when 1 + 1")
        #expect(items.first { $0.name == "body" }?.value?.contains("C++ crash when 1 + 1") == true)
    }

    @Test func aSemicolonIsEncoded() throws {
        var p = samplePayload()
        p.description = "open; close; open again"
        let url = GitHubIssueURL.url(for: p)
        #expect(!url.absoluteString.contains(";"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(items.first { $0.name == "title" }?.value == "[Figg bug] open; close; open again")
    }

    @Test func theTitleStopsAtAnyKindOfLineEnd() {
        var p = samplePayload()
        p.description = "first line\r\nsecond line"
        #expect(GitHubIssueURL.title(for: p) == "[Figg bug] first line")
        p.description = "\n\nfirst line\nsecond"
        #expect(GitHubIssueURL.title(for: p) == "[Figg bug] first line")
    }

    // One character can be thousands of bytes (stacked accents), and the
    // cut assumes the link fits once the description is gone.
    @Test func aHeavyFirstLineCannotOverflowTheLink() {
        var p = samplePayload()
        p.description = "e" + String(repeating: "\u{0301}", count: 3000) + " and then some text"
        let title = GitHubIssueURL.title(for: p)
        #expect(title.utf8.count <= GitHubIssueURL.maxTitleBytes + "[Figg bug] ".utf8.count)
        #expect(GitHubIssueURL.link(for: p).url.absoluteString.utf8.count <= GitHubIssueURL.maxLength)
    }

    @Test func theFullBodyIsTheWholeReport() throws {
        let text = String(repeating: "a long line of plain words ", count: 400)
        let shot = Screenshot(name: "x.jpg", mime: "image/jpeg", base64: "data:image/jpeg;base64,AAAA")
        var p = samplePayload(screenshots: [shot])
        p.description = text
        let body = GitHubIssueURL.fullBody(for: p)
        #expect(body.contains(text))
        #expect(!body.contains("Cut short"))
        #expect(body.contains("- **engine:** parakeet"))
        #expect(body.hasSuffix("### Screenshots\n_Paste your screenshots here._"))
        // The cut link says where the rest is.
        let cut = try #require(URLComponents(url: GitHubIssueURL.url(for: p), resolvingAgainstBaseURL: false)!
            .queryItems!.first { $0.name == "body" }?.value)
        #expect(cut.contains("The full report is on your clipboard"))
    }

    @Test func aShortDescriptionIsNotCut() throws {
        #expect(!GitHubIssueURL.link(for: samplePayload()).wasCut)
        let body = try #require(URLComponents(url: GitHubIssueURL.url(for: samplePayload()), resolvingAgainstBaseURL: false)!
            .queryItems!.first { $0.name == "body" }?.value)
        #expect(!body.contains("Cut short"))
    }
}

/// A clipboard with fixed contents.
struct FakeClipboard: ClipboardContents {
    var fileURLs: [URL] = []
    var items: [String: Data] = [:]
    var typeIdentifiers: [String] { Array(items.keys) }
    func data(forTypeIdentifier identifier: String) -> Data? { items[identifier] }
}

@Suite struct ClipboardImagesTests {
    let png = Data([1, 2, 3])
    let tiff = Data([4, 5, 6, 7])

    @Test func aCopiedScreenshotIsAttached() {
        // What macOS puts on the clipboard for a screenshot: PNG and TIFF.
        let clipboard = FakeClipboard(items: ["public.png": png, "public.tiff": tiff])
        #expect(ClipboardImages.images(on: clipboard) == [ClipboardImage(data: png, name: "pasted-image")])
    }

    @Test func anImageCopiedInABrowserIsAttachedDespiteItsLink() {
        let clipboard = FakeClipboard(items: [
            "public.tiff": tiff,
            "public.utf8-plain-text": Data("https://example.com/cat.png".utf8),
            "public.html": Data("<img src=cat.png>".utf8),
        ])
        #expect(ClipboardImages.images(on: clipboard) == [ClipboardImage(data: tiff, name: "pasted-image")])
    }

    @Test func plainTextIsLeftToTheTextField() {
        let clipboard = FakeClipboard(items: ["public.utf8-plain-text": Data("hello".utf8)])
        #expect(ClipboardImages.images(on: clipboard).isEmpty)
        #expect(ClipboardImages.images(on: FakeClipboard()).isEmpty)
    }

    @Test func aCopyFromADocumentIsTextEvenWithARenderingBeside() {
        let clipboard = FakeClipboard(items: [
            "public.utf8-plain-text": Data("cells".utf8),
            "public.rtf": Data("{\\rtf1}".utf8),
            "public.tiff": tiff,
        ])
        #expect(ClipboardImages.images(on: clipboard).isEmpty)
    }

    @Test func copiedImageFilesAreAttachedAndOtherFilesAreNot() {
        let shot = URL(fileURLWithPath: "/tmp/Screenshot 1.png")
        let photo = URL(fileURLWithPath: "/tmp/photo.HEIC")
        let doc = URL(fileURLWithPath: "/tmp/notes.pdf")
        // Finder adds the icon as image data; with files present it is never read.
        let clipboard = FakeClipboard(fileURLs: [shot, doc, photo], items: ["public.tiff": tiff])
        let images = ClipboardImages.images(on: clipboard) { url in Data(url.lastPathComponent.utf8) }
        #expect(images == [
            ClipboardImage(data: Data("Screenshot 1.png".utf8), name: "Screenshot 1.png"),
            ClipboardImage(data: Data("photo.HEIC".utf8), name: "photo.HEIC"),
        ])
        let onlyDoc = FakeClipboard(fileURLs: [doc], items: ["public.tiff": tiff])
        #expect(ClipboardImages.images(on: onlyDoc) { _ in Data([1]) }.isEmpty)
    }

    @Test func noMoreFilesAreReadThanAsked() {
        let files = (1...200).map { URL(fileURLWithPath: "/tmp/photo-\($0).png") }
        var reads = 0
        let images = ClipboardImages.images(on: FakeClipboard(fileURLs: files), limit: 2) { url in
            reads += 1
            return Data(url.lastPathComponent.utf8)
        }
        #expect(images.map(\.name) == ["photo-1.png", "photo-2.png"])
        #expect(reads == 2)
    }

    @Test func anUnreadableFileIsSkipped() {
        let clipboard = FakeClipboard(fileURLs: [URL(fileURLWithPath: "/tmp/gone.png")])
        #expect(ClipboardImages.images(on: clipboard) { _ in nil }.isEmpty)
        // The window can still tell this from a text paste, and say so.
        #expect(ClipboardImages.holdsImageFiles(clipboard))
    }

    @Test func onlyImageFilesCountAsImageFiles() {
        let doc = FakeClipboard(fileURLs: [URL(fileURLWithPath: "/tmp/notes.pdf")])
        #expect(!ClipboardImages.holdsImageFiles(doc))
        #expect(!ClipboardImages.holdsImageFiles(FakeClipboard(items: ["public.png": png])))
    }
}

/// Records what was put on the clipboard.
final class FakeClipboardWriter: ClipboardWriting {
    var image: [(typeIdentifier: String, data: Data)]?
    var files: [URL]?
    func replaceContents(withImage encodings: [(typeIdentifier: String, data: Data)]) { image = encodings; files = nil }
    func replaceContents(withFiles urls: [URL]) { files = urls; image = nil }
}

@Suite struct ScreenshotHandoffTests {
    func screenshot(_ name: String) throws -> Screenshot {
        try #require(ImageDownscaler.screenshot(from: DownscaleTests().pngData(width: 40, height: 30), name: name))
    }

    func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return CGSize(width: image.width, height: image.height)
    }

    func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("figg-handoff-test-\(UUID().uuidString)")
    }

    @Test func writesNumberedFilesThatAreTheScreenshots() throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let shots = [try screenshot("same.png"), try screenshot("same.png")]
        let files = try ScreenshotHandoff.writeFiles(shots, to: dir)
        #expect(files.map(\.lastPathComponent) == ["screenshot-1.jpg", "screenshot-2.jpg"])
        #expect(try Data(contentsOf: files[0]) == ScreenshotHandoff.imageData(of: shots[0]))
        #expect(pixelSize(of: try Data(contentsOf: files[1])) == CGSize(width: 40, height: 30))
    }

    @Test func oneScreenshotIsCopiedAsAPicture() throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try ScreenshotHandoff.writeFiles([try screenshot("a.png")], to: dir)
        let clipboard = FakeClipboardWriter()
        #expect(ScreenshotHandoff.copy(files, to: clipboard))
        let image = try #require(clipboard.image)
        #expect(image.map(\.typeIdentifier) == ["public.png", "public.tiff"])
        #expect(pixelSize(of: image[0].data) == CGSize(width: 40, height: 30))
        #expect(clipboard.files == nil)
    }

    @Test func severalScreenshotsAreCopiedAsFiles() throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try ScreenshotHandoff.writeFiles([try screenshot("a.png"), try screenshot("b.png")], to: dir)
        let clipboard = FakeClipboardWriter()
        #expect(ScreenshotHandoff.copy(files, to: clipboard))
        #expect(clipboard.files == files)
        #expect(clipboard.image == nil)
    }

    @Test func foldersFromEarlierReportsAreRemovedAndNothingElse() throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = ScreenshotHandoff.newFolder(in: dir)
        _ = try ScreenshotHandoff.writeFiles([try screenshot("a.png")], to: old)
        let other = dir.appendingPathComponent("someone-elses-file.txt")
        try Data("keep".utf8).write(to: other)

        ScreenshotHandoff.removeOldFolders(in: dir)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
        #expect(ScreenshotHandoff.newFolder(in: dir) != ScreenshotHandoff.newFolder(in: dir))
    }

    @Test func eachAppKeepsItsFilesInItsOwnFolder() {
        let temporary = URL(fileURLWithPath: "/tmp/t", isDirectory: true)
        let installed = ScreenshotHandoff.root(bundleIdentifier: "dev.example.figg", in: temporary)
        let dev = ScreenshotHandoff.root(bundleIdentifier: "dev.example.figg.dev", in: temporary)
        #expect(installed.path == "/tmp/t/dev.example.figg")
        #expect(installed != dev)
        #expect(ScreenshotHandoff.root(bundleIdentifier: nil, in: temporary).lastPathComponent == "figg")
    }

    @Test func nothingToCopyLeavesTheClipboardAlone() {
        let clipboard = FakeClipboardWriter()
        #expect(!ScreenshotHandoff.copy([], to: clipboard))
        #expect(clipboard.files == nil && clipboard.image == nil)
    }

    @Test func aDataURLOfAnotherShapeIsNotDecoded() {
        #expect(ScreenshotHandoff.imageData(of: Screenshot(name: "x", mime: "image/jpeg", base64: "AAAA")) == nil)
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
        (503, "bug_reporting_unconfigured", "Bug reporting isn't configured yet (missing GitHub token). Try again later.", true),
        (413, "screenshot_too_large", "A screenshot is too large. Please attach smaller images.", false),
        (400, "too_many_screenshots", "Attach at most 3 screenshots.", false),
        (400, "screenshots_must_be_images", "Only image files can be attached.", false),
        (400, "missing_description", "Please describe the issue.", false),
        (429, "rate_limited", "Too many reports in a short time. Please try again later.", true),
        (502, "issue_create_failed", "Something went wrong filing the report. Please try again.", true),
    ])
    // When the fault is the relay's, the browser is offered instead.
    func relayErrorsMapToMessages(status: Int, code: String, message: String, fallback: Bool) async {
        let http = FakeHTTP()
        http.status = status
        http.body = #"{"error":"\#(code)"}"#
        let result = await BugReportClient(endpoint: endpoint, http: http).send(samplePayload())
        #expect(result == .failed(message: message, offerBrowserFallback: fallback))
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
        // A broken relay is the relay's fault, so the browser is offered.
        #expect(result == .failed(message: "Something went wrong filing the report. Please try again.",
                                  offerBrowserFallback: true))
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
