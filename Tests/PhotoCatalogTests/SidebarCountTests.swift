import XCTest
@testable import PhotoCatalog

/// The sidebar's counts follow ratings, flags, keywords and other metadata edits without
/// recounting the library, and come out the same as a recount would.
final class SidebarCountTests: CatalogTestCase {
    private let shot = Date(timeIntervalSince1970: 1_791_800_000)

    private func photo(_ id: String, _ name: String, raw: Bool, offset: TimeInterval = 0, rating: Int = 0,
                       keywords: [String] = [], project: String = "") -> Asset {
        var asset = Asset(id: id, pid: 0, ori: "l", thumb: "", preview: "", filename: name,
                          type: raw ? "CR3" : "JPEG", isRaw: raw, folderId: "day", folderName: "2026-10-12",
                          date: shot.addingTimeInterval(offset), width: 6000, height: 4000, orientation: 1,
                          camera: "Canon EOS R5", lens: "", focal: 50, aperture: 4, shutter: "1/100", iso: 100,
                          colorSpace: "sRGB", fileMB: 1, rating: rating, flag: .none, keywords: keywords,
                          title: "", caption: "", location: "", gps: (0, 0), status: .ready, importedAt: shot,
                          localPath: scratch.appendingPathComponent(name).path)
        asset.project = project
        return asset
    }

    private func smart(_ id: String, _ field: String, _ op: String, _ value: String) -> SmartAlbum {
        SmartAlbum(id: id, name: id, rule: SmartRule(conditions: [SmartCondition(field: field, op: op, value: value)]),
                   count: 0)
    }

    @MainActor
    func testReviewAndMetadataEditsPatchTheSidebarCounts() throws {
        let app = AppState.selfCheckFixture()
        app.pairRawAndJpeg = true
        let raw = photo("raw", "IMG_0002.CR3", raw: true, offset: 10, keywords: ["trip"])
        let jpeg = photo("jpeg", "IMG_0002.JPG", raw: false, offset: 10, keywords: ["trip"])
        let solo = photo("solo", "IMG_0001.CR3", raw: true, rating: 4, project: "Wedding")
        let other = photo("other", "IMG_0003.JPG", raw: false, offset: 20, keywords: ["home"])
        // enough other photos that patching a few edits beats recounting the library
        let others = (0..<8).map { photo("filler-\($0)", "IMG_1\($0).JPG", raw: false, offset: 100 + Double($0)) }
        app.assets = [solo, raw, jpeg, other] + others
        app.duplicateGroupsCache = []
        app.albums = [Album(id: "album", name: "Album", assetIds: [raw.id, jpeg.id, other.id])]
        let rated = smart("rated", "rating", ">=", "3")
        let trip = smart("trip", "keywords", "包含", "trip")
        let picks = smart("picks", "flag", "=", "pick")
        let wedding = smart("wedding", "search", "包含", "Wedding")
        app.smartAlbums = [rated, trip, picks, wedding]
        XCTAssertTrue(app.assetPairing.isHiddenCompanion(jpeg.id), "the JPEG is behind its RAW")

        XCTAssertEqual(app.countForSmartAlbum(rated), 1)
        XCTAssertEqual(app.countForSmartAlbum(trip), 1, "the pair counts once")
        XCTAssertEqual(app.countForAlbum(app.albums[0]), 2)
        let rebuilds = app.sidebarCountIndexRebuilds

        // a rating reaches the RAW's JPEG too, which still counts once
        XCTAssertTrue(app.setRating(4, on: [raw.id]))
        XCTAssertEqual(app.countForSmartAlbum(rated), 2)
        XCTAssertEqual(app.sidebarCounts, app.recountedSidebarCounts())

        XCTAssertTrue(app.setFlag(.pick, on: [other.id]))
        XCTAssertEqual(app.countForSmartAlbum(picks), 1)
        XCTAssertEqual(app.sidebarCounts, app.recountedSidebarCounts())

        XCTAssertTrue(app.mutate(app.withCompanions([raw.id])) { $0.keywords = ["beach"] })
        XCTAssertEqual(app.countForSmartAlbum(trip), 0)
        XCTAssertEqual(app.sidebarCounts.keywords["beach"], 1)
        XCTAssertEqual(app.sidebarCounts, app.recountedSidebarCounts())

        XCTAssertTrue(app.mutate(app.withCompanions([raw.id, other.id])) {
            $0.project = "Wedding"
            $0.client = "Acme"
        })
        XCTAssertEqual(app.countForSmartAlbum(wedding), 3)
        XCTAssertEqual(app.sidebarCounts.projects["Wedding"], 3)
        XCTAssertEqual(app.sidebarCounts.clients["Acme"], 2)
        XCTAssertEqual(app.sidebarCounts, app.recountedSidebarCounts())

        XCTAssertTrue(app.mutate([solo.id]) { $0.project = "" })
        XCTAssertEqual(app.sidebarCounts.projects["Wedding"], 2)
        XCTAssertEqual(app.sidebarCounts, app.recountedSidebarCounts())

        XCTAssertEqual(app.sidebarCountIndexRebuilds, rebuilds,
                       "review and metadata edits patch the counts instead of recounting every photo")

        // a structural change still recounts, and lands on the same numbers
        let patched = app.sidebarCounts
        app.assets = app.assets
        XCTAssertEqual(app.sidebarCounts, patched)
        XCTAssertEqual(app.sidebarCountIndexRebuilds, rebuilds + 1)
    }
}

