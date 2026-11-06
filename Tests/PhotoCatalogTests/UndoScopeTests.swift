import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoCatalog

/// Undo takes back what its own step changed, and nothing a later, non-undoable operation
/// (rename, trash, offline status, rescan, sidecar read) did to the same photo since.
final class UndoScopeTests: XCTestCase {
    private static let defaultsKeys = ["pc_openLast", "pc_catalogURL", "pc_onboarded", "pc_recentCatalogs",
                                       "pc_renameTemplate", "pc_pinnedSidebarItems"]
    private var scratch: URL!
    private var undo: UndoManager!

    override func setUp() {
        super.setUp()
        preservingPreferences(Self.defaultsKeys)
        UserDefaults.app.set(false, forKey: "pc_openLast")
        UserDefaults.app.removeObject(forKey: "pc_pinnedSidebarItems")
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("pc-undo-scope-\(UUID().uuidString)")
    }

    override func tearDown() {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        undo = nil
        super.tearDown()
    }

    @MainActor
    func testUndoingARatingKeepsALaterRename() throws {
        let (app, package, id) = try openCatalogWithPhoto()
        step { XCTAssertTrue(app.setRating(3, on: [id])) }
        let original = try XCTUnwrap(asset(id, in: app))
        app.renameOriginals(template: "Renamed", targets: [original])
        let renamed = scratch.appendingPathComponent("Source/Renamed_0001.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
        XCTAssertEqual(undo.undoActionName, "评分", "a rename registers no undo step of its own")

        undo.undo()

        let memory = try XCTUnwrap(asset(id, in: app))
        XCTAssertEqual(memory.rating, 0, "undo takes the rating back")
        XCTAssertEqual(memory.filename, "Renamed_0001.jpg", "the rename survives undoing the rating")
        XCTAssertEqual(memory.localPath, renamed.path)
        let saved = try XCTUnwrap(try CatalogStore(packageURL: package).loadAssets().first { $0.id == id })
        XCTAssertEqual(saved.rating, 0)
        XCTAssertEqual(saved.filename, "Renamed_0001.jpg", "the catalog keeps the renamed file")
        XCTAssertEqual(saved.localPath, renamed.path)
    }

    @MainActor
    func testRedoingARatingKeepsALaterRename() throws {
        let (app, package, id) = try openCatalogWithPhoto()
        step { XCTAssertTrue(app.setRating(3, on: [id])) }
        let original = try XCTUnwrap(asset(id, in: app))
        app.renameOriginals(template: "Renamed", targets: [original])
        let renamed = scratch.appendingPathComponent("Source/Renamed_0001.jpg")
        undo.undo()

        undo.redo()

        let memory = try XCTUnwrap(asset(id, in: app))
        XCTAssertEqual(memory.rating, 3, "redo puts the rating back")
        XCTAssertEqual(memory.filename, "Renamed_0001.jpg")
        XCTAssertEqual(memory.localPath, renamed.path)
        let saved = try XCTUnwrap(try CatalogStore(packageURL: package).loadAssets().first { $0.id == id })
        XCTAssertEqual(saved.rating, 3)
        XCTAssertEqual(saved.filename, "Renamed_0001.jpg")
        XCTAssertEqual(saved.localPath, renamed.path)
    }

    @MainActor
    func testRedoingARatingAfterARenameKeepsTheNewName() throws {
        let (app, package, id) = try openCatalogWithPhoto()
        step { XCTAssertTrue(app.setRating(3, on: [id])) }
        undo.undo()
        let original = try XCTUnwrap(asset(id, in: app))
        app.renameOriginals(template: "Renamed", targets: [original])
        let renamed = scratch.appendingPathComponent("Source/Renamed_0001.jpg")
        XCTAssertTrue(undo.canRedo, "a rename registers no step, so the rating can still be redone")

        undo.redo()

        let memory = try XCTUnwrap(asset(id, in: app))
        XCTAssertEqual(memory.rating, 3)
        XCTAssertEqual(memory.filename, "Renamed_0001.jpg", "redoing the rating keeps the rename made since")
        XCTAssertEqual(memory.localPath, renamed.path)
        let saved = try XCTUnwrap(try CatalogStore(packageURL: package).loadAssets().first { $0.id == id })
        XCTAssertEqual(saved.rating, 3)
        XCTAssertEqual(saved.filename, "Renamed_0001.jpg")
        XCTAssertEqual(saved.localPath, renamed.path)
    }

    @MainActor
    func testUndoingARatingDoesNotBringBackATrashedPhoto() throws {
        let (app, package, id) = try openCatalogWithPhoto()
        step { XCTAssertTrue(app.setRating(3, on: [id])) }
        // what Move Originals to Trash records once the file is in the Trash
        XCTAssertTrue(app.applyTrashedOriginals(OriginalTrashReport(trashedIds: [id])))
        XCTAssertEqual(asset(id, in: app)?.deleted, true)
        XCTAssertEqual(undo.undoActionName, "评分")

        undo.undo()

        let memory = try XCTUnwrap(asset(id, in: app))
        XCTAssertTrue(memory.deleted, "undoing the rating leaves the trashed photo out of the catalog")
        XCTAssertEqual(memory.rating, 0)
        XCTAssertFalse(app.list.contains { $0.id == id })
        // loading skips soft-deleted rows, so read this one as it is
        let db = try Database(path: package.appendingPathComponent("catalog.sqlite").path)
        XCTAssertEqual(db.scalarInt("SELECT deleted FROM assets WHERE id=?;", [.text(id)]), 1,
                       "the catalog row stays removed")
        XCTAssertEqual(db.scalarInt("SELECT rating FROM assets WHERE id=?;", [.text(id)]), 0)
    }

    // MARK: - photos removed for good since

    @MainActor
    func testUndoingARemovalLeavesOutAPhotoOfASourceRemovedSince() throws {
        let (app, package, id) = try openCatalogWithPhoto(asSource: true)
        step { app.removeSelected() }
        app.confirmDestructiveAction = { _, _, _ in true }
        app.select(Selection(type: .folder, id: Self.sourceId, name: "Source"))
        app.removeSelectedSource()
        XCTAssertFalse(app.folders.contains { $0.id == Self.sourceId }, "the source is gone")
        XCTAssertEqual(undo.undoActionName, "从目录库移除", "removing a source registers no step")

        undo.undo()

        XCTAssertEqual(asset(id, in: app)?.deleted, true, "the photo stays out with its source")
        XCTAssertFalse(app.list.contains { $0.id == id })
        XCTAssertEqual(try deletedFlag(id, in: package), 1, "in the catalog too")
    }

    @MainActor
    func testUndoingARemovalLeavesOutAPhotoWhoseOriginalWasTrashedSince() throws {
        let (app, package, id) = try openCatalogWithPhoto()
        step { app.removeSelected() }
        undo.undo()
        XCTAssertEqual(asset(id, in: app)?.deleted, false)
        XCTAssertTrue(app.applyTrashedOriginals(OriginalTrashReport(trashedIds: [id])))
        undo.redo()

        undo.undo()

        XCTAssertEqual(asset(id, in: app)?.deleted, true, "a photo whose original is in the Trash stays out")
        XCTAssertFalse(app.list.contains { $0.id == id })
        XCTAssertEqual(try deletedFlag(id, in: package), 1)
    }

    @MainActor
    func testRedoingAVirtualCopyLeavesItOutOnceItsMastersOriginalIsTrashed() throws {
        let (app, package, id) = try openCatalogWithPhoto()
        step { app.createVirtualCopies() }
        let copyId = try XCTUnwrap(app.assets.first { $0.masterId == id }?.id)
        undo.undo()
        XCTAssertEqual(asset(copyId, in: app)?.deleted, true, "undo takes the copy away")
        XCTAssertTrue(app.applyTrashedOriginals(OriginalTrashReport(trashedIds: [id])))

        undo.redo()

        XCTAssertEqual(asset(copyId, in: app)?.deleted, true, "a copy of a trashed original stays out")
        XCTAssertFalse(app.list.contains { $0.id == copyId })
        XCTAssertEqual(try deletedFlag(copyId, in: package), 1)
    }

    // MARK: - fixture

    private static let sourceId = "src-undo-scope"

    /// The catalog row's own `deleted` (loading skips soft-deleted rows).
    private func deletedFlag(_ id: String, in package: URL) throws -> Int? {
        try Database(path: package.appendingPathComponent("catalog.sqlite").path)
            .scalarInt("SELECT deleted FROM assets WHERE id=?;", [.text(id)])
    }

    /// One step, closed the way AppKit closes an event's group.
    @MainActor
    private func step(_ action: () -> Void) {
        undo.beginUndoGrouping()
        action()
        undo.endUndoGrouping()
    }

    @MainActor
    private func asset(_ id: String, in app: AppState) -> Asset? {
        app.assets.first { $0.id == id }
    }

    /// A scratch catalog holding one real JPEG, `a.jpg`, opened in a fresh AppState with an undo
    /// manager; `asSource` adds its folder as a source.
    @MainActor
    private func openCatalogWithPhoto(asSource: Bool = false) throws -> (AppState, URL, String) {
        let source = scratch.appendingPathComponent("Source")
        let photo = source.appendingPathComponent("a.jpg")
        try writeJPEG(to: photo)
        let package = scratch.appendingPathComponent("Library.photolibrary")
        let id = "undo-scope-a"
        let photoAsset = Asset(id: id, pid: 1, ori: "l", thumb: "", preview: "", filename: photo.lastPathComponent,
                               type: "JPG", isRaw: false, folderId: Self.sourceId, folderName: "Source",
                               date: Date(timeIntervalSince1970: 1_700_000_000), width: 80, height: 60,
                               orientation: 1, camera: "", lens: "", focal: 0, aperture: 0, shutter: "", iso: 0,
                               colorSpace: "sRGB", fileMB: 0.01, rating: 0, flag: .none, keywords: [], title: "",
                               caption: "", location: "", gps: (0, 0), status: .ready, importedAt: .now,
                               localPath: photo.path, isDemo: false)
        let store = try CatalogStore(packageURL: package)
        if asSource { try store.addSourceRoot(id: Self.sourceId, displayName: "Source", path: source.path, bookmark: nil) }
        try store.upsert([photoAsset])

        undo = UndoManager()
        undo.groupsByEvent = false   // no run loop here to close event groups
        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))
        app.autoWriteXMPSidecar = false   // nothing beside the scratch photo but the photo
        app.undoManager = undo
        app.primaryId = id
        app.selectedIds = [id]
        XCTAssertNotNil(asset(id, in: app))
        return (app, package, id)
    }

    private func writeJPEG(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let context = CGContext(data: nil, width: 80, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw NSError(domain: "UndoScopeTests", code: 1)
        }
        context.setFillColor(CGColor(red: 0.7, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString,
                                                                1, nil) else {
            throw NSError(domain: "UndoScopeTests", code: 2)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "UndoScopeTests", code: 3) }
    }
}
