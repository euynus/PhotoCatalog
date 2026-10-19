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

    // ---------- whose sidecar is whose ----------
    /// Sidecar path for an original: `<name>.xmp` (IMG.xmp), which a RAW+JPEG pair shares. A
    /// file beside another of its name that isn't its pair — a TIFF saved beside its JPEG, a JPEG
    /// converted from a HEIC, a JPEG beside its RAW with pairing off, a Live Photo's MOV — keeps
    /// its own `<name>.<ext>.xmp` (IMG.JPG.xmp, as darktable and digiKam name sidecars), so the
    /// two never write over each other's. `IMG.xmp` stays with the one that owns the name: the
    /// RAW, else a HEIC or JPEG, else the first by extension, and a video only when no photo has it.
    static func sidecarURL(for original: URL) -> URL {
        sidecarURL(for: original, beside: namesakes(of: original), pairing: pairsRawAndJpeg)
    }

    /// The sidecars of many originals: a folder holding many of them is listed once, rather than
    /// looked into for each.
    static func sidecarURLs(for originals: [URL], pairing: Bool = pairsRawAndJpeg) -> [URL] {
        sidecarChoices(for: originals).map { pairing ? $0.paired : $0.unpaired }
    }

    /// The sidecars of many originals with pairing on and off: they differ only for a RAW's JPEG
    /// and the RAW itself.
    static func sidecarChoices(for originals: [URL]) -> [(paired: URL, unpaired: URL)] {
        func choices(_ original: URL, _ namesakes: Set<String>) -> (paired: URL, unpaired: URL) {
            (sidecarURL(for: original, beside: namesakes, pairing: true),
             sidecarURL(for: original, beside: namesakes, pairing: false))
        }
        var sidecars: [(paired: URL, unpaired: URL)] = originals.map { ($0, $0) }
        let byFolder = Dictionary(grouping: originals.indices) { originals[$0].deletingLastPathComponent().path }
        for (folder, indices) in byFolder {
            guard indices.count >= listingThreshold,
                  let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else {
                for index in indices { sidecars[index] = choices(originals[index], namesakes(of: originals[index])) }
                continue
            }
            var extensionsByStem: [String: Set<String>] = [:]
            for name in names {
                let ext = (name as NSString).pathExtension.lowercased()
                guard namesakeExtensions.contains(ext) else { continue }
                extensionsByStem[(name as NSString).deletingPathExtension.lowercased(), default: []].insert(ext)
            }
            for index in indices {
                let original = originals[index]
                let stem = original.deletingPathExtension().lastPathComponent.lowercased()
                sidecars[index] = choices(original, extensionsByStem[stem] ?? [])
            }
        }
        return sidecars
    }

    /// From this many originals in one folder, listing it (a couple of µs a file there) is
    /// quicker than looking for each one's namesakes (a few dozen lookups, ~150 µs each).
    private static let listingThreshold = 2

    /// Whether RAWs and their JPEGs are shown as pairs (Settings): a pair shares one sidecar,
    /// while with pairing off the JPEG is a photo of its own, with a sidecar of its own.
    static var pairsRawAndJpeg: Bool { UserDefaults.app.object(forKey: "pc_pairRawJpeg") as? Bool ?? true }

    /// The formats a file of the same name is looked for in: those the app imports.
    private static let namesakeExtensions: Set<String> = FileScanner.knownExtensions.union(["psd", "psb", "avif", "jxl"])

    /// The extensions (lower case) of the other files beside `original` with its name.
    static func namesakes(of original: URL) -> Set<String> {
        let fm = FileManager.default
        let base = (original.path as NSString).deletingPathExtension
        let own = original.pathExtension.lowercased()
        var found = Set<String>()
        for ext in namesakeExtensions where ext != own {
            // a case-insensitive volume finds either spelling with the first
            if fm.fileExists(atPath: base + "." + ext) || fm.fileExists(atPath: base + "." + ext.uppercased()) {
                found.insert(ext)
            }
        }
        return found
    }

    /// `original`'s sidecar, beside files of its name with the extensions `namesakes`.
    static func sidecarURL(for original: URL, beside namesakes: Set<String>, pairing: Bool) -> URL {
        ownsPlainName(original.pathExtension.lowercased(), beside: namesakes, pairing: pairing)
            ? original.deletingPathExtension().appendingPathExtension("xmp")
            : original.appendingPathExtension("xmp")
    }

    /// Whether a file with the extension `ext` has its name's plain sidecar (`IMG.xmp`), beside
    /// files of that name with the extensions `others` (all lower case).
    static func ownsPlainName(_ ext: String, beside others: Set<String>, pairing: Bool) -> Bool {
        let others = others.subtracting([ext])
        guard !others.isEmpty else { return true }
        let isVideo = { (ext: String) in Asset.videoTypes.contains(ext.uppercased()) }
        let all = others.union([ext])
        // a video beside a photo of its name (a Live Photo's MOV) leaves the name to the photo
        if isVideo(ext), all.contains(where: { !isVideo($0) }) { return false }
        if pairing, !isVideo(ext) {
            // a RAW and its JPEG/HEIC are one photo and share it; any other file beside them doesn't
            let raws = all.filter { FileScanner.isRaw(extension: $0) }
            let companions = all.filter { AssetPairing.companionExtensions.contains($0) }
            if raws.count == 1, !companions.isEmpty { return raws.contains(ext) || companions.contains(ext) }
        }
        func rank(_ ext: String) -> Int {
            isVideo(ext) ? 3 : FileScanner.isRaw(extension: ext) ? 0 : AssetPairing.companionExtensions.contains(ext) ? 1 : 2
        }
        return all.min { (rank($0), $0) < (rank($1), $1) } == ext
    }

    /// Moves an original's sidecar with it (`original` is where the file was, `moved` where it
    /// is now). True when it moved or there was none; a RAW+JPEG pair shares one sidecar, which
    /// the first file of the pair takes along.
    @discardableResult
    static func moveSidecar(from original: URL, to moved: URL) -> Bool {
        moveSidecar(at: sidecarURL(for: original), to: sidecarURL(for: moved))
    }

    /// Moves the sidecar at `source` to `target`; true when it moved or there was none. Another
    /// file's sidecar at `target` is never replaced.
    @discardableResult
    static func moveSidecar(at source: URL, to target: URL) -> Bool {
        let fm = FileManager.default
        guard source.path != target.path, fm.fileExists(atPath: source.path) else { return true }
        // another file's sidecar is never replaced (a change of case only is the same file)
        guard !fm.fileExists(atPath: target.path) || source.path.lowercased() == target.path.lowercased() else {
            return false
        }
        return (try? fm.moveItem(at: source, to: target)) != nil
    }

    /// XMP's GPS form: degrees, decimal minutes and a hemisphere letter ("30,30.500000N").
    static func gpsCoordinate(_ degrees: Double, positive: Character, negative: Character) -> String {
        let value = abs(degrees)
        // whole degrees as a Double: converting a value that isn't a place on Earth to Int traps
        let whole = value.rounded(.towardZero)
        return String(format: "%.0f,%.6f", whole, (value - whole) * 60) + String(degrees < 0 ? negative : positive)
    }

    /// Parses "DDD,MM.mmk" or "DDD,MM,SSk"; nil when malformed, or when it isn't a latitude
    /// (N, S) within 90° or a longitude (E, W) within 180°.
    static func parseGPSCoordinate(_ text: String) -> Double? {
        guard let reference = text.last?.uppercased(), "NSEW".contains(reference) else { return nil }
        let parts = text.dropLast().split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard (2...3).contains(parts.count) else { return nil }
        let degrees = parts[0] + parts[1] / 60 + (parts.count == 3 ? parts[2] / 3600 : 0)
        guard degrees.isFinite, abs(degrees) <= (reference == "N" || reference == "S" ? 90 : 180) else { return nil }
        return reference == "S" || reference == "W" ? -degrees : degrees
    }

    /// Whether `gps` (latitude, longitude) is a place on Earth: finite, and within 90° and 180°.
    static func isValidLocation(_ gps: (Double, Double)) -> Bool {
        gps.0.isFinite && gps.1.isFinite && abs(gps.0) <= 90 && abs(gps.1) <= 180
    }

    static func xmp(for a: Asset) -> String {
        let label = a.colorLabel.map { $0.rawValue.capitalized } ?? ""
        // a location that isn't on Earth (read by an older version from a malformed sidecar) is left out
        let gps = a.hasGPS && !(a.gps.0 == 0 && a.gps.1 == 0) && isValidLocation(a.gps)
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

    /// Properties that hold several items, of which the photo has one: a title, caption or
    /// copyright in several languages (the photo's is the default language's), and a list of
    /// creators (the photo's author is the first). Writing replaces that one and keeps the rest.
    private static let singleItemProperties: Set<String> = ["dc:title", "dc:description", "dc:rights", "dc:creator"]

    /// `existing` with this app's properties replaced by the photo's, everything else kept;
    /// nil when it isn't XMP that can be edited (it's then written afresh).
    static func merged(_ a: Asset, into existing: Data) -> String? {
        guard let document = try? XMLDocument(data: existing, options: [.nodePreserveAll]),
              let ours = try? XMLDocument(xmlString: xmp(for: a), options: []),
              let ourDescription = (try? ours.nodes(forXPath: "//*[local-name()='Description']"))?.first as? XMLElement,
              let descriptions = (try? document.nodes(forXPath: "//*[local-name()='Description']")) as? [XMLElement],
              let target = descriptions.first ?? emptyDescription(in: document) else { return nil }
        // take our properties out wherever another description carries them, attribute or element,
        // keeping the items of theirs the photo doesn't have (other languages, other creators)
        var otherItems: [String: [XMLNode]] = [:]
        for description in descriptions {
            for name in managedProperties { description.removeAttribute(forName: name) }
            for child in description.children ?? [] where managedProperties.contains(child.name ?? "") {
                if let name = child.name, singleItemProperties.contains(name), otherItems[name] == nil,
                   let element = child as? XMLElement {
                    otherItems[name] = itemsBesideThePhotos(in: element)
                }
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
            let copy = child.copy() as! XMLNode
            if let items = otherItems[child.name ?? ""], !items.isEmpty,
               let container = copy.children?.first(where: { $0.kind == .element }) as? XMLElement {
                for item in items { container.addChild(item) }
            }
            target.addChild(copy)
        }
        return document.xmlString(options: [.nodePreserveAll])
    }

    /// Copies of the items of `property` (an rdf:Alt or rdf:Seq) other than the one the photo
    /// has: every language but the default, or every creator but the first.
    private static func itemsBesideThePhotos(in property: XMLElement) -> [XMLNode] {
        guard let container = property.children?.first(where: { $0.kind == .element }) as? XMLElement else { return [] }
        let items = (container.children ?? []).compactMap { $0 as? XMLElement }.filter { $0.localName == "li" }
        let others = container.localName == "Alt"
            ? items.filter { $0.attribute(forName: "xml:lang")?.stringValue?.lowercased() != "x-default" }
            : Array(items.dropFirst())
        return others.map { $0.copy() as! XMLNode }
    }

    /// A new, empty rdf:Description for XMP that has none yet (an empty rdf:RDF, or an
    /// x:xmpmeta with nothing in it); nil when `document` isn't XMP at all.
    private static func emptyDescription(in document: XMLDocument) -> XMLElement? {
        let rdfURI = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
        var rdf = (try? document.nodes(forXPath: "//*[local-name()='RDF']"))?.first as? XMLElement
        if rdf == nil, let root = document.rootElement(), root.localName == "xmpmeta" {
            let created = XMLElement(name: "rdf:RDF", uri: rdfURI)
            created.addNamespace(XMLNode.namespace(withName: "rdf", stringValue: rdfURI) as! XMLNode)
            root.addChild(created)
            rdf = created
        }
        guard let rdf else { return nil }
        // the prefix the document gives the RDF namespace (rdf: almost always)
        let prefix = rdf.resolvePrefix(forNamespaceURI: rdfURI).map { $0.isEmpty ? "" : $0 + ":" } ?? "rdf:"
        let description = XMLElement(name: prefix + "Description", uri: rdfURI)
        description.addAttribute(XMLNode.attribute(withName: prefix + "about", uri: rdfURI, stringValue: "") as! XMLNode)
        rdf.addChild(description)
        return description
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

    /// Whether `sc` says what `asset` does: reading it (as Read Metadata from Files does) would
    /// leave the photo's rating, label, keywords, text, credits, capture time and location as
    /// they are. Times are written to the second, so they agree within one.
    static func agrees(_ sc: SidecarMetadata, with asset: Asset) -> Bool {
        var read = asset
        apply(sc, to: &read, replacingKeywords: true)
        return read.rating == asset.rating && read.colorLabel == asset.colorLabel
            && Set(read.keywords) == Set(asset.keywords) && read.title == asset.title
            && read.caption == asset.caption && read.author == asset.author && read.copyright == asset.copyright
            && abs(read.date.timeIntervalSince(asset.date)) < 1
            && abs(read.gps.0 - asset.gps.0) < 1e-6 && abs(read.gps.1 - asset.gps.1) < 1e-6
    }

    /// The sidecar's modification time, or nil when there's none.
    static func modificationTime(forOriginal path: String) -> Double? {
        modificationTime(of: sidecarURL(for: URL(fileURLWithPath: path)))
    }

    /// A sidecar's modification time (seconds since 1970), or nil when it isn't there.
    static func modificationTime(of sidecar: URL) -> Double? {
        ((try? FileManager.default.attributesOfItem(atPath: sidecar.path))?[.modificationDate] as? Date)?
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
    /// The language of the rdf:li being read, and the text properties already read: from a
    /// language alternative the default language's item counts (else the first), from a list of
    /// creators the first.
    private var language: String?
    private var readFromDefault: Set<String> = []
    private var read: Set<String> = []

    private func property(_ name: String, _ value: String) {
        switch name {
        case "xmp:Rating", "xap:Rating", "Rating":
            // Lightroom/Bridge may write "5.0" (Int("5.0") is nil) or "-1" (rejected, unrated
            // here); anything that isn't a number from -1 to 5 is another app's mistake, ignored
            guard let number = Double(value), number.isFinite, (-1...5).contains(number) else { return }
            result.rating = max(0, Int(number))
        case "xmp:Label", "xap:Label", "Label":
            result.label = value
        case "exif:DateTimeOriginal", "DateTimeOriginal":
            // a wall-clock time; any fraction or zone after the seconds doesn't move it
            if let date = XMPSidecar.exifDateFormatter.date(from: String(value.prefix(19))) { result.captureDate = date }
        case "exif:GPSLatitude", "GPSLatitude":
            latitude = XMPSidecar.parseGPSCoordinate(value).flatMap { abs($0) <= 90 ? $0 : nil }
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
        if name.hasSuffix("li") { language = attrs["xml:lang"] }
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
        if name.hasSuffix("li") {
            if inside("subject") {
                if !trimmed.isEmpty { result.keywords.append(trimmed) }
            } else if let property = ["title", "description", "creator", "rights"].first(where: inside) {
                textItem(trimmed, of: property)
            }
        }
        path.removeLast()
        text = ""
    }

    private func textItem(_ value: String, of property: String) {
        let isDefault = property != "creator" && language?.lowercased() == "x-default"
        guard isDefault ? !readFromDefault.contains(property) : !read.contains(property) else { return }
        if isDefault { readFromDefault.insert(property) }
        read.insert(property)
        switch property {
        case "title": result.title = value
        case "description": result.caption = value
        case "creator": result.author = value
        default: result.copyright = value
        }
    }
}