extension SidebarCountTests {
    /// A Today (or This Week…) smart album counts as of the day it's read: an edit after midnight
    /// doesn't patch yesterday's count, and reading it then doesn't hand it back either.
    @MainActor
    func testRelativeDateSmartAlbumsCountAsOfTheDayTheyAreRead() throws {
        let app = AppState.selfCheckFixture()
        var now = shot
        app.sidebarClock = { now }
        // taken that day by its camera's clock, among photos from a month before
        let wallClock = now.captureWallClock(in: .current).timeIntervalSince(shot)
        let taken = photo("today", "IMG_0001.JPG", raw: false, offset: wallClock)
        let older = (0..<8).map {
            photo("older-\($0)", "IMG_1\($0).JPG", raw: false, offset: wallClock - 86_400 * Double(30 + $0))
        }
        app.assets = [taken] + older
        app.duplicateGroupsCache = []
        let today = SmartAlbum(id: "today", name: "Today",
                               rule: SmartRule(conditions: [SmartCondition(field: "datePreset", op: "=", value: "today")]),
                               count: 0)
        app.smartAlbums = [today]
        XCTAssertEqual(app.countForSmartAlbum(today), 1)

        now = now.addingTimeInterval(86_400)
        XCTAssertEqual(app.countForSmartAlbum(today), 0, "read the next day, the photo is yesterday's")

        now = now.addingTimeInterval(-86_400)
        XCTAssertEqual(app.countForSmartAlbum(today), 1)
        now = now.addingTimeInterval(86_400)
        XCTAssertTrue(app.setRating(3, on: [taken.id]))
        XCTAssertEqual(app.countForSmartAlbum(today), 0, "an edit the next day doesn't patch yesterday's count")
        XCTAssertEqual(app.sidebarCounts, app.recountedSidebarCounts())
    }

