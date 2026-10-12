import AppKit
import XCTest
@testable import PhotoCatalog

/// External drives: which drive a source folder is on, and what happens as drives come, go,
/// are swapped for another of the same name or renamed. Folders under the test's own "Volumes"
/// folder stand in for drives, each naming its identifier in a `.volume-id` file.
final class VolumeTests: CatalogTestCase {
    private var volumes: URL { scratch.appendingPathComponent("Volumes") }
    private var unplugged: URL { scratch.appendingPathComponent("Unplugged") }

    private var probe: VolumeProbe {
        let directory = volumes.path
        return VolumeProbe(mountDirectory: directory) { url in
            let mountPoint = VolumeProbe(mountDirectory: directory) { _ in nil }.volumeRoot(of: url.path)
            guard let mountPoint else { return "startup-disk" }
            return try? String(contentsOfFile: mountPoint + "/.volume-id", encoding: .utf8)
        }
    }

    /// Plugs in a drive called `name` whose identifier is `id`.
    @discardableResult
    private func mountDrive(_ name: String, id: String) throws -> URL {
        let root = volumes.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try id.write(to: root.appendingPathComponent(".volume-id"), atomically: true, encoding: .utf8)
        return root
    }

    /// Unplugs the drive mounted as `name`; `plugIn` puts it back, under another name if given.
    private func unplug(_ name: String) throws {
        try FileManager.default.createDirectory(at: unplugged, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: volumes.appendingPathComponent(name),
                                         to: unplugged.appendingPathComponent(name))
    }

    private func plugIn(_ name: String, as mountName: String? = nil) throws {
        try FileManager.default.moveItem(at: unplugged.appendingPathComponent(name),
                                         to: volumes.appendingPathComponent(mountName ?? name))
    }

    /// A catalog with one referenced source folder, `Shoot`, on the drive `Photos` (identifier
    /// "drive-a"), holding IMG_0001.JPG.
    private func catalogOnDrive() throws -> (store: CatalogStore, root: SourceRootRecord, asset: Asset) {
        let drive = try mountDrive("Photos", id: "drive-a")
        let folder = drive.appendingPathComponent("Shoot")
        let photo = folder.appendingPathComponent("IMG_0001.JPG")
        try makeTestJPEG(at: photo, shade: 1)
        let store = try CatalogStore(packageURL: scratch.appendingPathComponent("Library.photolibrary"))
        try store.addSourceRoot(id: "source-1", displayName: "Shoot", path: folder.path, bookmark: nil,
                                volumeIdentifier: "drive-a")
        let asset = try XCTUnwrap(ImportCoordinator(store: store)
            .importFiles([photo], from: folder, sourceRootId: "source-1", folderName: "Shoot").first)
        try store.upsert([asset])
        let root = try XCTUnwrap(try store.loadSourceRoots().first)
        return (store, root, asset)
    }

    // ---------- another drive with the same name (#31) ----------

    /// The photo's drive is unplugged and another drive of the same name, with a file at the same
    /// path, is plugged in: the photo is offline, not "there".
    func testAnotherDriveOfTheSameNameLeavesThePhotoOffline() throws {
        let (_, root, asset) = try catalogOnDrive()
        try unplug("Photos")
        try makeTestJPEG(at: try mountDrive("Photos", id: "drive-b").appendingPathComponent("Shoot/IMG_0001.JPG"), shade: 7)

        let changes = AssetAvailabilityService.changes(in: [asset], sourceRootsById: [root.id: root], probe: probe)

        XCTAssertEqual(changes, [AssetAvailabilityUpdate(assetId: asset.id, status: .offline, localPath: asset.localPath)])
    }

