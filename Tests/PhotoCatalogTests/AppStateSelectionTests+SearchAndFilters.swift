import XCTest
@testable import PhotoCatalog

extension AppStateSelectionTests {
    @MainActor
    func testSearchFiltersAndSortKeepListConsistent() throws {
        let app = AppState()
        app.onboarded = true
        let filename = try XCTUnwrap(app.assets.first?.filename)

        app.setSearch(filename)
        XCTAssertFalse(app.list.isEmpty)
        XCTAssertTrue(app.list.allSatisfy { $0.filename.localizedStandardContains(filename) })
        XCTAssertEqual(app.primaryId, app.list.first?.id)

        app.setSearch("")
        var filters = Filters()
        filters.minRating = 2
        filters.type = "RAW"
        app.setFilters(filters)
        XCTAssertFalse(app.list.isEmpty)
        XCTAssertTrue(app.list.allSatisfy { $0.rating >= 2 && $0.isRaw })

        app.setFilters(Filters())
        app.setSort(Sort(field: .name, descending: false))
        let ascending = app.list.map(\.filename)
        XCTAssertEqual(ascending, ascending.sorted { $0.localizedCompare($1) == .orderedAscending })

        app.setSort(Sort(field: .name, descending: true))
        let descending = app.list.map(\.filename)
        XCTAssertEqual(descending, ascending.reversed())
    }

    @MainActor
    func testRealCatalogSearchUsesSubstringIndexAndShortQueryFallback() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-indexed-search-\(UUID().uuidString)")
        let package = dir.appendingPathComponent("Library.photolibrary")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try CatalogStore(packageURL: package)
        var asset = try XCTUnwrap(DemoData.assets.first)
        asset.isDemo = false
        asset.deleted = false
        asset.title = "Graduation Needle 毕业照 5\"x7"
        asset.project = "Client Project"
        try store.upsert([asset])

        let app = AppState()
        app.onboarded = true
        XCTAssertTrue(app.openCatalog(at: package))

        app.setSearch("duation")
        XCTAssertEqual(app.list.map(\.id), [asset.id])

        app.setSearch("ent Pro")
        XCTAssertEqual(app.list.map(\.id), [asset.id])

        app.setSearch("5\"x7")
        XCTAssertEqual(app.list.map(\.id), [asset.id])

