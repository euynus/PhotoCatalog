import XCTest
@testable import PhotoCatalog

/// An Asset is one reference to shared, copy-on-write storage: every field reads what it was
/// given and writes only itself; copies share the storage until one of them changes, which then
/// copies it once; a virtual copy and an undo's `takeChanges` carry exactly the fields they did.
final class AssetStorageTests: XCTestCase {
    private let shot = Date(timeIntervalSinceReferenceDate: 700_000_000.25)

    /// Every field differs from the initializer's defaults and from the others.
    private var sample: Asset {
        Asset(id: "a1", pid: 7, ori: "p", thumb: "/cache/t.jpg", preview: "/cache/p.jpg", filename: "IMG_1.CR3",
              type: "CR3", isRaw: true, folderId: "f1", folderName: "Trip", date: shot, width: 6000, height: 4000,
              orientation: 6, camera: "Canon EOS R5", lens: "RF50mm", focal: 50, aperture: 1.2, shutter: "1/250",
              iso: 400, colorSpace: "Adobe RGB", hasICCProfile: true, fileMB: 31.5,
              fileModifiedAt: shot.addingTimeInterval(60), fileCreatedAt: shot.addingTimeInterval(30), rating: 4,
              flag: .pick, colorLabel: .green, keywords: ["a", "b"], title: "Title", caption: "Caption",
              author: "Me", copyright: "© Me", makerNotes: "notes", project: "Proj", client: "Client",
              location: "Tokyo", gps: (35.6, 139.7), gpsAltitude: 40, status: .offline,
              importedAt: shot.addingTimeInterval(3600), deleted: true, localPath: "/photos/IMG_1.CR3",
              captureDateSource: "XMP", contentHash: "sha", quickHash: "quick", isDemo: false, faces: 3,
              perceptualHash: 0xdead_beef, masterId: "m0", copyName: "副本 9", duration: 12.5)
    }

    /// Every field by name, as text.
    private func fields(_ a: Asset) -> [String: String] {
        func text(_ value: Any) -> String { String(describing: value) }
        return [
            "id": a.id, "pid": text(a.pid), "ori": a.ori, "thumb": a.thumb, "preview": a.preview,
            "filename": a.filename, "type": a.type, "isRaw": text(a.isRaw), "folderId": a.folderId,
            "folderName": a.folderName, "date": text(a.date.timeIntervalSinceReferenceDate), "width": text(a.width),
            "height": text(a.height), "orientation": text(a.orientation), "camera": a.camera, "lens": a.lens,
            "focal": text(a.focal), "aperture": text(a.aperture), "shutter": a.shutter, "iso": text(a.iso),
            "colorSpace": a.colorSpace, "hasICCProfile": text(a.hasICCProfile), "fileMB": text(a.fileMB),
            "fileModifiedAt": text(a.fileModifiedAt?.timeIntervalSinceReferenceDate as Any),
            "fileCreatedAt": text(a.fileCreatedAt?.timeIntervalSinceReferenceDate as Any),
            "rating": text(a.rating), "flag": text(a.flag), "colorLabel": text(a.colorLabel as Any),
            "keywords": text(a.keywords), "title": a.title, "caption": a.caption, "author": a.author,
            "copyright": a.copyright, "makerNotes": a.makerNotes, "project": a.project, "client": a.client,
            "location": a.location, "gps": text(a.gps), "gpsAltitude": text(a.gpsAltitude as Any),
            "status": text(a.status), "importedAt": text(a.importedAt.timeIntervalSinceReferenceDate),
            "deleted": text(a.deleted), "localPath": text(a.localPath as Any), "captureDateSource": a.captureDateSource,
            "contentHash": text(a.contentHash as Any), "quickHash": text(a.quickHash as Any), "isDemo": text(a.isDemo),
            "faces": text(a.faces), "perceptualHash": text(a.perceptualHash as Any), "masterId": text(a.masterId as Any),
            "copyName": text(a.copyName as Any), "duration": text(a.duration as Any),
        ]
    }