    /// The photo's drive is back as "Photos 1" because another drive took "Photos": the photo is
    /// found on its own drive.
    func testThePhotosOwnDriveIsFoundUnderAnotherName() throws {
        let (_, root, asset) = try catalogOnDrive()
        try unplug("Photos")
        try makeTestJPEG(at: try mountDrive("Photos", id: "drive-b").appendingPathComponent("Shoot/IMG_0001.JPG"), shade: 7)
        try plugIn("Photos", as: "Photos 1")

        let changes = AssetAvailabilityService.changes(in: [asset], sourceRootsById: [root.id: root], probe: probe)

        let moved = volumes.appendingPathComponent("Photos 1/Shoot/IMG_0001.JPG").path
        XCTAssertEqual(changes, [AssetAvailabilityUpdate(assetId: asset.id, status: .ready, localPath: moved)])
    }

    /// The photo's own drive, where it was: nothing changes; a root with no drive recorded goes
    /// by the path alone, as before.
    func testThePhotosOwnDriveOrNoRecordedDriveChangesNothing() throws {
        let (_, root, asset) = try catalogOnDrive()
        XCTAssertEqual(AssetAvailabilityService.changes(in: [asset], sourceRootsById: [root.id: root], probe: probe), [])

        let unrecorded = SourceRootRecord(id: root.id, displayName: root.displayName, pathHint: root.pathHint,
                                          bookmarkData: nil, managementMode: root.managementMode, status: root.status,
                                          volumeIdentifier: nil)
        try unplug("Photos")
        try makeTestJPEG(at: try mountDrive("Photos", id: "drive-b").appendingPathComponent("Shoot/IMG_0001.JPG"), shade: 7)
        XCTAssertEqual(AssetAvailabilityService.changes(in: [asset], sourceRootsById: [root.id: unrecorded], probe: probe), [])
    }

    /// Opening the catalog while another drive of the same name is plugged in: the folder is
    /// offline and not watched, and a rescan leaves the catalog's rows alone.
    @MainActor
    func testOpeningWithAnotherDriveOfTheSameNameDoesNotScanIt() async throws {
        let (store, _, asset) = try catalogOnDrive()
        try unplug("Photos")
        try makeTestJPEG(at: try mountDrive("Photos", id: "drive-b").appendingPathComponent("Shoot/IMG_0001.JPG"), shade: 7)

        let app = AppState()
        app.onboarded = true
        app.volumeProbe = probe
        XCTAssertTrue(app.openCatalog(at: store.packageURL))
        try await waitUntil("originals checked") { !app.isCheckingOriginals }

        XCTAssertEqual(app.folders.first { $0.id == "source-1" }?.status, "offline")
        XCTAssertEqual(app.assets.first { $0.id == asset.id }?.status, .offline)
        app.rescanCurrentSource()
        try await waitUntil("rescan finished") { !app.isIncrementalRescanning }
        XCTAssertEqual(try store.loadAssets().first { $0.id == asset.id }?.quickHash, asset.quickHash)
    }

    /// Opening the catalog while the folder's drive is mounted as "Photos 1", another drive having
    /// taken "Photos": the folder and its photos are found on their own drive.
    @MainActor
    func testOpeningFindsTheFoldersDriveUnderAnotherName() async throws {
        let (store, _, asset) = try catalogOnDrive()
        try unplug("Photos")
        try makeTestJPEG(at: try mountDrive("Photos", id: "drive-b").appendingPathComponent("Shoot/IMG_0001.JPG"), shade: 7)
        try plugIn("Photos", as: "Photos 1")
        let moved = volumes.appendingPathComponent("Photos 1/Shoot")

        let app = AppState()
        app.onboarded = true
        app.volumeProbe = probe
        XCTAssertTrue(app.openCatalog(at: store.packageURL))
        try await waitUntil("originals checked") { !app.isCheckingOriginals }

        XCTAssertEqual(app.folders.first { $0.id == "source-1" }?.status, "online")
        XCTAssertEqual(try store.loadSourceRoots().first?.pathHint, moved.path)
        let found = try XCTUnwrap(app.assets.first { $0.id == asset.id })
        XCTAssertEqual(found.localPath, moved.appendingPathComponent("IMG_0001.JPG").path)
        XCTAssertEqual(found.status, .ready)
        try await rescanToCompletion(app)
        XCTAssertEqual(try store.loadAssets().first { $0.id == asset.id }?.quickHash, asset.quickHash)
    }

