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
    var hasICCProfile = false
    var camera = ""
    var lens = ""
    var focal = 0
    var aperture = 0.0
    var shutter = ""
    var iso = 0
    var captureDate = Date()
    var captureDateSource = "文件修改时间"
    var gps: (Double, Double) = (0, 0)
    var gpsAltitude: Double?
    var author = ""
    var copyright = ""
    var makerNotes = ""
    var fileSize: Int64 = 0
    var fileModifiedAt: Date?
    var fileCreatedAt: Date?
}

enum MetadataReader {
    static func read(_ url: URL) -> ScannedMetadata {
        var m = ScannedMetadata()

        // file attributes
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        m.fileSize = (attrs[.size] as? Int64) ?? 0
        let fileModified = (attrs[.modificationDate] as? Date) ?? .now
        let fileCreated = (attrs[.creationDate] as? Date)
        m.fileModifiedAt = fileModified
        m.fileCreatedAt = fileCreated

        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else {
            m.captureDate = fileModified
            return m
        }

        m.width = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
        m.height = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        m.orientation = (props[kCGImagePropertyOrientation] as? Int) ?? 1
        // orientations 5–8 rotate 90°/270°, so the displayed geometry transposes the stored
        // pixel dimensions. Report display dimensions to match the transformed thumbnails and
        // the landscape/portrait flag derived from them.
        if (5...8).contains(m.orientation) { swap(&m.width, &m.height) }
        if let model = props[kCGImagePropertyColorModel] as? String {
            m.colorSpace = (props[kCGImagePropertyProfileName] as? String) ?? model
        }
        m.hasICCProfile = props[kCGImagePropertyProfileName] != nil

        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]

        m.camera = cameraName(make: tiff[kCGImagePropertyTIFFMake] as? String,
                              model: tiff[kCGImagePropertyTIFFModel] as? String)
        m.lens = (exif[kCGImagePropertyExifLensModel] as? String) ?? ""
        if let f = (exif[kCGImagePropertyExifFocalLength] as? NSNumber)?.doubleValue { m.focal = Int(f.rounded()) }
        m.aperture = (exif[kCGImagePropertyExifFNumber] as? NSNumber)?.doubleValue ?? 0
        if let exp = (exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue { m.shutter = shutterString(exp) }
        let isoValue = exif[kCGImagePropertyExifISOSpeedRatings] ?? exif["PhotographicSensitivity" as CFString]
        if let iso = isoSpeed(from: isoValue) { m.iso = iso }
        m.author = stringValue(iptc[kCGImagePropertyIPTCByline])
        m.copyright = stringValue(iptc[kCGImagePropertyIPTCCopyrightNotice])
        m.makerNotes = makerNotesSummary(from: props)

        // GPS
        if let lat = (gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue,
           let lon = (gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue {
            let latRef = (gps[kCGImagePropertyGPSLatitudeRef] as? String) ?? "N"
            let lonRef = (gps[kCGImagePropertyGPSLongitudeRef] as? String) ?? "E"
            m.gps = (latRef == "S" ? -lat : lat, lonRef == "W" ? -lon : lon)
        }
        if let altitude = (gps[kCGImagePropertyGPSAltitude] as? NSNumber)?.doubleValue {
            let ref = (gps[kCGImagePropertyGPSAltitudeRef] as? NSNumber)?.intValue ?? 0
            m.gpsAltitude = ref == 1 ? -altitude : altitude
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

    static func isoSpeed(from value: Any?) -> Int? {
        switch value {
        case let values as [Int]:
            return values.first
        case let values as [NSNumber]:
            return values.first?.intValue
        case let values as [Any]:
            return values.lazy.compactMap { ($0 as? NSNumber)?.intValue ?? $0 as? Int }.first
        case let value as NSNumber:
            return value.intValue
        case let value as Int:
            return value
        default:
            return nil
        }
    }

    static func cameraName(make: String?, model: String?) -> String {
        let cleanMake = make?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanModel = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !cleanModel.isEmpty else { return cleanMake }
        guard !cleanMake.isEmpty else { return cleanModel }
        return cleanModel.range(of: cleanMake, options: [.caseInsensitive, .anchored]) != nil
            ? cleanModel : "\(cleanMake) \(cleanModel)"
    }

    private static func stringValue(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let strings = value as? [String] { return strings.joined(separator: ", ") }
        return ""
    }

    static func makerNotesSummary(from props: [CFString: Any]) -> String {
        var entries: [String] = []

        func collect(_ dict: [CFString: Any], includeNestedDictionaries: Bool) {
            for (key, value) in dict where isMakerKey(key) {
                appendEntry(name: cleanKey(key), value: value, into: &entries)
            }
            guard includeNestedDictionaries else { return }
            for (key, value) in dict where isMakerKey(key) {
                guard let nested = value as? [CFString: Any] else { continue }
                collect(nested, includeNestedDictionaries: false)
            }
        }

        collect(props, includeNestedDictionaries: true)
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            collect(exif, includeNestedDictionaries: false)
        }
        return entries.prefix(8).joined(separator: " · ")
    }

    private static func appendEntry(name: String, value: Any, into entries: inout [String]) {
        if let dict = value as? [CFString: Any] {
            let parts = dict
                .sorted { cleanKey($0.key) < cleanKey($1.key) }
                .prefix(6)
                .map { "\(cleanKey($0.key))=\(shortValue($0.value))" }
            if !parts.isEmpty {
                entries.append("\(name): " + parts.joined(separator: ", "))
            }
        } else {
            entries.append("\(name): \(shortValue(value))")
        }
    }

    private static func isMakerKey(_ key: CFString) -> Bool {
        let normalized = cleanKey(key).lowercased()
        return ["maker", "makernote", "canon", "nikon", "sony", "fuji", "olympus", "panasonic", "pentax", "leica"]
            .contains { normalized.contains($0) }
    }

    private static func cleanKey(_ key: CFString) -> String {
        (key as String)
            .replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
            .replacingOccurrences(of: "Dictionary", with: "")
            .replacingOccurrences(of: "kCGImageProperty", with: "")
    }

    private static func shortValue(_ value: Any) -> String {
        if let data = value as? Data { return "\(data.count) bytes" }
        if let string = value as? String { return String(string.prefix(48)) }
        if let number = value as? NSNumber { return number.stringValue }
        if let array = value as? [Any] {
            return array.prefix(4).map { shortValue($0) }.joined(separator: "/")
        }
        return String(String(describing: value).prefix(48))
    }

    // A fresh formatter per call: read() runs on concurrent background queues and
    // DateFormatter is not thread-safe to share.
    private static func exifDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        // EXIF DateTimeOriginal is a timezone-naive wall-clock; anchor it to UTC so the stored
        // instant is stable regardless of the importing machine's timezone (§ capture wall-clock).
        f.timeZone = TimeZone.captureWallClock
        return f.date(from: s)
    }
}
