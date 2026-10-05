// ============================================================
//  XMPSidecar — read/write `.xmp` sidecars for cross-app metadata
//  exchange (PRD §6.5 META-006/007). Never modifies the original.
// ============================================================
import Foundation

struct SidecarMetadata: Equatable {
    /// The rating and label as the sidecar has them, nil when it doesn't say: an app that
    /// writes only keywords leaves the photo's rating and label alone. An empty label is one
    /// taken off.
    var rating: Int?
    var label: String?
    var keywords: [String] = []
    var title: String = ""
    var caption: String = ""
    var author: String = ""
    var copyright: String = ""
    var captureDate: Date?
    /// Latitude, longitude in degrees.
    var gps: (Double, Double)?

    /// The label, when it's one of the app's colors (Lightroom's default label set).
    var colorLabel: ColorLabel? { label.flatMap { ColorLabel(rawValue: $0.lowercased()) } }

    static func == (l: SidecarMetadata, r: SidecarMetadata) -> Bool {
        l.rating == r.rating && l.label == r.label && l.keywords == r.keywords && l.title == r.title
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

    /// Sidecar path for an original: `<original>.xmp`. A video beside a photo of the same name
    /// (a Live Photo's HEIC and MOV) keeps its own, `<original>.<ext>.xmp`, so it never
    /// overwrites the photo's.
    static func sidecarURL(for original: URL) -> URL {
        let plain = original.deletingPathExtension().appendingPathExtension("xmp")
        guard VideoMetadata.isVideo(original) else { return plain }
        let stem = original.deletingPathExtension().lastPathComponent.lowercased()
        let siblings = (try? FileManager.default.contentsOfDirectory(atPath: original.deletingLastPathComponent().path)) ?? []
        let photoBeside = siblings.contains { name in
            let url = URL(fileURLWithPath: name)
            return url.deletingPathExtension().lastPathComponent.lowercased() == stem && !VideoMetadata.isVideo(url)
                && url.pathExtension.lowercased() != "xmp" && FileScanner.isSupported(url)
        }
        return photoBeside ? original.appendingPathExtension("xmp") : plain
    }

    /// Moves an original's sidecar with it (`original` is where the file was, `moved` where it
    /// is now). True when it moved or there was none; a RAW+JPEG pair shares one sidecar, which
    /// the first file of the pair takes along.
    @discardableResult
    static func moveSidecar(from original: URL, to moved: URL) -> Bool {
        let fm = FileManager.default
        let source = sidecarURL(for: original), target = sidecarURL(for: moved)
        guard source.path != target.path, fm.fileExists(atPath: source.path) else { return true }
        // another file's sidecar is never replaced (a change of case only is the same file)
        guard !fm.fileExists(atPath: target.path) || source.path.lowercased() == target.path.lowercased() else {
            return false
        }
        return (try? fm.moveItem(at: source, to: target)) != nil
    }

    /// Copies an original's sidecar beside a copy of it, unless one is already there.
    static func copySidecar(from original: URL, to copy: URL) {
        let fm = FileManager.default
        let source = sidecarURL(for: original), target = sidecarURL(for: copy)
        guard fm.fileExists(atPath: source.path), !fm.fileExists(atPath: target.path) else { return }
        try? fm.copyItem(at: source, to: target)
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

    /// Writes the photo's sidecar. An existing one — perhaps another app's, with its own develop
    /// settings or history — keeps everything but the properties this app writes; the file is
    /// replaced atomically. One that can't be read or edited as XMP is left alone (false):
    /// replacing it would lose whatever another app keeps there.
    @discardableResult
    static func write(_ a: Asset, to url: URL) -> Bool {
        let text: String
        if let existing = try? Data(contentsOf: url), !existing.isEmpty {
            guard let merged = merged(a, into: existing) else { return false }
            text = merged
        } else if FileManager.default.fileExists(atPath: url.path), (try? Data(contentsOf: url)) == nil {
            return false
        } else {
            text = xmp(for: a)
        }
        return (try? text.data(using: .utf8)?.write(to: url, options: .atomic)) != nil
    }

    /// The properties this app writes, as attributes or elements of an rdf:Description.
    private static let managedProperties: Set<String> = [
        // xap: is the XMP namespace's older prefix: the same properties, written by older apps
        "xmp:Rating", "xmp:Label", "xap:Rating", "xap:Label",
        "exif:DateTimeOriginal", "exif:GPSLatitude", "exif:GPSLongitude",
        "dc:subject", "dc:title", "dc:description", "dc:creator", "dc:rights",
    ]

    /// `existing` with this app's properties replaced by the photo's, everything else kept;
    /// nil when it isn't XMP that can be edited (it's then written afresh).
    static func merged(_ a: Asset, into existing: Data) -> String? {
        guard let document = try? XMLDocument(data: existing, options: [.nodePreserveAll]),
              let ours = try? XMLDocument(xmlString: xmp(for: a), options: []),
              let ourDescription = (try? ours.nodes(forXPath: "//*[local-name()='Description']"))?.first as? XMLElement,
              let descriptions = (try? document.nodes(forXPath: "//*[local-name()='Description']")) as? [XMLElement],
              let target = descriptions.first else { return nil }
        // take our properties out wherever another description carries them, attribute or element
        for description in descriptions {
            for name in managedProperties { description.removeAttribute(forName: name) }
            for child in description.children ?? [] where managedProperties.contains(child.name ?? "") {
                child.detach()
            }
        }
        for namespace in ourDescription.namespaces ?? [] {
            guard let prefix = namespace.name, let uri = namespace.stringValue,
                  target.resolveNamespace(forName: prefix + ":x")?.stringValue != uri else { continue }
            target.addNamespace(XMLNode.namespace(withName: prefix, stringValue: uri) as! XMLNode)
        }
        for attribute in ourDescription.attributes ?? [] where attribute.name != "rdf:about" {
            target.addAttribute(attribute.copy() as! XMLNode)
        }
        for child in ourDescription.children ?? [] where child.kind == .element {
            target.addChild(child.copy() as! XMLNode)
        }
        return document.xmlString(options: [.nodePreserveAll])
    }

    /// Applies a sidecar's metadata to `asset`: the sidecar's rating, label, text, credits,
    /// capture time and location win where it has them; its keywords are merged ahead of the
    /// photo's own, or replace them when `replacingKeywords` (reading changes another app made).
    static func apply(_ sc: SidecarMetadata, to asset: inout Asset, replacingKeywords: Bool = false) {
        if let rating = sc.rating { asset.rating = rating }
        if let label = sc.label {
            // a label outside the app's colors (a custom Lightroom set) leaves the photo's alone
            if label.isEmpty { asset.colorLabel = nil } else if let color = sc.colorLabel { asset.colorLabel = color }
        }
        if !sc.keywords.isEmpty {
            asset.keywords = replacingKeywords ? KeywordService.normalize(sc.keywords)
                                               : KeywordService.normalize(sc.keywords + asset.keywords)
        }
        if !sc.title.isEmpty { asset.title = sc.title }
        if !sc.caption.isEmpty { asset.caption = sc.caption }
        if !sc.author.isEmpty { asset.author = sc.author }
        if !sc.copyright.isEmpty { asset.copyright = sc.copyright }
        // a capture-time correction made in another app (or mirrored by us) takes precedence
        if let d = sc.captureDate { asset.date = d; asset.captureDateSource = "sidecar" }
        // a location set in another app (or by us) travels in the sidecar
        if let gps = sc.gps {
            asset.gps = gps
            asset.location = Asset.locationLabel(gps)
        }
    }

    /// The sidecar's modification time, or nil when there's none.
    static func modificationTime(forOriginal path: String) -> Double? {
        let sidecar = sidecarURL(for: URL(fileURLWithPath: path))
        return ((try? FileManager.default.attributesOfItem(atPath: sidecar.path))?[.modificationDate] as? Date)?
            .timeIntervalSince1970
    }

    static func read(_ url: URL) -> SidecarMetadata? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let parser = XMLParser(data: data)
        let delegate = SidecarParser()
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.result
    }

    /// Text made safe for XML: markup escaped, and control characters XML can't hold at all
    /// left out (one would make the sidecar unreadable, to us and to every other app).
    static func escape(_ s: String) -> String {
        let allowed = s.unicodeScalars.filter { scalar in
            let v = scalar.value
            return v == 0x9 || v == 0xA || v == 0xD || (v >= 0x20 && v != 0xFFFE && v != 0xFFFF)
        }
        return String(String.UnicodeScalarView(allowed))
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Reads the properties the app keeps, written as attributes of an rdf:Description (as
/// Lightroom does) or as elements inside it (as other apps do), under xmp: or the older xap:.
private final class SidecarParser: NSObject, XMLParserDelegate {
    var result = SidecarMetadata()
    private var path: [String] = []
    private var text = ""
    private var latitude: Double?
    private var longitude: Double?

    private func property(_ name: String, _ value: String) {
        switch name {
        case "xmp:Rating", "xap:Rating", "Rating":
            // Lightroom/Bridge may write "5.0" (Int("5.0") is nil) or "-1" (rejected);
            // parse leniently and clamp into the app's 0…5 range.
            guard !value.isEmpty else { return }
            result.rating = min(5, max(0, Int(value) ?? Int(Double(value) ?? 0)))
        case "xmp:Label", "xap:Label", "Label":
            result.label = value
        case "exif:DateTimeOriginal", "DateTimeOriginal":
            // a wall-clock time; any fraction or zone after the seconds doesn't move it
            if let date = XMPSidecar.exifDateFormatter.date(from: String(value.prefix(19))) { result.captureDate = date }
        case "exif:GPSLatitude", "GPSLatitude":
            latitude = XMPSidecar.parseGPSCoordinate(value)
        case "exif:GPSLongitude", "GPSLongitude":
            longitude = XMPSidecar.parseGPSCoordinate(value)
        default:
            return
        }
        if let latitude, let longitude { result.gps = (latitude, longitude) }
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attrs: [String: String]) {
        path.append(name)
        text = ""
        if name == "rdf:Description" || name == "Description" {
            for (key, value) in attrs { property(key, value) }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let inside = { (tag: String) in self.path.contains { $0.hasSuffix(tag) } }
        // a property written as an element of the description
        if path.count >= 2, path[path.count - 2].hasSuffix("Description") { property(name, trimmed) }
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
