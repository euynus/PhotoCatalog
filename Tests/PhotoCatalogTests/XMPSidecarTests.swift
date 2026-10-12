import XCTest
@testable import PhotoCatalog

/// Reading and writing `.xmp` sidecars: other apps' sidecars, however they're written, are
/// read safely and keep what they hold when this app writes its properties into them.
final class XMPSidecarTests: XCTestCase {
    private var scratch: URL!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("pc-xmp-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        super.tearDown()
    }

    private func sample() -> Asset {
        var asset = DemoData.assets[1]
        asset.isDemo = false
        asset.rating = 4
        asset.colorLabel = .red
        asset.keywords = ["trip"]
        asset.title = "Title"
        asset.caption = "Caption"
        asset.author = "Author"
        asset.copyright = "© Author"
        return asset
    }

    private func sidecar(_ name: String, _ text: String) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// Another app's sidecar with an empty rdf:RDF (or none at all) is still XMP: the photo's
    /// properties go into a description of their own, and what else is there stays.
    func testSidecarWithoutDescriptionIsWritten() throws {
        let url = try sidecar("empty.xmp", """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Other App 1.0">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """)
        XCTAssertTrue(XMPSidecar.write(sample(), to: url), "the sidecar is written")
        let read = try XCTUnwrap(XMPSidecar.read(url))
        XCTAssertEqual(read.rating, 4)
        XCTAssertEqual(read.keywords, ["trip"])
        XCTAssertEqual(read.title, "Title")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("Other App 1.0"), "the rest is kept")
        XCTAssertTrue(text.contains("<rdf:Description ") && text.contains("rdf:about="), text)