    // ---------- a drive plugged in after the catalog opened (#32) ----------

    /// The folder's drive isn't plugged in when the catalog opens. Plugged in later, the folder is
    /// online and watched again: a photo added to it meanwhile comes in, and ⌘R rescans it.
    @MainActor
    func testDrivePluggedInAfterOpeningIsWatchedAgain() async throws {
        let (store, _, asset) = try catalogOnDrive()
        try unplug("Photos")
        let app = AppState()
        app.onboarded = true
        app.volumeProbe = probe
        XCTAssertTrue(app.openCatalog(at: store.packageURL))
        try await waitUntil("originals checked") { !app.isCheckingOriginals }
        XCTAssertEqual(app.folders.first { $0.id == "source-1" }?.status, "offline")
        XCTAssertEqual(app.assets.first { $0.id == asset.id }?.status, .offline)

        try plugIn("Photos")
        try makeTestJPEG(at: volumes.appendingPathComponent("Photos/Shoot/IMG_0002.JPG"), shade: 4)
        app.volumesDidChange()
        try await waitUntil("the photo added meanwhile comes in") {
            app.assets.contains { $0.filename == "IMG_0002.JPG" } && !app.isCheckingOriginals
        }

        XCTAssertEqual(app.folders.first { $0.id == "source-1" }?.status, "online")
        XCTAssertEqual(try store.loadSourceRoots().first?.status, "online")
        XCTAssertEqual(app.assets.first { $0.id == asset.id }?.status, .ready)
        try await rescanToCompletion(app)
    }

    /// A folder whose bookmark can't be resolved because its drive isn't plugged in is offline,
    /// not waiting for permission.
    @MainActor
    func testFolderOnAnUnpluggedDriveIsOfflineNotWaitingForPermission() async throws {
        let (store, root, _) = try catalogOnDrive()
        // a bookmark that can't be resolved, as one to a drive that isn't plugged in, and no drive recorded
        try store.updateSourceRootAccess(id: root.id, displayName: root.displayName, path: root.pathHint,
                                         bookmark: Data([1, 2, 3]), status: "online", volumeIdentifier: nil)
        try unplug("Photos")

        let app = AppState()
        app.onboarded = true
        app.volumeProbe = probe
        XCTAssertTrue(app.openCatalog(at: store.packageURL))

        XCTAssertEqual(try store.loadSourceRoots().first?.status, "offline")
    }

    // ---------- a drive renamed or remounted elsewhere while the catalog is open (#50) ----------

    /// Renaming a drive is a drive change the app hears about.
    @MainActor
    func testVolumeMonitorHearsADriveRenamed() async throws {
        final class Count: @unchecked Sendable { var value = 0 }
        let count = Count()
        let monitor = VolumeMonitor { count.value += 1 }
        monitor.start()
        defer { monitor.stop() }

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didRenameVolumeNotification, object: nil)

