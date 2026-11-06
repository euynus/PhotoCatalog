import XCTest
import Observation
@testable import PhotoCatalog

private actor ObservationFlag {
    private var changed = false
    func markChanged() { changed = true }
    func value() -> Bool { changed }
}

extension AppStateSelectionTests {
    @MainActor
    func testCompareSelectionTracksSearchResults() {
        let app = AppState()
        app.onboarded = true
        app.switchView(.compare)

        XCTAssertEqual(app.compareIds.count, 3)
        let firstId = app.compareIds[0]
        let firstFilename = app.assets.first { $0.id == firstId }?.filename
        XCTAssertNotNil(firstFilename)

        app.setSearch(firstFilename ?? "")
        XCTAssertEqual(app.compareIds, [firstId])
        XCTAssertEqual(app.selectedIds, Set([firstId]))

        app.setSearch("NO_SUCH_PHOTO_123")
        XCTAssertTrue(app.compareIds.isEmpty)
        XCTAssertTrue(app.selectedIds.isEmpty)
        XCTAssertNil(app.primaryId)
    }

    @MainActor
    func testCompareMembershipKeepsKeyboardSelectionAligned() throws {
        let app = AppState()
        app.onboarded = true
        app.switchView(.compare)
        let removed = try XCTUnwrap(app.compareIds.first)
        let replacement = try XCTUnwrap(app.list.first { !app.compareIds.contains($0.id) }?.id)
        app.winner = removed

        app.removeFromCompare(removed)

        XCTAssertFalse(app.compareIds.contains(removed))
        XCTAssertEqual(app.selectedIds, Set(app.compareIds))
        XCTAssertFalse(app.selectedIds.contains(removed))
        XCTAssertNil(app.winner)

        app.addToCompare(replacement)

        XCTAssertTrue(app.compareIds.contains(replacement))
        XCTAssertEqual(app.selectedIds, Set(app.compareIds))
    }

    @MainActor
    func testSelectionMutationRefreshesCachedListAndPrimary() throws {
        let app = AppState()
        app.onboarded = true
        let id = try XCTUnwrap(app.primaryId)
        _ = app.list

        XCTAssertTrue(app.handleKey("4", hasCommand: false))

        XCTAssertEqual(app.primary?.rating, 4)
        XCTAssertEqual(app.list.first { $0.id == id }?.rating, 4)
    }

    @MainActor
    func testPrimaryObservationInvalidatesAfterSelectionMutation() async throws {
        let app = AppState()
        app.onboarded = true
        let flag = ObservationFlag()
        withObservationTracking {
            _ = app.primary?.rating
        } onChange: {
            Task { await flag.markChanged() }
        }

        XCTAssertTrue(app.handleKey("4", hasCommand: false))
        try await Task.sleep(for: .milliseconds(50))

        let didChange = await flag.value()
        XCTAssertTrue(didChange)
        XCTAssertEqual(app.primary?.rating, 4)
    }

    @MainActor
    func testSingleAssetMutationRefreshesCachedList() throws {
        let app = AppState()
        app.onboarded = true
        let id = try XCTUnwrap(app.primaryId)
        _ = app.list

        app.mutateAsset(id) { $0.flag = .pick }

        XCTAssertEqual(app.primary?.flag, .pick)
        XCTAssertEqual(app.list.first { $0.id == id }?.flag, .pick)
    }

    @MainActor
    func testWelcomeStateDoesNotExposeHiddenDemoSelection() {
        let app = AppState()
        app.onboarded = false

        XCTAssertFalse(app.hasSelection)
        XCTAssertFalse(app.canApplySelectionToAlbum)
        XCTAssertFalse(app.canRemoveSelectionFromCurrentAlbum)
    }

    @MainActor
    func testOpeningRealCatalogSelectsFirstVisibleAsset() throws {
        preservingPreferences(["pc_catalogURL", "pc_recentCatalogs"])

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-open-selection-\(UUID().uuidString)")
        let source = dir.appendingPathComponent("Source")
        let package = dir.appendingPathComponent("Library.photolibrary")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try CatalogStore(packageURL: package)
        let realAssets = try DemoData.assets.dropFirst(5).prefix(2).map { base -> Asset in
            try store.addSourceRoot(id: base.folderId, displayName: base.folderName,
                                    path: source.path, bookmark: nil)
            var asset = base
            let file = source.appendingPathComponent(asset.filename)
            try Data("image".utf8).write(to: file)
            asset.localPath = file.path
            asset.status = .ready
            asset.isDemo = false
            asset.deleted = false
            return asset
        }
        try store.upsert(realAssets)

        let app = AppState()
        app.onboarded = true

        XCTAssertTrue(app.openCatalog(at: package))
        let firstVisible = try XCTUnwrap(app.list.first?.id)
        XCTAssertEqual(app.primaryId, firstVisible)
        XCTAssertEqual(app.selectedIds, [firstVisible])
    }
}
