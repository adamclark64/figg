import AppKit
import Foundation
import UniformTypeIdentifiers

/// The parts of a clipboard the bug reporter reads. A protocol so the paste
/// rule below is tested with a fake, not with the real clipboard.
public protocol ClipboardContents {
    /// Files on the clipboard (a copy in Finder), in order.
    var fileURLs: [URL] { get }
    /// Type identifiers on the clipboard, e.g. "public.png".
    var typeIdentifiers: [String] { get }
    func data(forTypeIdentifier identifier: String) -> Data?
}

/// One image taken from the clipboard, not yet downscaled.
public struct ClipboardImage: Equatable, Sendable {
    public var data: Data
    public var name: String

    public init(data: Data, name: String) {
        self.data = data
        self.name = name
    }
}

/// Decides what a paste in the Report a Bug window attaches. The window has
/// a text field, so a paste must stay a text paste unless the clipboard
/// clearly holds a picture.
public enum ClipboardImages {
    /// Image data types, best first. A screenshot copied by macOS carries
    /// PNG and TIFF; PNG is the smaller read.
    static let imageTypes = ["public.png", "public.jpeg", "public.heic", "public.tiff", "com.compuserve.gif"]

    /// Rich text beside a picture means the copy came out of a document
    /// (a spreadsheet or word processor adds a rendering of the selection),
    /// so the paste is text.
    static let richTextTypes = ["public.rtf", "com.apple.rtfd", "com.apple.flat-rtfd"]

    /// The images a paste should attach, or none when the paste belongs to
    /// the text field.
    ///
    /// - Files win: copied image files are attached, and nothing else is
    ///   read, so a copied document never attaches its icon.
    /// - Otherwise image data is attached (a screenshot, "Copy Image" in a
    ///   browser), unless rich text came with it.
    ///
    /// At most `limit` files are read, so a paste of two hundred copied
    /// photos does not load them all to keep three.
    public static func images(
        on clipboard: any ClipboardContents,
        limit: Int = .max,
        readFile: (URL) -> Data? = { try? Data(contentsOf: $0) }
    ) -> [ClipboardImage] {
        let files = clipboard.fileURLs
        if !files.isEmpty {
            return files.filter(isImageFile).prefix(max(limit, 0)).compactMap { url in
                readFile(url).map { ClipboardImage(data: $0, name: url.lastPathComponent) }
            }
        }
        let types = clipboard.typeIdentifiers
        if types.contains(where: richTextTypes.contains) { return [] }
        for type in imageTypes where types.contains(type) {
            if let data = clipboard.data(forTypeIdentifier: type), !data.isEmpty {
                return [ClipboardImage(data: data, name: "pasted-image")]
            }
        }
        return []
    }

    /// True when the clipboard holds copied image files. With this true and
    /// `images` empty, the files could not be read (figg may lack access to
    /// their folder), and the paste should say so, not type their names.
    public static func holdsImageFiles(_ clipboard: any ClipboardContents) -> Bool {
        clipboard.fileURLs.contains(where: isImageFile)
    }

    static func isImageFile(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }
}

extension NSPasteboard: ClipboardContents {
    public var fileURLs: [URL] {
        (readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    public var typeIdentifiers: [String] {
        (types ?? []).map(\.rawValue)
    }

    public func data(forTypeIdentifier identifier: String) -> Data? {
        data(forType: NSPasteboard.PasteboardType(identifier))
    }
}