    /// The project and client lists keep through edits that leave projects and clients alone, and
    /// edits that change them patch the lists instead of recounting every photo, coming out as a
    /// recount would: most photos first, ties in the order a pass meets them, a value no photo
    /// has any more gone, values trimmed, and a RAW with its JPEG counted once.
    @MainActor
    func testProjectAndClientListsArePatchedAsARecountWouldCountThem() throws {
        let app = AppState.selfCheckFixture()
        app.pairRawAndJpeg = true
        let raw = photo("raw", "IMG_0002.CR3", raw: true, offset: 10, project: "Wedding")
        let jpeg = photo("jpeg", "IMG_0002.JPG", raw: false, offset: 10, project: "Wedding")
        // p0…p7 alternate between two projects; the first three have a client
        let others = (0..<8).map { index in
            var asset = photo("p\(index)", "IMG_1\(index).JPG", raw: false, offset: 100 + Double(index),
                              project: index % 2 == 0 ? "Portraits" : "Wedding")
            asset.client = index < 3 ? " Acme " : ""
            return asset
        }
        app.assets = [raw, jpeg] + others
        app.duplicateGroupsCache = []
        XCTAssertTrue(app.assetPairing.isHiddenCompanion(jpeg.id))
        func expectRecount(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
            let recounted = app.recountedMetadataLists()
            XCTAssertEqual(app.projectList, recounted.projects, message, file: file, line: line)
            XCTAssertEqual(app.clientList, recounted.clients, message, file: file, line: line)
        }
        func projects() -> [String] { app.projectList.map { "\($0.name) \($0.count)" } }
        XCTAssertEqual(projects(), ["Wedding 5", "Portraits 4"])
        XCTAssertEqual(app.clientList.map { "\($0.name) \($0.count)" }, ["Acme 3"])
        let rebuilds = app.metadataListRebuilds

        XCTAssertTrue(app.mutate(["p0"]) { $0.title = "Golden hour" })
        XCTAssertTrue(app.mutate(["p1"]) { $0.keywords = ["beach"] })
        expectRecount("a title and a keyword")
        XCTAssertEqual(app.metadataListRebuilds, rebuilds, "edits that leave projects and clients alone keep the lists")

        XCTAssertTrue(app.mutate(["p1"]) { $0.project = "Portraits" })
        XCTAssertEqual(projects(), ["Portraits 5", "Wedding 4"])
        expectRecount("a photo moved to the other project")

        // Portraits' first photo leaves it: a tie, which the photo Wedding is first on now wins
        XCTAssertTrue(app.mutate(["p0"]) { $0.project = "" })
        XCTAssertEqual(projects(), ["Wedding 4", "Portraits 4"])
        expectRecount("a project's first photo emptied")

        XCTAssertTrue(app.mutate(app.withCompanions([raw.id])) { $0.project = "" })
        XCTAssertEqual(projects(), ["Portraits 4", "Wedding 3"])
        expectRecount("the RAW and its JPEG emptied, once")

        XCTAssertTrue(app.mutate(["p0"]) { $0.project = "Wedding" })
        XCTAssertEqual(projects(), ["Wedding 4", "Portraits 4"], "a photo before a project's first one is its first now")
        expectRecount("a project set before its first photo")

        XCTAssertTrue(app.mutate([jpeg.id]) { $0.project = "Hidden" })
        XCTAssertEqual(projects(), ["Wedding 4", "Portraits 4"], "a JPEG behind its RAW isn't counted")
        expectRecount("the hidden JPEG alone")

        XCTAssertTrue(app.mutate(["p0", "p5", "p6", "p7"]) { $0.client = $0.id == "p0" ? "" : "Acme" })
        XCTAssertEqual(app.clientList.map { "\($0.name) \($0.count)" }, ["Acme 5"])
        expectRecount("a client added to some and taken from its first photo at once")

        XCTAssertTrue(app.mutate(["p3"]) { $0.project = " Wedding " })
        expectRecount("a value as it was with spaces around")

        XCTAssertTrue(app.mutate(Set(app.assets.filter { $0.project == "Portraits" }.map(\.id))) { $0.project = "" })
        XCTAssertEqual(projects(), ["Wedding 4"], "a project on no photo leaves the list")
        expectRecount("a project emptied")

        XCTAssertTrue(app.mutate(["p7"]) { $0.project = "Studio" })
        XCTAssertEqual(projects(), ["Wedding 3", "Studio 1"])
        expectRecount("a new project")

        // A on p0, p2, p4 and B on p1, p3: when p0 leaves A, A's first photo is p2, after B's
        let others8 = Set((0..<8).map { "p\($0)" })
        XCTAssertTrue(app.mutate(others8) { $0.project = ["p0": "A", "p2": "A", "p4": "A", "p1": "B", "p3": "B"][$0.id] ?? "" })
        XCTAssertEqual(projects(), ["A 3", "B 2"])
        expectRecount("projects set on many photos at once")
        XCTAssertTrue(app.mutate(["p0"]) { $0.project = "" })
        XCTAssertEqual(projects(), ["B 2", "A 2"], "tied, A's first photo now comes after B's")
        expectRecount("a project's first photo emptied, its next one after another's first")
        XCTAssertTrue(app.mutate(["p0", "p2"]) { $0.project = $0.id == "p0" ? "A" : "" })
        XCTAssertEqual(projects(), ["A 2", "B 2"])
        expectRecount("a project moved to a photo before its first, in one edit")
        XCTAssertTrue(app.mutate(["p0", "p5"]) { $0.project = $0.id == "p0" ? "" : "A" })
        XCTAssertEqual(projects(), ["B 2", "A 2"])
        expectRecount("a project moved from its first photo to a later one, in one edit")
        XCTAssertEqual(app.metadataListRebuilds, rebuilds, "project and client edits patch the lists")

        // a structural change still recounts them
        app.assets = app.assets
        expectRecount("after a structural change")
        XCTAssertEqual(app.metadataListRebuilds, rebuilds + 2)
    }