    /// Each settable field, set to a value none of the sample's has.
    private static let writes: [(name: String, write: @Sendable (inout Asset) -> Void)] = [
        ("filename", { $0.filename = "NEW.CR3" }), ("folderId", { $0.folderId = "f2" }),
        ("folderName", { $0.folderName = "Home" }), ("date", { $0.date = Date(timeIntervalSinceReferenceDate: 1) }),
        ("hasICCProfile", { $0.hasICCProfile = false }), ("fileMB", { $0.fileMB = 2.25 }),
        ("fileModifiedAt", { $0.fileModifiedAt = nil }), ("fileCreatedAt", { $0.fileCreatedAt = Date(timeIntervalSinceReferenceDate: 2) }),
        ("rating", { $0.rating = 1 }), ("flag", { $0.flag = .reject }), ("colorLabel", { $0.colorLabel = nil }),
        ("keywords", { $0.keywords = ["z"] }), ("title", { $0.title = "T2" }), ("caption", { $0.caption = "C2" }),
        ("author", { $0.author = "You" }), ("copyright", { $0.copyright = "© You" }),
        ("makerNotes", { $0.makerNotes = "" }), ("project", { $0.project = "P2" }), ("client", { $0.client = "C3" }),
        ("location", { $0.location = "Oslo" }), ("gps", { $0.gps = (59.9, 10.7) }), ("gpsAltitude", { $0.gpsAltitude = nil }),
        ("status", { $0.status = .missing }), ("importedAt", { $0.importedAt = Date(timeIntervalSinceReferenceDate: 3) }),
        ("deleted", { $0.deleted = false }), ("localPath", { $0.localPath = "/elsewhere/NEW.CR3" }),
        ("captureDateSource", { $0.captureDateSource = "File" }), ("contentHash", { $0.contentHash = nil }),
        ("quickHash", { $0.quickHash = "q2" }), ("isDemo", { $0.isDemo = true }), ("faces", { $0.faces = 0 }),
        ("perceptualHash", { $0.perceptualHash = 1 }), ("masterId", { $0.masterId = nil }),
        ("copyName", { $0.copyName = "副本 2" }),
    ]

    private func storage(_ a: Asset) -> ObjectIdentifier {
        ObjectIdentifier(Mirror(reflecting: a).descendant("storage") as AnyObject)
    }

    func testEveryFieldReadsWhatItWasGiven() {
        XCTAssertEqual(fields(sample), [
            "id": "a1", "pid": "7", "ori": "p", "thumb": "/cache/t.jpg", "preview": "/cache/p.jpg",
            "filename": "IMG_1.CR3", "type": "CR3", "isRaw": "true", "folderId": "f1", "folderName": "Trip",
            "date": "700000000.25", "width": "6000", "height": "4000", "orientation": "6", "camera": "Canon EOS R5",
            "lens": "RF50mm", "focal": "50", "aperture": "1.2", "shutter": "1/250", "iso": "400",
            "colorSpace": "Adobe RGB", "hasICCProfile": "true", "fileMB": "31.5", "fileModifiedAt": "Optional(700000060.25)",
            "fileCreatedAt": "Optional(700000030.25)", "rating": "4", "flag": "pick", "colorLabel": "Optional(PhotoCatalog.ColorLabel.green)",
            "keywords": "[\"a\", \"b\"]", "title": "Title", "caption": "Caption", "author": "Me", "copyright": "© Me",
            "makerNotes": "notes", "project": "Proj", "client": "Client", "location": "Tokyo", "gps": "(35.6, 139.7)",
            "gpsAltitude": "Optional(40.0)", "status": "offline", "importedAt": "700003600.25", "deleted": "true",
            "localPath": "Optional(\"/photos/IMG_1.CR3\")", "captureDateSource": "XMP", "contentHash": "Optional(\"sha\")",
            "quickHash": "Optional(\"quick\")", "isDemo": "false", "faces": "3", "perceptualHash": "Optional(3735928559)",
            "masterId": "Optional(\"m0\")", "copyName": "Optional(\"副本 9\")", "duration": "Optional(12.5)",
        ])
        XCTAssertEqual(fields(sample).count, 52)
        XCTAssertTrue(sample.isVirtualCopy)
    }

