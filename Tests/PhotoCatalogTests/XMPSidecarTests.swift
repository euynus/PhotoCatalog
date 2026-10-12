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
}