    /// The smart album editor's preview counts what the sidebar counts: a RAW and the JPEG shown
    /// behind it are one photo, in the preview's thumbnails too.
    @MainActor
    func testSmartAlbumPreviewLeavesOutHiddenCompanionsAsTheSidebarDoes() throws {
        let app = AppState.selfCheckFixture()
        app.pairRawAndJpeg = true
        let raw = photo("raw", "IMG_0002.CR3", raw: true, offset: 10, rating: 4)
        let jpeg = photo("jpeg", "IMG_0002.JPG", raw: false, offset: 10, rating: 4)
        let other = photo("other", "IMG_0003.JPG", raw: false, offset: 20, rating: 1)
        app.assets = [raw, jpeg, other]
        app.duplicateGroupsCache = []
        let rated = smart("rated", "rating", ">=", "4")
        app.smartAlbums = [rated]
        XCTAssertTrue(app.assetPairing.isHiddenCompanion(jpeg.id))
        XCTAssertEqual(app.countForSmartAlbum(rated), 1)

        let preview = try XCTUnwrap(SmartMatcher.preview(app.assets, rated.rule, pairing: app.assetPairing, limit: 14))
        XCTAssertEqual(preview.count, app.countForSmartAlbum(rated), "the editor and the sidebar agree")
        XCTAssertEqual(preview.first.map(\.id), [raw.id])
    }

