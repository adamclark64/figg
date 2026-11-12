import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Where the handoff puts screenshots. A protocol so the rule below is
/// tested with a fake, not with the real clipboard.
public protocol ClipboardWriting {
    /// Replaces the clipboard with one picture, given in several encodings.
    func replaceContents(withImage encodings: [(typeIdentifier: String, data: Data)])
    /// Replaces the clipboard with files, as a copy in Finder would.
    func replaceContents(withFiles urls: [URL])
}

/// Carries screenshots from the Report a Bug window to the GitHub issue in
/// the browser. A link cannot hold a picture, so the screenshots go on the
/// clipboard and one paste in the issue attaches them.
public enum ScreenshotHandoff {
    /// Every handoff folder's name starts with this.
    static let folderPrefix = "figg-report-"

    /// Where one app's hand-off folders live: a folder of its own inside the
    /// temporary folder, named by bundle identifier, so a development copy
    /// running beside the installed app never clears the other's files.
    public static func root(bundleIdentifier: String?, in temporary: URL = FileManager.default.temporaryDirectory) -> URL {
        temporary.appendingPathComponent(bundleIdentifier ?? "figg", isDirectory: true)
    }

    /// A new folder name for one report's screenshots, inside `directory`.
    public static func newFolder(in directory: URL) -> URL {
        directory.appendingPathComponent(folderPrefix + UUID().uuidString, isDirectory: true)
    }

    /// Deletes the folders earlier reports left in `directory`. Screenshots
    /// can show meeting content, so they should not sit in the temporary
    /// folder until macOS clears it. A folder cannot go when its report is
    /// done, because a paste of several files reads them then; it goes when
    /// the next report starts.
    public static func removeOldFolders(in directory: URL) {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        for entry in entries where entry.lastPathComponent.hasPrefix(folderPrefix) {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// The decoded image bytes of a screenshot, or nil when its data URL is
    /// not the shape `ImageDownscaler` writes.
    public static func imageData(of screenshot: Screenshot) -> Data? {
        guard let comma = screenshot.base64.firstIndex(of: ","),
              screenshot.base64.hasPrefix("data:") else { return nil }
        return Data(base64Encoded: String(screenshot.base64[screenshot.base64.index(after: comma)...]))
    }

    /// Writes each screenshot as a file in `directory`, creating it first,
    /// and returns the files in order. Names are numbered, so two
    /// screenshots called the same never overwrite each other.
    public static func writeFiles(_ screenshots: [Screenshot], to directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var urls: [URL] = []
        for (index, screenshot) in screenshots.enumerated() {
            guard let data = imageData(of: screenshot) else { continue }
            let url = directory.appendingPathComponent("screenshot-\(index + 1).jpg")
            try data.write(to: url)
            urls.append(url)
        }
        return urls
    }

    /// Puts the screenshot files where one paste in the browser attaches
    /// them. A single picture goes as image data, which every browser
    /// takes; several go as files, the only way to paste more than one.
    /// Returns false when there was nothing to copy.
    @discardableResult
    public static func copy(_ files: [URL], to clipboard: any ClipboardWriting) -> Bool {
        if files.count == 1, let data = try? Data(contentsOf: files[0]) {
            var encodings: [(typeIdentifier: String, data: Data)] = []
            for type in [UTType.png, UTType.tiff] {
                if let converted = convert(data, to: type) {
                    encodings.append((type.identifier, converted))
                }
            }
            if !encodings.isEmpty {
                clipboard.replaceContents(withImage: encodings)
                return true
            }
        }
        guard !files.isEmpty else { return false }
        clipboard.replaceContents(withFiles: files)
        return true
    }

    static func convert(_ data: Data, to type: UTType) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }
}

extension NSPasteboard: ClipboardWriting {
    public func replaceContents(withImage encodings: [(typeIdentifier: String, data: Data)]) {
        clearContents()
        declareTypes(encodings.map { NSPasteboard.PasteboardType($0.typeIdentifier) }, owner: nil)
        for encoding in encodings {
            setData(encoding.data, forType: NSPasteboard.PasteboardType(encoding.typeIdentifier))
        }
    }

    public func replaceContents(withFiles urls: [URL]) {
        clearContents()
        writeObjects(urls as [NSURL])
    }
}
