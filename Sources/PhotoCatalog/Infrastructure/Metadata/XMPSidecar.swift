// ============================================================
//  XMPSidecar — read/write `.xmp` sidecars for cross-app metadata
//  exchange (PRD §6.5 META-006/007). Never modifies the original.
// ============================================================
import Foundation

struct SidecarMetadata: Equatable {
    var rating: Int = 0
    var colorLabel: ColorLabel?
    var keywords: [String] = []
    var title: String = ""
    var caption: String = ""
    var author: String = ""
    var copyright: String = ""
    var captureDate: Date?
    /// Latitude, longitude in degrees.
    var gps: (Double, Double)?

    static func == (l: SidecarMetadata, r: SidecarMetadata) -> Bool {
        l.rating == r.rating && l.colorLabel == r.colorLabel && l.keywords == r.keywords && l.title == r.title
            && l.caption == r.caption && l.author == r.author && l.copyright == r.copyright
            && l.captureDate == r.captureDate && l.gps?.0 == r.gps?.0 && l.gps?.1 == r.gps?.1
    }
}

enum XMPSidecar {
    /// exif:DateTimeOriginal is a wall-clock time; format/parse it in the capture frame (UTC).
    static let exifDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.captureWallClock
        return f
    }()

    /// Sidecar path for an original: `<original>.xmp`.
    static func sidecarURL(for original: URL) -> URL {
        original.deletingPathExtension().appendingPathExtension("xmp")
    }

    /// XMP's GPS form: degrees, decimal minutes and a hemisphere letter ("30,30.500000N").
    static func gpsCoordinate(_ degrees: Double, positive: Character, negative: Character) -> String {
        let value = abs(degrees)
        let whole = Int(value)
        return String(format: "%d,%.6f", whole, (value - Double(whole)) * 60) + String(degrees < 0 ? negative : positive)
    }

    /// Parses "DDD,MM.mmk" or "DDD,MM,SSk"; nil when malformed.
    static func parseGPSCoordinate(_ text: String) -> Double? {
        guard let reference = text.last?.uppercased(), "NSEW".contains(reference) else { return nil }
        let parts = text.dropLast().split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard (2...3).contains(parts.count) else { return nil }
        let degrees = parts[0] + parts[1] / 60 + (parts.count == 3 ? parts[2] / 3600 : 0)
        return reference == "S" || reference == "W" ? -degrees : degrees
    }

    static func xmp(for a: Asset) -> String {
        let label = a.colorLabel.map { $0.rawValue.capitalized } ?? ""
        let gps = a.hasGPS && !(a.gps.0 == 0 && a.gps.1 == 0)
            ? "\n            exif:GPSLatitude=\"\(gpsCoordinate(a.gps.0, positive: "N", negative: "S"))\""
                + "\n            exif:GPSLongitude=\"\(gpsCoordinate(a.gps.1, positive: "E", negative: "W"))\""
            : ""
        let kws = a.keywords.map { "        <rdf:li>\(escape($0))</rdf:li>" }.joined(separator: "\n")
        return """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:exif="http://ns.adobe.com/exif/1.0/"
            xmp:Rating="\(a.rating)"
            xmp:Label="\(escape(label))"
            exif:DateTimeOriginal="\(exifDateFormatter.string(from: a.date))"\(gps)>
           <dc:subject>
            <rdf:Bag>
        \(kws)
            </rdf:Bag>
           </dc:subject>
           <dc:title><rdf:Alt><rdf:li xml:lang="x-default">\(escape(a.title))</rdf:li></rdf:Alt></dc:title>
           <dc:description><rdf:Alt><rdf:li xml:lang="x-default">\(escape(a.caption))</rdf:li></rdf:Alt></dc:description>
           <dc:creator><rdf:Seq><rdf:li>\(escape(a.author))</rdf:li></rdf:Seq></dc:creator>
           <dc:rights><rdf:Alt><rdf:li xml:lang="x-default">\(escape(a.copyright))</rdf:li></rdf:Alt></dc:rights>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }

    @discardableResult
    static func write(_ a: Asset, to url: URL) -> Bool {
        (try? xmp(for: a).data(using: .utf8)?.write(to: url)) != nil
    }

    static func read(_ url: URL) -> SidecarMetadata? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let parser = XMLParser(data: data)
        let delegate = SidecarParser()
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.result
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private final class SidecarParser: NSObject, XMLParserDelegate {
    var result = SidecarMetadata()
    private var path: [String] = []
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attrs: [String: String]) {
        path.append(name)
        text = ""
        if name == "rdf:Description" || name == "Description" {
            if let r = attrs["xmp:Rating"] ?? attrs["Rating"] {
                // Lightroom/Bridge may write "5.0" (Int("5.0") is nil) or "-1" (rejected);
                // parse leniently and clamp into the app's 0…5 range.
                result.rating = min(5, max(0, Int(r) ?? Int(Double(r) ?? 0)))
            }
            if let l = attrs["xmp:Label"] ?? attrs["Label"], !l.isEmpty {
                result.colorLabel = ColorLabel(rawValue: l.lowercased())
            }
            if let d = attrs["exif:DateTimeOriginal"] ?? attrs["DateTimeOriginal"], !d.isEmpty {
                result.captureDate = XMPSidecar.exifDateFormatter.date(from: d)
            }
            if let lat = (attrs["exif:GPSLatitude"] ?? attrs["GPSLatitude"]).flatMap(XMPSidecar.parseGPSCoordinate),
               let lon = (attrs["exif:GPSLongitude"] ?? attrs["GPSLongitude"]).flatMap(XMPSidecar.parseGPSCoordinate) {
                result.gps = (lat, lon)
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let inside = { (tag: String) in self.path.contains { $0.hasSuffix(tag) } }
        if name.hasSuffix("li") && !trimmed.isEmpty {
            if inside("subject") { result.keywords.append(trimmed) }
            else if inside("title") { result.title = trimmed }
            else if inside("description") { result.caption = trimmed }
            else if inside("creator") { result.author = trimmed }
            else if inside("rights") { result.copyright = trimmed }
        }
        path.removeLast()
        text = ""
    }
}