    /// Counted in chunks on several threads, the sidebar's tallies come out as one pass's, and a
    /// smart album's count is the photos shown that its rule, read field by field, matches.
    func testChunkedTalliesAreOnePassCounts() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-31T18:00:00Z"))
        var photos = try SmartMatcherTests.variedPhotos(now: now)
        photos[3].deleted = true
        photos[4].client = "Acme"
        // a RAW and the JPEG shown behind it, in a folder of their own
        photos.insert(photo("raw", "IMG_0002.CR3", raw: true, rating: 4, keywords: ["Café"], project: "Wedding"), at: 5)
        photos.insert(photo("jpeg", "IMG_0002.JPG", raw: false, rating: 4, keywords: ["Café"], project: "Wedding"), at: 9)
        let pairing = AssetPairing.rawJpeg(photos)
        XCTAssertTrue(pairing.isHiddenCompanion("jpeg"))
        func rule(_ match: String, _ conditions: [(String, String, String)]) -> SmartRule {
            SmartRule(match: match, conditions: conditions.map { SmartCondition(field: $0.0, op: $0.1, value: $0.2) })
        }
        let rules = [
            rule("all", [("rating", ">=", "4")]),
            rule("all", [("keywords", "包含", "cafe")]),
            rule("all", [("captureYear", "=", "2023"), ("flag", "=", "pick")]),
            rule("any", [("datePreset", "=", "thisYear"), ("captureDate", ">=", "2025-06-01")]),
            rule("all", [("camera", "包含", "canon"), ("keywords", "包含", "旅行"), ("rating", ">=", "3")]),
            rule("any", [("search", "包含", "wedding"), ("lens", "包含", "rf"), ("captureYear", "<=", "1")]),
            rule("all", []),
        ]
        let compiled = rules.map { SmartMatcher.Prepared($0, now: now) }

        let whole = AppState.sidebarTallies(of: photos, pairing: pairing, rules: compiled, chunk: .max)
        for chunk in [1, 3, 7] {
            XCTAssertEqual(AppState.sidebarTallies(of: photos, pairing: pairing, rules: compiled, chunk: chunk), whole,
                           "in chunks of \(chunk)")
        }
        let shown = photos.filter(pairing.shows)
        XCTAssertEqual(shown.count, photos.count - 2)
        for (rule, count) in zip(rules, whole.smartAlbums) {
            let expected = shown.filter { photo in
                let each = rule.conditions.map { SmartMatcherTests.fieldByField(photo, $0, now: now) }
                return rule.match == "all" ? !each.contains(false) : each.contains(true)
            }.count
            XCTAssertEqual(count, expected, "\(rule.conditions.map(\.value))")
        }
        XCTAssertEqual(whole.folders, Dictionary(grouping: shown, by: \.folderId).mapValues(\.count))
        XCTAssertEqual(whole.projects, ["Wedding": shown.filter { $0.project == "Wedding" }.count])
        XCTAssertEqual(whole.clients, ["Acme": 1])

        // keyword counts too, each keyword where a single pass first meets it
        let keywords = shown.flatMap(\.keywords)
        var firstSeen: [String] = []
        for keyword in keywords where !firstSeen.contains(keyword) { firstSeen.append(keyword) }
        for chunk in [1, 3, 7, Int.max] {
            let counted = AppState.keywordCounts(of: photos, pairing: pairing, chunk: chunk)
            XCTAssertEqual(counted.order, firstSeen, "in chunks of \(chunk)")
            XCTAssertEqual(counted.counts, Dictionary(keywords.map { ($0, 1) }, uniquingKeysWith: +))
        }

        // and projects, clients and cameras: trimmed, most photos first, ties as a pass meets them
        for field in [\Asset.project, \Asset.client, \Asset.camera] {
            var order: [String] = []
            var counts: [String: Int] = [:]
            for photo in shown {
                let value = photo[keyPath: field].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { continue }
                if counts[value] == nil { order.append(value) }
                counts[value, default: 0] += 1
            }
            let expected = order.map { KeywordCount(name: $0, count: counts[$0] ?? 0) }.sorted { $0.count > $1.count }
            for chunk in [1, 3, 7, Int.max] {
                XCTAssertEqual(AppState.metadataCounts(photos, pairing: pairing, field, chunk: chunk).list, expected,
                               "\(field) in chunks of \(chunk)")
            }
        }

