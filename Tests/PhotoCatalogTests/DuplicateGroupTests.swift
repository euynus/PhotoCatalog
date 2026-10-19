import XCTest
@testable import PhotoCatalog

/// Duplicate groups keep their ids from one recompute to the next, and never hand one to another
/// group: the Duplicates view remembers which photo to keep, and which groups it has handled, by id.
final class DuplicateGroupTests: XCTestCase {
    func testIdenticalFileGroupsAreNamedByTheirPhotos() {
        let first = [photo("a1", contentHash: "aaa"), photo("a2", contentHash: "aaa")]
        let second = [photo("b1", contentHash: "bbb"), photo("b2", contentHash: "bbb")]

        assertStableIds(first, second, grouping: HashService.exactDuplicateGroups)
    }

    func testLikelyCopyGroupsAreNamedByTheirPhotos() {
        let first = [photo("a1", contentHash: "a1", quickHash: "qa"), photo("a2", contentHash: "a2", quickHash: "qa")]
        let second = [photo("b1", contentHash: "b1", quickHash: "qb"), photo("b2", contentHash: "b2", quickHash: "qb")]

        assertStableIds(first, second, grouping: HashService.suspectedDuplicateGroups)
    }

    func testLookAlikeGroupsAreNamedByTheirPhotos() {
        let first = [photo("a1", contentHash: "a1", perceptualHash: 0), photo("a2", contentHash: "a2", perceptualHash: 1)]
        let second = [photo("b1", contentHash: "b1", perceptualHash: .max), photo("b2", contentHash: "b2", perceptualHash: .max - 1)]

        assertStableIds(first, second, grouping: { PerceptualHash.similarGroups($0) })
    }

    /// Resolving one group (its other photos leave the catalog) and finding the groups again
    /// leaves no group under the resolved one's id: the view would show it as handled.
    func testAResolvedGroupsIdIsNotReused() {
        let photos = [photo("a1", contentHash: "aaa"), photo("a2", contentHash: "aaa"),
                      photo("b1", contentHash: "bbb"), photo("b2", contentHash: "bbb")]
        let before = HashService.exactDuplicateGroups(photos)
        XCTAssertEqual(before.count, 2)
        let resolved = before[0]
        let removed = Set(resolved.items.dropFirst().map(\.id))

        let after = HashService.exactDuplicateGroups(photos.filter { !removed.contains($0.id) })

        XCTAssertEqual(after.count, 1)
        XCTAssertNotEqual(after.first?.id, resolved.id, "the group left over doesn't take the resolved group's id")
        XCTAssertEqual(after.first?.id, before[1].id, "the group left over keeps its own id")
    }

    /// Two separate groups get different ids, and each keeps its id when found alongside the other.
    private func assertStableIds(_ first: [Asset], _ second: [Asset], grouping: ([Asset]) -> [DuplicateGroup],
                                 file: StaticString = #filePath, line: UInt = #line) {
        let firstAlone = grouping(first), secondAlone = grouping(second), both = grouping(first + second)
        XCTAssertEqual(firstAlone.count, 1, file: file, line: line)
        XCTAssertEqual(secondAlone.count, 1, file: file, line: line)
        XCTAssertNotEqual(firstAlone.first?.id, secondAlone.first?.id, "different photos, different group ids",
                          file: file, line: line)
        XCTAssertEqual(Set(both.map(\.id)), Set((firstAlone + secondAlone).map(\.id)),
                       "a group's id doesn't depend on the other groups found with it", file: file, line: line)
    }

    private func photo(_ id: String, contentHash: String? = nil, quickHash: String? = nil,
                       perceptualHash: UInt64? = nil) -> Asset {
        Asset(id: id, pid: 1, ori: "l", thumb: "", preview: "", filename: "\(id).jpg", type: "JPG", isRaw: false,
              folderId: "folder", folderName: "Folder", date: Date(timeIntervalSince1970: 1_700_000_000),
              width: 80, height: 60, orientation: 1, camera: "", lens: "", focal: 0, aperture: 0, shutter: "",
              iso: 0, colorSpace: "sRGB", fileMB: 1, rating: 0, flag: .none, keywords: [], title: "", caption: "",
              location: "", gps: (0, 0), status: .ready, importedAt: .now, contentHash: contentHash,
              quickHash: quickHash, isDemo: false, perceptualHash: perceptualHash)
    }
}

