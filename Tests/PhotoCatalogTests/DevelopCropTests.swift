import XCTest
@testable import PhotoCatalog

/// The crop tool's shape, orientation and straighten edits, moved from the panel into AppState,
/// give the crops the panel's own helpers gave. Those helpers are copied here as the oracle.
@MainActor
final class DevelopCropTests: XCTestCase {
    private let asset = Asset(id: "photo", pid: 1, ori: "l", thumb: "", preview: "", filename: "photo.jpg", type: "JPG",
                              isRaw: false, folderId: "src", folderName: "Source", date: .now, width: 600, height: 400,
                              orientation: 1, camera: "", lens: "", focal: 0, aperture: 0, shutter: "", iso: 0,
                              colorSpace: "sRGB", fileMB: 0.01, rating: 0, flag: .none, keywords: [], title: "",
                              caption: "", location: "", gps: (0, 0), status: .ready, importedAt: .now,
                              localPath: nil, isDemo: false)

    override func setUp() {
        super.setUp()
        openingNoCatalogAtLaunch()
    }

    /// A photo decoded at 4000 × 3000 (not the asset's 600 × 400), with `saved` as its settings.
    private func makeApp(_ saved: DevelopSettings) -> AppState {
        let app = AppState.selfCheckFixture()
        app.recordDevelopSourceSize(CGSize(width: 4000, height: 3000), for: asset.id)
        app.commitDevelop([asset.id: saved], undoName: "设置")
        return app
    }

    private func tilted(crop: DevelopCrop? = DevelopCrop(x: 0.2, y: 0.15, width: 0.5, height: 0.6),
                        rotation: Int = 0) -> DevelopSettings {
        var settings = DevelopSettings()
        settings.straighten = 4
        settings.perspectiveVertical = 12
        settings.rotation = rotation
        settings.crop = crop
        return settings
    }

    // ---- the panel's helpers before they moved, returning what they committed or drafted ----
    private func oldApplyAspect(_ app: AppState, _ aspect: CropAspect) -> DevelopSettings? {
        let settings = app.developSettings(for: asset.id)
        let frame = app.developFrame(for: asset, settings: settings)
        guard let ratio = aspect.ratio(frame: frame) else { return nil }
        let current = DevelopGeometry.effectiveCrop(settings, frame: frame)
        let landscape = current.width * frame.width >= current.height * frame.height
        return oldReshapeCrop(app, aspect: landscape ? ratio : 1 / ratio, around: current, frame: frame)
    }

    private func oldSwapCropOrientation(_ app: AppState) -> DevelopSettings {
        let settings = app.developSettings(for: asset.id)
        let frame = app.developFrame(for: asset, settings: settings)
        let current = DevelopGeometry.effectiveCrop(settings, frame: frame)
        let aspect = current.height * frame.height / max(current.width * frame.width, 1e-9)
        return oldReshapeCrop(app, aspect: aspect, around: current, frame: frame)
    }

    private func oldReshapeCrop(_ app: AppState, aspect: Double, around current: DevelopCrop,
                                frame: CGSize) -> DevelopSettings {
        var next = app.developSettings[asset.id] ?? .neutral
        let perspective = DevelopGeometry.perspective(next, frame: frame)
        let largest = DevelopGeometry.inscribed(aspect: aspect, angle: next.straighten, perspective: perspective,
                                                frame: frame)
        let crop = DevelopGeometry.move(largest, dx: current.midX - largest.midX, dy: current.midY - largest.midY,
                                        angle: next.straighten, perspective: perspective, frame: frame)
        let isWhole = crop == DevelopGeometry.inscribed(aspect: frame.width / max(frame.height, 1),
                                                        angle: next.straighten, perspective: perspective, frame: frame)
        next.crop = isWhole ? nil : crop
        return next
    }

    private func oldStraightenDraft(_ app: AppState, _ angle: Double) -> DevelopSettings {
        var next = app.developSettings[asset.id] ?? .neutral
        let frame = app.developFrame(for: asset, settings: next)
        next.straighten = angle
        next.crop = DevelopGeometry.refit(next, frame: frame)
        return next
    }

    private func draft(_ app: AppState) -> DevelopSettings {
        var dragging = app.developSettings(for: asset.id)
        dragging.crop = DevelopCrop(x: 0.05, y: 0.3, width: 0.35, height: 0.5)
        dragging.straighten = -6
        return dragging
    }

    // ---- shape ----
    func testCropShapesGiveTheOldCrops() {
        for saved in [tilted(), tilted(crop: nil), tilted(rotation: 1), DevelopSettings()] {
            for aspect in [CropAspect.square, .r16x9, .r4x5, .original] {
                for withDraft in [false, true] {
                    let app = makeApp(saved)
                    if withDraft { app.updateDevelopDraft(draft(app), for: asset.id) }
                    let expected = oldApplyAspect(app, aspect)

                    app.setCropAspect(aspect, for: asset)

                    XCTAssertEqual(app.developCropAspect, aspect)
                    XCTAssertEqual(app.developSettings(for: asset.id), expected, "\(aspect), draft: \(withDraft)")
                }
            }
        }
    }