        let bare = try sidecar("bare.xmp", #"<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Bare"/>"#)
        XCTAssertTrue(XMPSidecar.write(sample(), to: bare), "an xmpmeta without rdf:RDF is written too")
        XCTAssertEqual(XMPSidecar.read(bare)?.rating, 4)
        XCTAssertTrue(try String(contentsOf: bare, encoding: .utf8).contains("Bare"))

        let other = try sidecar("other.xmp", "<notes><note>not XMP</note></notes>")
        XCTAssertFalse(XMPSidecar.write(sample(), to: other), "XML that isn't XMP is still left alone")
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "<notes><note>not XMP</note></notes>")
    }

    private func description(_ attributes: String) throws -> URL {
        try sidecar("\(UUID().uuidString).xmp", """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
         <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/"
           xmlns:exif="http://ns.adobe.com/exif/1.0/" \(attributes)/>
        </rdf:RDF></x:xmpmeta>
        """)
    }

    /// A rating that isn't a number from -1 (rejected) to 5 is ignored, not trusted.
    func testMalformedRatingIsIgnored() throws {
        for value in ["1e20", "-1e20", "nan", "inf", "7", "-2"] {
            let read = XMPSidecar.read(try description(#"xmp:Rating="\#(value)""#))
            XCTAssertNotNil(read, value)
            XCTAssertNil(read?.rating, "rating \(value) is ignored")
        }
        XCTAssertEqual(XMPSidecar.read(try description(#"xmp:Rating="5.0""#))?.rating, 5)
        XCTAssertEqual(XMPSidecar.read(try description(#"xmp:Rating="-1""#))?.rating, 0, "rejected reads as unrated")
        XCTAssertEqual(XMPSidecar.read(try description(#"xmp:Rating="3""#))?.rating, 3)
    }

    /// A location that isn't on Earth — not finite, or past the poles or the date line — is
    /// ignored, and the rest of the sidecar is still read.
    func testMalformedLocationIsIgnored() throws {
        for (latitude, longitude) in [("inf,0N", "10,0E"), ("1e300,0N", "10,0E"), ("nan,0N", "10,0E"),
                                      ("91,0N", "10,0E"), ("10,0N", "181,0E"), ("10,0N", "0,1e300W")] {
            let read = XMPSidecar.read(try description(
                #"exif:GPSLatitude="\#(latitude)" exif:GPSLongitude="\#(longitude)" xmp:Rating="2""#))
            XCTAssertNil(read?.gps, "\(latitude) \(longitude) is ignored")
            XCTAssertEqual(read?.rating, 2)
        }
        let valid = XMPSidecar.read(try description(#"exif:GPSLatitude="30,30.0N" exif:GPSLongitude="122,15.0W""#))
        XCTAssertEqual(valid?.gps?.0, 30.5)
        XCTAssertEqual(valid?.gps?.1, -122.25)
    }

    /// A photo whose location isn't on Earth (from a sidecar an older version read) is written
    /// without one rather than stopping the app.
    func testImpossibleLocationIsNotWritten() throws {
        for gps in [(Double.infinity, 10.0), (1e300, 10), (10, -.nan), (95, 10), (10, 200)] {
            var asset = sample()
            asset.gps = gps
            let url = scratch.appendingPathComponent("\(UUID().uuidString).xmp")
            XCTAssertTrue(XMPSidecar.write(asset, to: url))
            let read = XMPSidecar.read(url)
            XCTAssertNil(read?.gps, "\(gps) isn't written")
            XCTAssertEqual(read?.rating, 4)
        }
    }

    /// The metadata JSON exported beside originals leaves such a location out too.
    func testImpossibleLocationIsLeftOutOfExportedMetadata() throws {
        var asset = sample()
        asset.gps = (.nan, .infinity)
        let url = scratch.appendingPathComponent("metadata.json")
        XCTAssertTrue(ExportService.exportMetadataJSON([asset], to: url))
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        XCTAssertTrue(rows.first?["gpsLatitude"] is NSNull)
        XCTAssertTrue(rows.first?["gpsLongitude"] is NSNull)
    }

    /// Another app's titles in several languages and its several creators: the photo's title is
    /// the default-language one and its author the first creator, and writing changes just
    /// those, keeping the other languages and creators.
    func testOtherLanguagesAndCreatorsSurviveAWrite() throws {
        let url = try sidecar("languages.xmp", """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
         <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/">
          <dc:title><rdf:Alt>
           <rdf:li xml:lang="x-default">Hallo</rdf:li>
           <rdf:li xml:lang="de">Titel</rdf:li>
           <rdf:li xml:lang="en">Title in English</rdf:li>
          </rdf:Alt></dc:title>
          <dc:description><rdf:Alt>
           <rdf:li xml:lang="x-default">Beschreibung</rdf:li>
           <rdf:li xml:lang="ja">キャプション</rdf:li>
          </rdf:Alt></dc:description>
          <dc:creator><rdf:Seq><rdf:li>Alice</rdf:li><rdf:li>Bob</rdf:li></rdf:Seq></dc:creator>
          <dc:rights><rdf:Alt>
           <rdf:li xml:lang="fr">Tous droits réservés</rdf:li>
           <rdf:li xml:lang="x-default">All rights reserved</rdf:li>
          </rdf:Alt></dc:rights>
         </rdf:Description></rdf:RDF></x:xmpmeta>
        """)
        let read = try XCTUnwrap(XMPSidecar.read(url))
        XCTAssertEqual(read.title, "Hallo", "the default-language title")
        XCTAssertEqual(read.caption, "Beschreibung")
        XCTAssertEqual(read.author, "Alice", "the first creator")
        XCTAssertEqual(read.copyright, "All rights reserved", "the default language, wherever it's listed")

        var edited = sample()
        edited.title = "New title"
        edited.caption = "Beschreibung"
        edited.author = "Carol"
        edited.copyright = "All rights reserved"
        XCTAssertTrue(XMPSidecar.write(edited, to: url))
        let text = try String(contentsOf: url, encoding: .utf8)
        for kept in ["Titel", "Title in English", "キャプション", "Bob", "Tous droits réservés"] {
            XCTAssertTrue(text.contains(kept), "\(kept) is kept")
        }
        XCTAssertFalse(text.contains("Hallo"), "the default-language title is replaced")
        XCTAssertFalse(text.contains("Alice"), "the first creator is replaced")
        let again = try XCTUnwrap(XMPSidecar.read(url))
        XCTAssertEqual(again.title, "New title")
        XCTAssertEqual(again.author, "Carol")
        XCTAssertEqual(again.copyright, "All rights reserved")

        XCTAssertTrue(XMPSidecar.write(edited, to: url))
        let rewritten = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(rewritten.components(separatedBy: "Title in English").count, 2, "a second write adds nothing")
        XCTAssertEqual(rewritten.components(separatedBy: "Bob").count, 2)
    }
}
