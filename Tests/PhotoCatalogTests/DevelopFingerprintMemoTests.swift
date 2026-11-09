import XCTest
@testable import PhotoCatalog

/// A photo's settings fingerprint is remembered between edits, and always equals the one made
/// from its settings as they are: over many random edits of sliders, curves, masks (brush strokes
/// included), spots and geometry, with undo and redo, a direct write and a clear between them.
final class DevelopFingerprintMemoTests: XCTestCase {
    override func setUp() {
        super.setUp()
        openingNoCatalogAtLaunch()
    }

    /// A generator that gives the same edits on every run.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private func point(_ rng: inout SeededGenerator) -> CGPoint {
        CGPoint(x: Double(Int.random(in: 0...1_000, using: &rng)) / 1_000, y: Double(Int.random(in: 0...1_000, using: &rng)) / 1_000)
    }

    private func stroke(_ rng: inout SeededGenerator) -> BrushStroke {
        var stroke = BrushStroke()
        for _ in 0..<Int.random(in: 1...200, using: &rng) { stroke.append(point(&rng)) }
        stroke.radius = Double(Int.random(in: 1...100, using: &rng)) / 1_000
        return stroke
    }

    /// One random change that the render shows, named for the failure message.
    private func edit(_ settings: inout DevelopSettings, _ rng: inout SeededGenerator) -> String {
        func slider(_ range: ClosedRange<Int> = -100...100) -> Double { Double(Int.random(in: range, using: &rng)) }
        switch Int.random(in: 0..<19, using: &rng) {
        case 0: settings.exposure = slider(-500...500) / 100; return "exposure"
        case 1: settings.contrast = slider(); return "contrast"
        case 2: settings.highlights = slider(); settings.shadows = slider(); return "highlights and shadows"
        case 3: settings.temperature = slider(2_000...12_000); return "temperature"
        case 4: settings.clarity = slider(); return "clarity"
        case 5:
            settings.curve.rgb = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: Double(Int.random(in: 1...999, using: &rng)) / 1_000),
                                  CurvePoint(x: 1, y: 1)]
            return "curve"
        case 6:
            var mask = LocalAdjustment(kind: .radial)
            mask.center = point(&rng)
            mask.exposure = slider(-400...400) / 100
            settings.masks.append(mask)
            return "a radial mask added"
        case 7:
            var mask = LocalAdjustment(kind: .brush)
            mask.strokes = [stroke(&rng)]
            mask.contrast = slider()
            settings.masks.append(mask)
            return "a brush mask added"
        case 8:
            guard !settings.masks.isEmpty else { return "nothing" }
            let i = Int.random(in: settings.masks.indices, using: &rng)
            settings.masks[i].saturation = slider()
            return "a mask's saturation"
        case 9:
            guard let i = settings.masks.firstIndex(where: { $0.kind == .brush }) else { return "nothing" }
            settings.masks[i].strokes[0].append(point(&rng))
            return "a dab added to a brush stroke"
        case 10:
            guard !settings.masks.isEmpty else { return "nothing" }
            settings.masks.remove(at: Int.random(in: settings.masks.indices, using: &rng))
            return "a mask removed"
        case 11:
            guard !settings.masks.isEmpty else { return "nothing" }
            let i = Int.random(in: settings.masks.indices, using: &rng)
            settings.masks[i].inverted.toggle()
            return "a mask inverted"
        case 12:
            var spot = SpotRemoval(target: point(&rng), source: point(&rng), radius: Double(Int.random(in: 1...50, using: &rng)) / 1_000)
            if Bool.random(using: &rng) {
                spot.mode = .remove
                spot.strokes = [stroke(&rng)]
            }
            settings.spots.append(spot)
            return "a spot added"
        case 13:
            guard !settings.spots.isEmpty else { return "nothing" }
            settings.spots[Int.random(in: settings.spots.indices, using: &rng)].target = point(&rng)
            return "a spot moved"
        case 14:
            guard !settings.spots.isEmpty else { return "nothing" }
            settings.spots.remove(at: Int.random(in: settings.spots.indices, using: &rng))
            return "a spot removed"
        case 15:
            let corner = point(&rng)
            settings.crop = DevelopCrop(x: corner.x / 2, y: corner.y / 2, width: 0.4, height: 0.4)
            return "crop"
        case 16: settings.rotation = (settings.rotation + 90) % 360; return "rotation"
        case 17: settings.grain = slider(0...100); return "grain"
        default:
            settings.mixer.saturation[Int.random(in: 0..<8, using: &rng)] = slider()
            return "color mixer"
        }
    }

    @MainActor
    func testTheRememberedFingerprintIsAlwaysTheSettingsOwn() {
        let app = AppState.selfCheckFixture()
        let undo = UndoManager()
        undo.groupsByEvent = false   // no run loop here to close event groups
        app.undoManager = undo
        let id = "photo"
        var rng = SeededGenerator(state: 0x5EED)
        var changes = 0
        func expectOwn(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
            let uncached = app.developSettings[id]?.fingerprint
            XCTAssertEqual(app.developFingerprint(for: id), uncached, label, file: file, line: line)
            XCTAssertEqual(app.developFingerprint(for: id), uncached, "\(label), asked again", file: file, line: line)
        }
        expectOwn("as shot")
        for step in 0..<1_500 {
            let before = app.developFingerprint(for: id)
            switch Int.random(in: 0..<20, using: &rng) {
            case 0:
                undo.undo()
                expectOwn("step \(step): undo")
            case 1:
                undo.redo()
                expectOwn("step \(step): redo")
            case 2:
                // written without an edit, as a catalog load or a sidecar read does
                var settings = app.developSettings[id] ?? .neutral
                let name = edit(&settings, &rng)
                app.developSettings[id] = settings
                expectOwn("step \(step): \(name), written directly")
            case 3:
                undo.beginUndoGrouping()
                app.commitDevelop([id: .neutral], undoName: "复位")
                undo.endUndoGrouping()
                expectOwn("step \(step): cleared")
                XCTAssertNil(app.developFingerprint(for: id))
            default:
                var settings = app.developSettings[id] ?? .neutral
                let name = edit(&settings, &rng)
                undo.beginUndoGrouping()
                app.commitDevelop([id: settings], undoName: "调整")
                undo.endUndoGrouping()
                expectOwn("step \(step): \(name)")
                let after = app.developSettings[id]?.fingerprint
                if after != before { changes += 1 }
                XCTAssertEqual(app.developSettings[id] ?? .neutral, settings, "step \(step): \(name) saved")
            }
        }
        XCTAssertGreaterThan(changes, 600, "the edits changed the fingerprint")
    }

    /// Settings that are equal give the remembered fingerprint, and any rendered change gives a
    /// new one: a dab more in a brush mask, a spot moved a thousandth.
    @MainActor
    func testASmallMaskOrSpotChangeIsANewFingerprint() {
        let app = AppState.selfCheckFixture()
        var settings = DevelopSettings()
        var mask = LocalAdjustment(kind: .brush)
        var stroke = BrushStroke()
        for i in 0..<6_000 { stroke.append(CGPoint(x: Double(i % 100) / 100, y: Double(i / 100) / 60)) }
        mask.strokes = [stroke]
        mask.exposure = 1
        settings.masks = [mask]
        settings.spots = [SpotRemoval(target: CGPoint(x: 0.3, y: 0.3), source: CGPoint(x: 0.4, y: 0.4), radius: 0.02)]
        app.developSettings["p"] = settings
        let first = app.developFingerprint(for: "p")

        var dab = settings
        dab.masks[0].strokes[0].append(CGPoint(x: 0.5, y: 0.5))
        app.developSettings["p"] = dab
        XCTAssertNotEqual(app.developFingerprint(for: "p"), first)
        XCTAssertEqual(app.developFingerprint(for: "p"), dab.fingerprint)

        var moved = settings
        moved.spots[0].target.x += 0.001
        app.developSettings["p"] = moved
        XCTAssertEqual(app.developFingerprint(for: "p"), moved.fingerprint)
        XCTAssertNotEqual(app.developFingerprint(for: "p"), first)

        app.developSettings["p"] = settings
        XCTAssertEqual(app.developFingerprint(for: "p"), first, "back to the first settings, the first fingerprint")
        app.developSettings["p"] = nil
        XCTAssertNil(app.developFingerprint(for: "p"))
        XCTAssertNil(app.developFingerprintCache["p"], "a cleared photo's is let go")
    }

    /// The full-size loader's key and the developed cache file's name are what they were.
    @MainActor
    func testRequestKeyAndEditedCacheNameAreUnchanged() throws {
        var settings = DevelopSettings()
        settings.exposure = 0.7
        var mask = LocalAdjustment(kind: .radial)
        mask.exposure = -1
        settings.masks = [mask]
        let edited = FullResolutionLoader.Request(path: "/photos/a.CR3", isRaw: true, settings: settings,
                                                  fingerprint: settings.fingerprint, version: "v2")
        XCTAssertEqual(edited.key, "/photos/a.CR3|v2|\(settings.fingerprint)")
        let computed = FullResolutionLoader.Request(path: "/photos/a.CR3", isRaw: true, settings: settings, version: "v2")
        XCTAssertEqual(computed.key, edited.key)
        XCTAssertEqual(computed, edited)
        let plain = FullResolutionLoader.Request(path: "/photos/a.JPG", isRaw: false, settings: nil, version: "v1")
        XCTAssertEqual(plain.key, "/photos/a.JPG|v1")

        let store = try CatalogStore(packageURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-fingerprint-\(UUID().uuidString)/Fingerprint.photolibrary"))
        defer { try? FileManager.default.removeItem(at: store.packageURL.deletingLastPathComponent()) }
        let service = ThumbnailService(store: store)
        for id in ["a1", "with/slash", "üñí"] {
            for kind in [ThumbnailService.Kind.thumb512, .preview2048] {
                XCTAssertEqual(service.editedCachePath(assetId: id, kind: kind, fingerprint: settings.fingerprint),
                               service.editedCachePath(assetId: id, kind: kind, settings: settings), id)
            }
        }
    }
}