        try await waitUntil("the rename is heard", timeout: 2) { count.value == 1 }
    }

    /// The folder's drive is renamed while the catalog is open: the folder and its photos move to
    /// the new name, and the folder is watched there.
    @MainActor
    func testDriveRenamedWhileOpenMovesItsFolder() async throws {
        let (store, _, asset) = try catalogOnDrive()
        let app = AppState()
        app.onboarded = true
        app.volumeProbe = probe
        XCTAssertTrue(app.openCatalog(at: store.packageURL))
        try await waitUntil("originals checked") { !app.isCheckingOriginals }

        try FileManager.default.moveItem(at: volumes.appendingPathComponent("Photos"),
                                         to: volumes.appendingPathComponent("Archive"))
        let renamed = volumes.appendingPathComponent("Archive/Shoot")
        try makeTestJPEG(at: renamed.appendingPathComponent("IMG_0002.JPG"), shade: 4)
        app.volumesDidChange()
        try await waitUntil("the photo added there comes in") {
            app.assets.contains { $0.filename == "IMG_0002.JPG" } && !app.isCheckingOriginals
        }

        XCTAssertEqual(try store.loadSourceRoots().first?.pathHint, renamed.path)
        let moved = try XCTUnwrap(app.assets.first { $0.id == asset.id })
        XCTAssertEqual(moved.localPath, renamed.appendingPathComponent("IMG_0001.JPG").path)
        XCTAssertEqual(moved.status, .ready)
        XCTAssertEqual(app.folders.first { $0.id == "source-1" }?.status, "online")
    }

    /// The drive is unplugged and plugged back in while another drive has taken its name: its
    /// folder is found under the new name; the other drive isn't read.
    @MainActor
    func testDriveRemountedUnderAnotherNameWhileOpenIsFollowed() async throws {
        let (store, _, asset) = try catalogOnDrive()
        let app = AppState()
        app.onboarded = true
        app.volumeProbe = probe
        XCTAssertTrue(app.openCatalog(at: store.packageURL))
        try await waitUntil("originals checked") { !app.isCheckingOriginals }

        try unplug("Photos")
        app.volumesDidChange()
        try await waitUntil("originals checked") { !app.isCheckingOriginals }
        XCTAssertEqual(app.assets.first { $0.id == asset.id }?.status, .offline)
        try makeTestJPEG(at: try mountDrive("Photos", id: "drive-b").appendingPathComponent("Shoot/IMG_0009.JPG"), shade: 7)
        try plugIn("Photos", as: "Photos 1")
        app.volumesDidChange()
        try await waitUntil("originals checked") { !app.isCheckingOriginals && !app.isIncrementalRescanning }

        let moved = volumes.appendingPathComponent("Photos 1/Shoot")
        XCTAssertEqual(try store.loadSourceRoots().first?.pathHint, moved.path)
        XCTAssertEqual(app.assets.first { $0.id == asset.id }?.localPath, moved.appendingPathComponent("IMG_0001.JPG").path)
        XCTAssertEqual(app.assets.first { $0.id == asset.id }?.status, .ready)
        XCTAssertFalse(app.assets.contains { $0.filename == "IMG_0009.JPG" }, "the other drive isn't read")
    }

    /// The drive is swapped for another of the same name while the catalog is open: a rescan of
    /// the folder doesn't read the other drive's files into the catalog.
    @MainActor
    func testRescanSkipsAnotherDriveOfTheSameName() async throws {
        let (store, _, asset) = try catalogOnDrive()
        let app = AppState()
        app.onboarded = true
        app.volumeProbe = probe
        XCTAssertTrue(app.openCatalog(at: store.packageURL))
        try await waitUntil("originals checked") { !app.isCheckingOriginals }
        XCTAssertEqual(app.folders.first { $0.id == "source-1" }?.status, "online")

        try unplug("Photos")
        let other = try mountDrive("Photos", id: "drive-b").appendingPathComponent("Shoot")
        try makeTestJPEG(at: other.appendingPathComponent("IMG_0001.JPG"), shade: 7)
        try makeTestJPEG(at: other.appendingPathComponent("IMG_0002.JPG"), shade: 8)
        app.rescanCurrentSource()
        try await waitUntil("rescan finished") { !app.isIncrementalRescanning }

        XCTAssertEqual(try store.loadAssets().first { $0.id == asset.id }?.quickHash, asset.quickHash)
        XCTAssertFalse(app.assets.contains { $0.filename == "IMG_0002.JPG" }, "the other drive's photo isn't imported")
    }
}