        // the library's counts: of the photos shown, and of every live file for missing or offline
        photos[1].status = .missing
        photos[9].status = .offline   // the JPEG behind its RAW
        let cutoff = now.addingTimeInterval(-90 * 86_400)
        let library = AppState.libraryCounts(photos, pairing: pairing, recentCutoff: cutoff, chunk: .max)
        XCTAssertEqual(library.all, shown.count)
        XCTAssertEqual(library.recent, shown.filter { $0.importedAt > cutoff }.count)
        XCTAssertEqual(library.unrated, shown.filter { $0.rating == 0 && $0.flag != .reject }.count)
        XCTAssertEqual(library.picks, shown.filter { $0.flag == .pick }.count)
        XCTAssertEqual(library.rejected, shown.filter { $0.flag == .reject }.count)
        XCTAssertEqual(library.places, shown.filter(\.hasGPS).count)
        XCTAssertEqual(library.missingOffline,
                       photos.filter { !$0.deleted && ($0.status == .missing || $0.status == .offline) }.count)
        for chunk in [1, 3, 7] {
            XCTAssertEqual(AppState.libraryCounts(photos, pairing: pairing, recentCutoff: cutoff, chunk: chunk), library,
                           "in chunks of \(chunk)")
        }

        // capture days, and each folder's photos
        let days = Dictionary(shown.compactMap { CaptureDates.day(of: $0.date) }.map { ($0, 1) }, uniquingKeysWith: +)
        for chunk in [1, 3, 7, Int.max] {
            XCTAssertEqual(CaptureDates.dayCounts(photos, pairing: pairing, chunk: chunk), days, "in chunks of \(chunk)")
        }
        XCTAssertEqual(CaptureDates.groups(dayCounts: days), CaptureDates.groups(shown))
        let directory = PathString.standardized(scratch.path)
        let items = Set(photos.map(\.folderId)).sorted().map {
            FolderTreeItem(id: $0, sourceId: $0, name: $0, status: "online", depth: 0, directoryPath: nil)
        } + [FolderTreeItem(id: "subfolder:" + directory, sourceId: "day", name: "day", status: "online", depth: 1,
                            directoryPath: directory)]
        var folders = Dictionary(grouping: shown, by: \.folderId).mapValues(\.count)
        folders["subfolder:" + directory] = shown.filter {
            $0.folderId == "day" && $0.localPath.map { PathString.standardized(PathString.directory(of: $0)) } == directory
        }.count
        XCTAssertGreaterThan(folders["subfolder:" + directory] ?? 0, 0)
        for chunk in [1, 3, 7, Int.max] {
            XCTAssertEqual(FolderTreeService.counts(for: items, assets: photos, pairing: pairing, chunk: chunk), folders,
                           "in chunks of \(chunk)")
        }
    }
}

extension SidebarCountTests {
    /// A project or client typed with spaces around it is listed trimmed; its pinned count and its
    /// collection go by that trimmed name too, as the list counts it.
    @MainActor
    func testProjectWithSurroundingSpacesCountsAndShowsUnderItsTrimmedName() throws {
        let app = AppState.selfCheckFixture()
        var spaced = photo("spaced", "IMG_0001.JPG", raw: false, project: " Wedding ")
        spaced.client = "Acme "
        let plain = photo("plain", "IMG_0002.JPG", raw: false, offset: 10, project: "Wedding")
        let others = (0..<4).map { photo("filler-\($0)", "IMG_1\($0).JPG", raw: false, offset: 100 + Double($0)) }
        app.assets = [spaced, plain] + others
        app.duplicateGroupsCache = []
        XCTAssertEqual(app.projectList.first { $0.name == "Wedding" }?.count, 2)

        let project = PinnedSidebarItem(type: .project, selectionId: "Wedding", name: "Wedding")
        let client = PinnedSidebarItem(type: .client, selectionId: "Acme", name: "Acme")
        XCTAssertEqual(app.countForPinnedSidebarItem(project), "2", "the pinned project counts what the list does")
        XCTAssertEqual(app.countForPinnedSidebarItem(client), "1")
        XCTAssertEqual(app.sidebarCounts, app.recountedSidebarCounts())

        app.select(Selection(type: .project, id: "Wedding", name: "Wedding"))
        XCTAssertEqual(Set(app.list.map(\.id)), [spaced.id, plain.id], "the collection shows what it counts")
        app.select(Selection(type: .client, id: "Acme", name: "Acme"))
        XCTAssertEqual(app.list.map(\.id), [spaced.id])

        // an edit to the spacing alone keeps both where they were
        XCTAssertTrue(app.mutate([plain.id]) { $0.project = "Wedding  " })
        XCTAssertEqual(app.countForPinnedSidebarItem(project), "2")
        XCTAssertEqual(app.sidebarCounts, app.recountedSidebarCounts())
    }
}