    /// Each write changes that field alone, on a copy of its own; the photo it was copied from
    /// keeps its storage and every value.
    func testEachWriteChangesItsFieldAloneAndCopiesOnce() {
        let original = sample
        let before = fields(original)
        XCTAssertEqual(Set(Self.writes.map(\.name)).count, 34)
        for (name, write) in Self.writes {
            var copy = original
            XCTAssertEqual(storage(copy), storage(original), "a copy shares until written")
            write(&copy)
            XCTAssertNotEqual(storage(copy), storage(original), "\(name): written on a storage of its own")
            let after = fields(copy)
            XCTAssertEqual(Set(after.keys.filter { after[$0] != before[$0] }), [name], name)
            XCTAssertEqual(fields(original), before, "\(name): the original is untouched")
            // the copy is unique now: further writes stay on its storage
            let own = storage(copy)
            write(&copy)
            copy.rating = 2
            XCTAssertEqual(storage(copy), own, "\(name): no second copy")
        }
    }

    func testAUniqueAssetIsWrittenInPlace() {
        var photo = sample
        let own = storage(photo)
        for (_, write) in Self.writes { write(&photo) }
        XCTAssertEqual(storage(photo), own)
        var shared = photo
        shared.title = "Changed"
        XCTAssertNotEqual(storage(shared), own)
        XCTAssertEqual(storage(photo), own)
        XCTAssertEqual(photo.title, "T2")
    }

    func testVirtualCopyCarriesEverythingButWhatMakesItACopy() {
        var master = sample
        master.masterId = nil
        master.copyName = nil
        let before = Date.now
        let copy = master.virtualCopy(id: "v1", name: "副本 1")
        let after = Date.now
        XCTAssertNotEqual(storage(copy), storage(master))
        var expected = fields(master)
        expected["id"] = "v1"
        expected["deleted"] = "false"
        expected["isDemo"] = "false"
        expected["faces"] = "0"
        expected["masterId"] = "Optional(\"a1\")"
        expected["copyName"] = "Optional(\"副本 1\")"
        expected["importedAt"] = nil
        var got = fields(copy)
        got["importedAt"] = nil
        XCTAssertEqual(got, expected)
        XCTAssertTrue((before...after).contains(copy.importedAt))
        XCTAssertEqual(fields(master)["importedAt"], "700003600.25")
        // a copy of a copy names the first photo as its master
        XCTAssertEqual(copy.virtualCopy(id: "v2", name: "副本 2").masterId, "a1")
        XCTAssertEqual(sample.virtualCopy(id: "v3", name: "x").masterId, "m0")
    }

    /// Undo replays one step: every editable field the step changed is taken, the rest of the
    /// photo as it is now stays.
    func testTakeChangesTakesWhatTheStepChanged() {
        let old = sample
        var new = old
        for (_, write) in Self.writes { write(&new) }
        var target = old.virtualCopy(id: "t1", name: "Target")
        target.title = "Edited since"
        let targetBefore = fields(target)
        target.takeChanges(from: old, to: new)
        let newFields = fields(new)
        let editable = Set(Self.writes.map(\.name))
        for (name, value) in fields(target) {
            XCTAssertEqual(value, editable.contains(name) ? newFields[name] : targetBefore[name], name)
        }

        // a field the step left alone keeps the value the photo has now
        var renamed = old
        renamed.rating = 5
        var photo = old
        photo.title = "Mine"
        photo.takeChanges(from: old, to: renamed)
        XCTAssertEqual(photo.rating, 5)
        XCTAssertEqual(photo.title, "Mine")

        // a step whose two sides are one storage changes nothing and copies nothing
        var shared = old
        let own = storage(shared)
        shared.takeChanges(from: new, to: new)
        XCTAssertEqual(storage(shared), own)
        XCTAssertEqual(fields(shared), fields(old))
    }
}