/// The Duplicates view shows each photo as it is now, not as it was when the groups were found.
final class DuplicateGroupMemberTests: CatalogTestCase {
    private static let defaultsKeys = ["pc_renameTemplate", "pc_autoWriteXMP"]
    private var savedDefaults: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for key in Self.defaultsKeys {
            if let value = UserDefaults.app.object(forKey: key) { savedDefaults[key] = value }
        }
    }

    override func tearDown() {
        for key in Self.defaultsKeys {
            if let value = savedDefaults[key] {
                UserDefaults.app.set(value, forKey: key)
            } else {
                UserDefaults.app.removeObject(forKey: key)
            }
        }
        savedDefaults = [:]
        super.tearDown()
    }

    @MainActor
    func testARenamedPhotoShowsItsNewName() throws {
        let (app, ids) = try appWithDuplicatePair()
        let photo = try XCTUnwrap(app.asset(id: ids[0]))

        app.renameOriginals(template: "Renamed", targets: [photo])

        let renamed = try XCTUnwrap(app.asset(id: ids[0]))
        XCTAssertEqual(renamed.filename, "Renamed_0001.jpg")
        let shown = app.duplicateGroups.first?.items.first { $0.id == ids[0] }
        XCTAssertEqual(shown?.filename, renamed.filename, "the group shows the new name")
        XCTAssertEqual(shown?.localPath, renamed.localPath, "and the new path")
    }

    @MainActor
    func testAShiftedPhotoShowsItsNewCaptureTime() throws {
        let (app, ids) = try appWithDuplicatePair()
        let before = try XCTUnwrap(app.asset(id: ids[1])?.date)
        app.selectedIds = [ids[1]]
        app.primaryId = ids[1]

        app.shiftCaptureTime(hours: 2)

        let shifted = try XCTUnwrap(app.asset(id: ids[1])?.date)
        XCTAssertNotEqual(shifted, before)
        XCTAssertEqual(app.duplicateGroups.first?.items.first { $0.id == ids[1] }?.date, shifted,
                       "the group shows the shifted capture time")
    }

    /// Two identical photos on disk, cataloged and found as one group of identical files.
    @MainActor
    private func appWithDuplicatePair() throws -> (AppState, [String]) {
        let photos = try (0..<2).map { index -> Asset in
            let url = scratch.appendingPathComponent("Source/copy-\(index).jpg")
            try makeTestJPEG(at: url, shade: 3)
            return Asset(id: "dup-member-\(index)", pid: 1, ori: "l", thumb: "", preview: "",
                         filename: url.lastPathComponent, type: "JPG", isRaw: false, folderId: "src-dup",
                         folderName: "Source", date: Date(timeIntervalSince1970: 1_700_000_000), width: 80, height: 60,
                         orientation: 1, camera: "", lens: "", focal: 0, aperture: 0, shutter: "", iso: 0,
                         colorSpace: "sRGB", fileMB: 0.01, rating: 0, flag: .none, keywords: [], title: "",
                         caption: "", location: "", gps: (0, 0), status: .ready, importedAt: .now,
                         localPath: url.path, contentHash: "same", isDemo: false)
        }
        let store = try CatalogStore(packageURL: scratch.appendingPathComponent("Library.photolibrary"))
        try store.upsert(photos)
        let app = AppState.selfCheckFixture(store: store)
        app.runsBackgroundMaintenance = false   // the groups stay as found: nothing recomputes them
        app.autoWriteXMPSidecar = false
        app.assets = photos
        app.duplicateGroupsCache = HashService.exactDuplicateGroups(photos)
        XCTAssertEqual(app.duplicateGroups.count, 1)
        return (app, photos.map(\.id))
    }
}