    func testThePhotosOwnShapeIsNoCrop() {
        let app = makeApp(DevelopSettings())
        app.setCropAspect(.r16x9, for: asset)
        XCTAssertNotNil(app.developSettings[asset.id]?.crop)

        app.setCropAspect(.original, for: asset)

        XCTAssertNil(app.developSettings[asset.id], "4 : 3 in a 4 : 3 photo is the whole photo: no crop, no edit")
        XCTAssertEqual(app.developCropAspect, .original)
    }

    func testAFreeShapeOnlyChangesTheChoice() {
        let app = makeApp(tilted())
        app.updateDevelopDraft(draft(app), for: asset.id)
        app.setCropAspect(.free, for: asset)
        XCTAssertEqual(app.developCropAspect, .free)
        XCTAssertEqual(app.developSettings[asset.id], tilted())
        XCTAssertNotNil(app.developDraft, "nothing committed, so the drag carries on")
    }

    // ---- orientation ----
    func testSwappingGivesTheOldCrop() {
        for saved in [tilted(), tilted(crop: nil), tilted(rotation: 3)] {
            for withDraft in [false, true] {
                let app = makeApp(saved)
                if withDraft { app.updateDevelopDraft(draft(app), for: asset.id) }
                let expected = oldSwapCropOrientation(app)

                app.swapCropOrientation(for: asset)

                XCTAssertEqual(app.developSettings(for: asset.id), expected, "draft: \(withDraft)")
            }
        }
    }

    func testSwappingTwiceReturnsTheOriginal() throws {
        let app = makeApp(DevelopSettings())
        app.setCropAspect(.r16x9, for: asset)
        let original = try XCTUnwrap(app.developSettings[asset.id]?.crop)

        app.swapCropOrientation(for: asset)
        let portrait = try XCTUnwrap(app.developSettings[asset.id]?.crop)
        XCTAssertLessThan(portrait.width * 4000, portrait.height * 3000, "the crop turned upright")
        app.swapCropOrientation(for: asset)

        let back = try XCTUnwrap(app.developSettings[asset.id]?.crop)
        XCTAssertEqual(back.x, original.x, accuracy: 1e-9)
        XCTAssertEqual(back.y, original.y, accuracy: 1e-9)
        XCTAssertEqual(back.width, original.width, accuracy: 1e-9)
        XCTAssertEqual(back.height, original.height, accuracy: 1e-9)
    }

    // ---- straighten ----
    func testTheStraightenDraftGivesTheOldDraft() {
        for saved in [tilted(), tilted(rotation: 1), tilted(crop: nil)] {
            for withDraft in [false, true] {
                let app = makeApp(saved)
                if withDraft { app.updateDevelopDraft(draft(app), for: asset.id) }
                let expected = oldStraightenDraft(app, 9.5)

                app.draftStraighten(9.5, for: asset)

                XCTAssertEqual(app.developDraft?.settings, expected, "draft: \(withDraft)")
                XCTAssertEqual(app.developSettings[asset.id], saved, "only a draft until the slider is let go")
            }
        }
    }

    func testRefitUsesTheDecodedFrameAfterQuarterTurns() {
        let app = makeApp(DevelopSettings())
        var settings = tilted(crop: DevelopCrop(x: 0, y: 0, width: 1, height: 1), rotation: 1)
        let expected = DevelopGeometry.refit(settings, frame: CGSize(width: 3000, height: 4000))
        app.refitCrop(&settings, for: asset)
        XCTAssertEqual(settings.crop, expected)
        XCTAssertNotEqual(settings.crop, DevelopCrop(x: 0, y: 0, width: 1, height: 1), "shrunk inside the tilt")
    }

    func testOrientedFollowsTheCropsShape() {
        let frame = CGSize(width: 4000, height: 3000)
        XCTAssertEqual(DevelopGeometry.oriented(ratio: 1.5, like: DevelopCrop(x: 0, y: 0, width: 0.5, height: 0.5),
                                                frame: frame), 1.5, "wider in pixels than tall")
        XCTAssertEqual(DevelopGeometry.oriented(ratio: 1.5, like: DevelopCrop(x: 0, y: 0, width: 0.3, height: 0.5),
                                                frame: frame), 1 / 1.5)
        XCTAssertEqual(DevelopGeometry.oriented(ratio: 1.5, like: DevelopCrop(x: 0, y: 0, width: 0.75, height: 1),
                                                frame: frame), 1.5, "a square crop counts as landscape")
    }
}
