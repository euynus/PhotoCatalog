// ============================================================
//  MetadataReader — Image I/O EXIF / TIFF / GPS reader
//  (PRD §6.5 metadata, §12.4 capture-date priority)
// ============================================================
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ScannedMetadata {
    var width = 0
    var height = 0
    var orientation = 1
    var colorSpace = "sRGB"
    var camera = ""
    var lens = ""
    var focal = 0
    var aperture = 0.0
    var shutter = ""
    var iso = 0
    var captureDate = Date()
    var captureDateSource = "文件修改时间"
    var gps: (Double, Double) = (0, 0)
    var fileSize: Int64 = 0
}

enum MetadataReader {
    static func read(_ url: URL) -> ScannedMetadata {
        var m = ScannedMetadata()

        // file attributes
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        m.fileSize = (attrs[.size] as? Int64) ?? 0
        let fileModified = (attrs[.modificationDate] as? Date) ?? Date()
        let fileCreated = (attrs[.creationDate] as? Date)

        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else {
            m.captureDate = fileModified
            return m
        }

        m.width = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
        m.height = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        m.orientation = (props[kCGImagePropertyOrientation] as? Int) ?? 1
        if let model = props[kCGImagePropertyColorModel] as? String {
            m.colorSpace = (props[kCGImagePropertyProfileName] as? String) ?? model
        }

        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]

        m.camera = [tiff[kCGImagePropertyTIFFMake] as? String, tiff[kCGImagePropertyTIFFModel] as? String]
            .compactMap { $0 }.joined(separator: " ")
        m.lens = (exif[kCGImagePropertyExifLensModel] as? String) ?? ""
        if let f = (exif[kCGImagePropertyExifFocalLength] as? NSNumber)?.doubleValue { m.focal = Int(f.rounded()) }
        m.aperture = (exif[kCGImagePropertyExifFNumber] as? NSNumber)?.doubleValue ?? 0
        if let exp = (exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue { m.shutter = shutterString(exp) }
        if let isos = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int], let first = isos.first { m.iso = first }

        // GPS
        if let lat = (gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue,
           let lon = (gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue {
            let latRef = (gps[kCGImagePropertyGPSLatitudeRef] as? String) ?? "N"
            let lonRef = (gps[kCGImagePropertyGPSLongitudeRef] as? String) ?? "E"
            m.gps = (latRef == "S" ? -lat : lat, lonRef == "W" ? -lon : lon)
        }

        // capture-date priority (§12.4)
        if let d = exifDate(exif[kCGImagePropertyExifDateTimeOriginal] as? String) {
            m.captureDate = d; m.captureDateSource = "EXIF · DateTimeOriginal"
        } else if let d = exifDate(exif[kCGImagePropertyExifDateTimeDigitized] as? String) {
            m.captureDate = d; m.captureDateSource = "EXIF · CreateDate"
        } else if let d = fileCreated {
            m.captureDate = d; m.captureDateSource = "文件创建时间"
        } else {
            m.captureDate = fileModified; m.captureDateSource = "文件修改时间"
        }
        return m
    }

    private static func shutterString(_ exp: Double) -> String {
        guard exp > 0 else { return "" }
        if exp >= 1 { return String(format: "%.1f", exp) }
        return "1/\(Int((1 / exp).rounded()))"
    }

    // A fresh formatter per call: read() runs on concurrent background queues and
    // DateFormatter is not thread-safe to share.
    private static func exifDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: s)
    }
}
