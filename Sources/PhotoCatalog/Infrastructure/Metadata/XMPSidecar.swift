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
}

enum XMPSidecar {
    /// Sidecar path for an original: `<original>.xmp`.
    static func sidecarURL(for original: URL) -> URL {
        original.deletingPathExtension().appendingPathExtension("xmp")
    }

    static func xmp(for a: Asset) -> String {
        let label = a.colorLabel.map { $0.rawValue.capitalized } ?? ""
        let kws = a.keywords.map { "        <rdf:li>\(escape($0))</rdf:li>" }.joined(separator: "\n")
        return """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmp:Rating="\(a.rating)"
            xmp:Label="\(escape(label))">
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
            if let r = attrs["xmp:Rating"] ?? attrs["Rating"] { result.rating = Int(r) ?? 0 }
            if let l = attrs["xmp:Label"] ?? attrs["Label"], !l.isEmpty {
                result.colorLabel = ColorLabel(rawValue: l.lowercased())
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
