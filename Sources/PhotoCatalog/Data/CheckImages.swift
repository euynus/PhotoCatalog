// ============================================================
//  Check images — pictures the headless checks write to disk
// ============================================================
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes the checks' pictures as files, for the code that reads photos from disk.
enum CheckImages {
    /// Writes `image` to `url` as `type`, creating its folder; whether the file was written.
    @discardableResult
    static func write(_ image: CGImage, to url: URL, type: UTType = .png, properties: [CFString: Any]? = nil) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary?)
        return CGImageDestinationFinalize(destination)
    }

    /// `image` written to a new PNG in the temporary folder, named `prefix` and a UUID. The caller
    /// removes it.
    static func temporaryPNG(_ image: CGImage, prefix: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)\(UUID().uuidString).png")
        write(image, to: url)
        return url
    }
}
