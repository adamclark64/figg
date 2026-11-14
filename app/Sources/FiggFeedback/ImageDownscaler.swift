import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Downscales a user-chosen screenshot to at most 1600 px on the long edge
/// and re-encodes it as JPEG quality 0.5, so three screenshots stay well
/// under the relay's 3 MB per-image cap. Re-encoding through CGImage also
/// drops any EXIF metadata from the original file.
public enum ImageDownscaler {
    public static let maxLongEdge = 1600
    public static let jpegQuality: Double = 0.5

    /// Returns nil when the data is not a decodable image; callers skip it.
    public static func screenshot(from data: Data, name: String) -> Screenshot? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  // Always build from the full image, never a stored thumbnail,
                  // and never upscale a small one.
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxLongEdge,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else { return nil }
        guard let jpeg = jpegData(from: image) else { return nil }

        let base = (name as NSString).deletingPathExtension
        let safeName = (base.isEmpty ? "screenshot" : base) + ".jpg"
        return Screenshot(name: safeName, mime: "image/jpeg",
                          base64: "data:image/jpeg;base64," + jpeg.base64EncodedString())
    }

    static func jpegData(from image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, [
            kCGImageDestinationLossyCompressionQuality: jpegQuality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