extension SidebarCountTests {
    /// The keyword list's ties keep the order a pass over the photos meets them in, after edits as
    /// after a recount: a new keyword on an early photo, or a keyword taken off the photo it was
    /// first met on, moves among its ties as a recount would put it.
    @MainActor
    func testKeywordListTiesStayInTheOrderARecountGives() throws {
        let app = AppState.selfCheckFixture()
        let first = photo("first", "IMG_0001.JPG", raw: false, keywords: ["beach"])
        let second = photo("second", "IMG_0002.JPG", raw: false, offset: 10, keywords: ["city"])
        let later = photo("later", "IMG_0003.JPG", raw: false, offset: 20, keywords: ["beach"])
        let others = (0..<4).map { photo("filler-\($0)", "IMG_1\($0).JPG", raw: false, offset: 100 + Double($0)) }
        app.assets = [first, second, later] + others
        app.duplicateGroupsCache = []
        XCTAssertEqual(app.keywordList.map(\.name), ["beach", "city"])
        XCTAssertEqual(app.keywordList, app.recountedKeywordList())

        // a new keyword on the first photo is met before city
        XCTAssertTrue(app.mutate([first.id]) { $0.keywords = ["beach", "dawn"] })
        XCTAssertEqual(app.keywordList, app.recountedKeywordList(), "a new keyword sits where a pass meets it")

        // beach taken off the photo it was first met on is next met after city, so among the ties
        // of one photo each it comes after it
        XCTAssertTrue(app.mutate([first.id]) { $0.keywords = ["dawn"] })
        XCTAssertEqual(app.keywordList, app.recountedKeywordList(), "a keyword's first photo losing it moves it")

        // put back on a photo before any that has it
        XCTAssertTrue(app.mutate([second.id]) { $0.keywords = ["city", "dawn"] })
        XCTAssertTrue(app.mutate([first.id]) { $0.keywords = ["city"] })
        XCTAssertEqual(app.keywordList, app.recountedKeywordList(), "a keyword put on an earlier photo moves up")

        // an edit away from any keyword's first photo patches the counts and keeps the order
        XCTAssertTrue(app.mutate([later.id]) { $0.keywords = ["beach", "city"] })
        XCTAssertEqual(app.keywordList, app.recountedKeywordList())

        // new keywords on photos no keyword is first met on are put in their place, not recounted
        _ = app.keywordList
        XCTAssertTrue(app.mutate([others[2].id, others[0].id]) { $0.keywords = ["night", "stars"] })
        XCTAssertTrue(app.mutate([later.id]) { $0.keywords = ["beach", "city", "sunset"] })
        XCTAssertEqual(app.keywordList, app.recountedKeywordList(), "new keywords sit where a pass meets them")

        // single-pass and chunked counts agree on where each keyword is first met
        let counted = AppState.keywordCounts(of: app.assets, pairing: app.assetPairing)
        for chunk in [1, 2, 3] {
            let chunked = AppState.keywordCounts(of: app.assets, pairing: app.assetPairing, chunk: chunk)
            XCTAssertEqual(chunked.order, counted.order)
            XCTAssertEqual(chunked.first, counted.first, "in chunks of \(chunk)")
        }
    }
}