        app.setSearch("毕业")
        XCTAssertEqual(app.list.map(\.id), [asset.id])
    }

    @MainActor
    func testAdvancedFiltersMatchMetadataStatusAndLocation() throws {
        let app = AppState()
        app.onboarded = true

        var filters = Filters()
        filters.flag = Flag.pick.rawValue
        app.setFilters(filters)
        XCTAssertFalse(app.list.isEmpty)
        XCTAssertTrue(app.list.allSatisfy { $0.flag == .pick })

        let color = try XCTUnwrap(app.assets.first { $0.colorLabel != nil }?.colorLabel)
        filters = Filters()
        filters.color = color.rawValue
        app.setFilters(filters)
        XCTAssertFalse(app.list.isEmpty)
        XCTAssertTrue(app.list.allSatisfy { $0.colorLabel == color })

        let camera = try XCTUnwrap(app.assets.first?.camera)
        filters = Filters()
        filters.camera = camera
        app.setFilters(filters)
        XCTAssertFalse(app.list.isEmpty)
        XCTAssertTrue(app.list.allSatisfy { $0.camera.localizedStandardContains(camera) })

        let lens = try XCTUnwrap(app.assets.first?.lens)
        filters = Filters()
        filters.lens = lens
        app.setFilters(filters)
        XCTAssertFalse(app.list.isEmpty)
        XCTAssertTrue(app.list.allSatisfy { $0.lens.localizedStandardContains(lens) })

        filters = Filters()
        filters.gps = "yes"
        app.setFilters(filters)
        XCTAssertFalse(app.list.isEmpty)
        XCTAssertTrue(app.list.allSatisfy(\.hasGPS))

        filters = Filters()
        filters.status = AssetStatus.missing.rawValue
        app.setFilters(filters)
        XCTAssertFalse(app.list.isEmpty)
        XCTAssertTrue(app.list.allSatisfy { $0.status == .missing })
    }

    @MainActor
    func testLibrarySelectionsFilterExpectedAssets() {
        let app = AppState()
        app.onboarded = true

        app.select(Selection(type: .lib, id: "unrated", name: "未评分"))
        XCTAssertFalse(app.list.isEmpty)
        XCTAssertTrue(app.list.allSatisfy { $0.rating == 0 && $0.flag != .reject })

        app.select(Selection(type: .lib, id: "missing", name: "缺失 / 离线"))
        XCTAssertFalse(app.list.isEmpty)
        XCTAssertTrue(app.list.allSatisfy { $0.status == .missing || $0.status == .offline })
        XCTAssertEqual(app.primaryId, app.list.first?.id)
    }

    @MainActor
    func testProjectAndClientSelectionsFilterExpectedAssets() throws {
        let app = AppState()
        app.onboarded = true
        let project = try XCTUnwrap(app.projectList.first)
        let client = try XCTUnwrap(app.clientList.first)

        app.select(Selection(type: .project, id: project.name, name: project.name))
        XCTAssertEqual(app.list.count, project.count)
        XCTAssertTrue(app.list.allSatisfy { $0.project == project.name })
        XCTAssertEqual(app.primaryId, app.list.first?.id)

        app.select(Selection(type: .client, id: client.name, name: client.name))
        XCTAssertEqual(app.list.count, client.count)
        XCTAssertTrue(app.list.allSatisfy { $0.client == client.name })
        XCTAssertEqual(app.primaryId, app.list.first?.id)
    }

    @MainActor
    func testLargeLibrarySearchAndSortSmoke() {
        let app = AppState()
        app.onboarded = true
        app.assets = Self.largeAssetFixture(count: 100_000)
        app.albums = []
        app.smartAlbums = []
        app.folders = [Folder(id: "perf", name: "Performance")]
        app.duplicateGroupsCache = []
        app.filters.minRating = 4
        app.setSearch("needle")
        var sort = Sort()
        sort.field = .name
        sort.descending = false
        app.setSort(sort)

        let start = ContinuousClock.now
        let matches = app.list
        let elapsed = start.duration(to: .now)

        XCTAssertEqual(matches.count, 1_000)
        XCTAssertTrue(matches.allSatisfy { $0.rating >= 4 && $0.title.contains("needle") })
        XCTAssertLessThan(Self.seconds(elapsed), 2.0)
    }

    @MainActor
    func testLargeAlbumMembershipSmoke() {
        let app = AppState()
        app.onboarded = true
        app.assets = Self.largeAssetFixture(count: 100_000)
        let memberIds = stride(from: 0, to: 100_000, by: 2).map { "perf-\($0)" }
        app.albums = [Album(id: "large-album", name: "Large Album", assetIds: memberIds)]
        app.smartAlbums = []
        app.folders = [Folder(id: "perf", name: "Performance")]
        app.duplicateGroupsCache = []
        app.selection = Selection(type: .album, id: "large-album", name: "Large Album")

        let start = ContinuousClock.now
        let matches = app.list
        let elapsed = start.duration(to: .now)

        XCTAssertEqual(matches.count, 50_000)
        XCTAssertTrue(matches.allSatisfy { Int($0.id.dropFirst("perf-".count))?.isMultiple(of: 2) == true })
        XCTAssertLessThan(Self.seconds(elapsed), 2.0)
    }

    private static func seconds(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) + Double(c.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func largeAssetFixture(count: Int) -> [Asset] {
        let templates = DemoData.assets
        return (0..<count).map { i in
            let t = templates[i % templates.count]
            let hit = i % 100 == 0
            return Asset(
                id: "perf-\(i)",
                pid: t.pid + i,
                ori: t.ori,
                thumb: t.thumb,
                preview: t.preview,
                filename: String(format: "IMG_%06d.%@", i, t.type),
                type: t.type,
                isRaw: t.isRaw,
                folderId: "perf",
                folderName: "Performance",
                date: t.date.addingTimeInterval(Double(i)),
                width: t.width,
                height: t.height,
                orientation: t.orientation,
                camera: t.camera,
                lens: t.lens,
                focal: t.focal,
                aperture: t.aperture,
                shutter: t.shutter,
                iso: t.iso,
                colorSpace: t.colorSpace,
                fileMB: t.fileMB,
                rating: hit ? 4 : i % 4,
                flag: t.flag,
                colorLabel: t.colorLabel,
                keywords: hit ? ["needle"] : t.keywords,
                title: hit ? "needle \(i)" : "",
                caption: t.caption,
                project: t.project,
                client: t.client,
                location: t.location,
                gps: t.gps,
                status: .ready,
                importedAt: t.importedAt.addingTimeInterval(Double(i))
            )
        }
    }
}
