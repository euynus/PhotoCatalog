import XCTest
@testable import PhotoCatalog

/// Stacks are worked out from every photo after each structural change: originals with their
/// edited copies (by name), duplicate groups, and with auto-stacking on, bursts by capture time.
/// Whatever makes that faster, the stacks must be the ones the plain derivation gives — a frozen
/// copy of it is below — and so must what the window reads of them: each photo's stack badge, the
/// menu, and the photo list with stacks folded.
final class PhotoStackTests: CatalogTestCase {
    private let shot = Date(timeIntervalSince1970: 1_791_800_000)
    private var savedAutoStack: Any?

    override func setUp() {
        super.setUp()
        savedAutoStack = UserDefaults.app.object(forKey: "pc_autoStackSeconds")
    }

    override func tearDown() {
        UserDefaults.app.set(savedAutoStack, forKey: "pc_autoStackSeconds")
        super.tearDown()
    }

    private func photo(_ id: String, _ path: String?, filename: String? = nil, camera: String = "Canon EOS R5",
                       at offset: TimeInterval, deleted: Bool = false) -> Asset {
        let name = filename ?? path.map(PathString.lastComponent) ?? "\(id).JPG"
        let ext = PathString.splitExtension(name).ext.uppercased()
        return Asset(id: id, pid: 0, ori: "l", thumb: "", preview: "", filename: name, type: ext,
                     isRaw: ["CR3", "NEF", "ARW"].contains(ext), folderId: "src", folderName: "Photos",
                     date: shot.addingTimeInterval(offset), width: 6000, height: 4000, orientation: 1,
                     camera: camera, lens: "", focal: 50, aperture: 2, shutter: "1/200", iso: 100,
                     colorSpace: "sRGB", fileMB: 1, rating: 0, flag: .none, keywords: [], title: "", caption: "",
                     location: "", gps: (0, 0), status: .ready, importedAt: shot, deleted: deleted,
                     localPath: path, isDemo: false)
    }

    /// Every kind of stack and near miss: edited copies under each name the app and editors write
    /// (and names that only look like one), originals that are RAW+JPEG pairs, missing, deleted,
    /// in another folder or virtual copies; bursts with gaps of exactly the interval, ties in
    /// capture time, photos without a camera, deleted and hidden JPEGs between shots, a camera
    /// named in two Unicode forms; then a few hundred generated photos in three folders; and
    /// duplicate groups that overlap edited copies and bursts.
    private func catalog() -> (photos: [Asset], duplicates: [DuplicateGroup]) {
        let a = "/Volumes/Stacks/A", b = "/Volumes/Stacks/B"
        var photos: [Asset] = [
            // an original shot RAW+JPEG with its edited copies, in each language and numbering
            photo("e1r", "\(a)/IMG_0001.CR3", at: 0),
            photo("e1j", "\(a)/IMG_0001.JPG", at: 0.5),
            photo("e1a", "\(a)/IMG_0001-Edit.tif", camera: "", at: 900),
            photo("e1b", "\(a)/IMG_0001-编辑.tif", camera: "", at: 901),
            photo("e1c", "\(a)/IMG_0001-Edit (2).tif", camera: "", at: 902),
            photo("e1d", "\(a)/IMG_0001-编辑-2.tif", camera: "", at: 903),
            photo("e1e", "\(a)/img_0001-edit.tif", camera: "", at: 904),
            // names that aren't edited copies
            photo("n1", "\(a)/IMG_0001 (1).jpg", at: 2_000),
            photo("n2", "\(a)/IMG-Editor.jpg", at: 2_100),
            photo("n3", "\(a)/IMG_0001-edited.jpg", at: 2_200),
            // a JPEG original, then its RAW: the RAW leads the stack
            photo("e2j", "\(a)/IMG_0002.JPG", camera: "SONY ILCE-7M4", at: 3_000),
            photo("e2a", "\(a)/IMG_0002-Edit.tif", camera: "", at: 3_500),
            photo("e2r", "\(a)/IMG_0002.CR3", camera: "SONY ILCE-7M4", at: 3_000),
            // no original here: one in another folder, one deleted; an original with a virtual copy
            photo("e3a", "\(a)/IMG_0003-Edit.tif", at: 4_000),
            photo("e3o", "\(b)/IMG_0003.CR3", at: 4_100),
            photo("e4o", "\(a)/IMG_0004.CR3", at: 5_000, deleted: true),
            photo("e4a", "\(a)/IMG_0004-Edit.tif", at: 5_100),
            photo("e5o", "\(a)/IMG_0005.JPG", at: 6_000),
            photo("e5a", "\(a)/IMG_0005-Edit.tif", at: 6_100),
            // a file renamed in the catalog only: the name, not the path, says what it is
            photo("e6o", "\(a)/IMG_0006.JPG", at: 7_000),
            photo("e6a", "\(a)/IMG_0006-Edit.tif", filename: "Renamed.tif", at: 7_100),
            photo("e6b", nil, filename: "IMG_0006-Edit.tif", at: 7_200),
            // an edited copy of an edited copy has no original of its own
            photo("e7o", "\(a)/IMG_0007.JPG", at: 8_000),
            photo("e7a", "\(a)/IMG_0007-Edit.tif", at: 8_100),
            photo("e7b", "\(a)/IMG_0007-Edit-Edit.tif", at: 8_200),
            // a deleted edited copy
            photo("e8o", "\(a)/IMG_0008.JPG", at: 9_000),
            photo("e8a", "\(a)/IMG_0008-Edit.tif", at: 9_100, deleted: true),
            photo("e8b", "\(a)/IMG_0008-Edit (2).tif", at: 9_200),
            // a slash with a combining accent after it isn't a character of its own, so these
            // two are in /Volumes/Stacks as file names go; a folder named with the Kelvin sign is
            // the folder named K
            photo("e9o", "\(a)/\u{301}IMG_0009.JPG", at: 9_500),
            photo("e9a", "\(a)/\u{301}IMG_0009-Edit.tif", at: 9_600),
            photo("e10o", "/Volumes/Stacks/K/IMG_0010.JPG", at: 9_700),
            photo("e10a", "/Volumes/Stacks/\u{212A}/IMG_0010-Edit.tif", at: 9_800),
            // a burst: gaps of 1 s, exactly 5 s, then just over
            photo("c1", "\(b)/C_1.JPG", at: 20_000),
            photo("c2", "\(b)/C_2.JPG", at: 20_001),
            photo("c3", "\(b)/C_3.JPG", at: 20_006),
            photo("c4", "\(b)/C_4.JPG", at: 20_011.001),
            photo("c5", "\(b)/C_5.JPG", at: 20_012),
            // two shots at one moment, the later id first in the catalog
            photo("t-z", "\(b)/T_2.JPG", camera: "SONY ILCE-7M4", at: 21_000),
            photo("t-a", "\(b)/T_1.JPG", camera: "SONY ILCE-7M4", at: 21_000),
            photo("t-m", "\(b)/T_3.JPG", camera: "SONY ILCE-7M4", at: 21_000.5),
            // photos without a camera don't stack, and don't join the shots around them
            photo("x1", "\(b)/X_1.JPG", camera: "", at: 22_000),
            photo("x2", "\(b)/X_2.JPG", camera: "", at: 22_001),
            photo("x3", "\(b)/X_3.JPG", camera: "Canon EOS R6m2", at: 22_000.5),
            // a deleted photo between two shots doesn't bridge them
            photo("d1", "\(b)/D_1.JPG", camera: "NIKON Z 6_2", at: 23_000),
            photo("d2", "\(b)/D_2.JPG", camera: "NIKON Z 6_2", at: 23_004, deleted: true),
            photo("d3", "\(b)/D_3.JPG", camera: "NIKON Z 6_2", at: 23_008),
            // a RAW's JPEG between two RAWs bridges them only when it isn't hidden behind its RAW
            photo("h1", "\(b)/H_1.NEF", camera: "NIKON Z 6_2", at: 24_000),
            photo("h1j", "\(b)/H_1.JPG", camera: "NIKON Z 6_2", at: 24_001.9),
            photo("h2", "\(b)/H_2.NEF", camera: "NIKON Z 6_2", at: 24_006.5),
            // one camera's name in two Unicode forms, and a name with a trailing space
            photo("u1", "\(b)/U_1.JPG", camera: "Caf\u{E9} 1", at: 25_000),
            photo("u2", "\(b)/U_2.JPG", camera: "Cafe\u{301} 1", at: 25_001),
            photo("u3", "\(b)/U_3.JPG", camera: "Caf\u{E9} 1 ", at: 25_002),
            photo("u4", "\(b)/U_4.JPG", camera: "Caf\u{E9} 1 ", at: 25_003),
        ]
        // virtual copies: of an original (which stays the original), of an edited copy (not one
        // itself), and of a burst's shot (which it joins)
        photos.append(photos.first { $0.id == "e5o" }!.virtualCopy(id: "e5v", name: "副本 1"))
        photos.append(photos.first { $0.id == "e7a" }!.virtualCopy(id: "e7v", name: "副本 1"))
        photos.append(photos.first { $0.id == "c2" }!.virtualCopy(id: "c2v", name: "副本 1"))

        // generated: three folders, four cameras (one empty), shots a few seconds apart, some
        // RAW+JPEG, some edited copies of earlier names, some deleted, some virtual copies
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        let cameras = ["Canon EOS R5", "SONY ILCE-7M4", "", "FUJIFILM X-T4"]
        var time = 30_000.0
        for index in 0..<600 {
            let folder = "/Volumes/Stacks/G\(next(3))"
            time += [0, 0.5, 1, 2, 3, 5, 7, 30, 600][next(9)]
            let camera = cameras[next(cameras.count)]
            let deleted = next(30) == 0
            switch next(10) {
            case 0, 1:
                let raw = photo("g\(index)r", "\(folder)/G_\(index).CR3", camera: camera, at: time, deleted: deleted)
                photos.append(raw)
                photos.append(photo("g\(index)j", "\(folder)/G_\(index).JPG", camera: camera, at: time + 0.5))
            case 2:
                let of = next(max(index, 1))
                let ending = ["-Edit", "-编辑", "-Edit (2)", "-edit", "-Edit-3"][next(5)]
                photos.append(photo("g\(index)e", "\(folder)/G_\(of)\(ending).tif", camera: "", at: time,
                                    deleted: deleted))
            default:
                photos.append(photo("g\(index)", "\(folder)/G_\(index).JPG", camera: camera, at: time,
                                    deleted: deleted))
            }
            if next(40) == 0, let last = photos.last {
                photos.append(last.virtualCopy(id: "g\(index)v", name: "副本 1"))
            }
        }

        // duplicate groups: one overlapping an edited copy's stack, one a burst, one with a
        // deleted photo, and some generated ones
        func group(_ id: String, _ ids: [String], method: String = "contentHash") -> DuplicateGroup {
            DuplicateGroup(id: id, method: method, score: 1,
                           items: ids.compactMap { id in photos.first { $0.id == id } })
        }
        var duplicates = [
            group("dup-edit", ["e1c", "n1", "n2"]),
            group("dup-burst", ["c4", "c5", "x1"], method: "perceptualHash"),
            group("dup-deleted", ["d2", "e4o"]),
            group("dup-one", ["c1"]),
        ]
        let generated = photos.filter { $0.id.hasPrefix("g") }
        for index in 0..<25 {
            let ids = (0..<(2 + next(3))).map { _ in generated[next(generated.count)].id }
            duplicates.append(group("dup-g\(index)", ids, method: next(2) == 0 ? "contentHash" : "perceptualHash"))
        }
        return (photos, duplicates)
    }

    @MainActor
    private func app(_ photos: [Asset], _ duplicates: [DuplicateGroup], pairing: Bool,
                     seconds: Double?) -> AppState {
        let app = AppState.selfCheckFixture()
        app.runsBackgroundMaintenance = false
        app.pairRawAndJpeg = pairing
        app.autoStackSeconds = seconds
        app.assets = photos
        app.duplicateGroupsCache = duplicates
        app.select(Selection(type: .lib, id: "all", name: "All"))
        return app
    }

    private static let intervals: [Double?] = [nil, 0, 1, 2, 5, 60, 3_600, 1e9]

    /// The stacks are the plain derivation's, in its order, each with its photos in its order:
    /// with pairing on and off, and auto-stacking off or at several intervals.
    @MainActor
    func testStacksAreThePlainDerivations() throws {
        let (photos, duplicates) = catalog()
        for pairing in [true, false] {
            for seconds in Self.intervals {
                let app = app(photos, duplicates, pairing: pairing, seconds: seconds)
                let expected = Frozen.stacks(photos, pairing: app.assetPairing, duplicates: duplicates, seconds: seconds)
                XCTAssertEqual(app.photoStacks, expected, "pairing \(pairing), auto-stack \(seconds.map { "\($0)" } ?? "off")")
                XCTAssertEqual(app.hasStacks, !expected.isEmpty)
            }
        }
        // the catalog has each kind of stack, and auto-stacking makes some
        let app = app(photos, duplicates, pairing: true, seconds: 5)
        XCTAssertEqual(Set(app.photoStacks.map(\.method)), ["edit", "contentHash", "perceptualHash", "captureTime"])
        XCTAssertGreaterThan(app.photoStacks.filter { $0.method == "captureTime" }.count, 20)
        XCTAssertEqual(app.photoStacks.first { $0.assetIds.contains("e1r") }?.assetIds,
                       ["e1r", "e1a", "e1b", "e1c", "e1d", "e1e"], "the RAW leads; edited copies before duplicates")
        XCTAssertEqual(app.photoStacks.first { $0.assetIds.contains("t-a") }?.assetIds, ["t-a", "t-z", "t-m"])
        XCTAssertEqual(app.photoStacks.first { $0.assetIds.contains("e9a") }?.assetIds, ["e9o", "e9a"])
        XCTAssertEqual(app.photoStacks.first { $0.assetIds.contains("e10a") }?.assetIds, ["e10o", "e10a"])
    }

    /// The auto-stack dialog's preview counts what auto-stacking at each interval would make.
    @MainActor
    func testAutoStackPreviewCountsThePlainGroups() throws {
        let (photos, duplicates) = catalog()
        for pairing in [true, false] {
            let app = app(photos, duplicates, pairing: pairing, seconds: 5)
            let shown = photos.filter(app.assetPairing.shows)
            for seconds in Self.intervals.compactMap({ $0 }) {
                let groups = Frozen.captureTimeGroups(shown, within: seconds)
                let preview = app.autoStackPreview(seconds: seconds)
                XCTAssertEqual(preview.stacks, groups.count, "\(seconds) s")
                XCTAssertEqual(preview.photos, groups.reduce(0) { $0 + $1.count }, "\(seconds) s")
            }
        }
    }

    /// Each pass over the photos gives what one pass gives, however they're split among threads.
    func testChunkedPassesJoinInCatalogOrder() throws {
        let (photos, duplicates) = catalog()
        let pairing = AssetPairing.rawJpeg(photos)
        for seconds in [2, 1e9] {
            let groups = Frozen.editGroups(photos) + duplicates
            let captureTime = Frozen.captureTimeGroups(photos.filter(pairing.shows), within: seconds)
            for chunk in [1, 3, 4_096] {
                XCTAssertEqual(PhotoStackService.stacks(from: groups, captureTimeGroups: captureTime, chunk: chunk),
                               Frozen.stacks(from: groups, captureTimeGroups: captureTime),
                               "stacks, chunks of \(chunk), \(seconds) s")
            }
        }
        // edited copies' folders all in plain ASCII (told apart by their bytes) or not
        let ascii = photos.filter { !$0.id.hasPrefix("e10") }
        let expectedASCII = Frozen.editGroups(ascii).map { [$0.id, $0.method] + $0.items.map(\.id) }
        XCTAssertTrue(expectedASCII.contains { $0.contains("e9a") } && expectedASCII.count > 10)
        for chunk in [1, 3, 64, 65_536] {
            XCTAssertEqual(EditedVersions.groups(ascii, chunk: chunk).map { [$0.id, $0.method] + $0.items.map(\.id) },
                           expectedASCII, "edited copies in ASCII folders, chunks of \(chunk)")
        }
        let expectedEdits = Frozen.editGroups(photos).map { [$0.id, $0.method] + $0.items.map(\.id) }
        for seconds in Self.intervals.compactMap({ $0 }) {
            XCTAssertEqual(PhotoStackService.captureTimeGroups(photos.filter(pairing.shows), within: seconds),
                           Frozen.captureTimeGroups(photos.filter(pairing.shows), within: seconds), "\(seconds) s")
        }
        for chunk in [1, 3, 7, 64, 65_536] {
            XCTAssertEqual(EditedVersions.groups(photos, chunk: chunk).map { [$0.id, $0.method] + $0.items.map(\.id) },
                           expectedEdits, "edited copies, chunks of \(chunk)")
            let order = AppState.captureOrder(of: photos, pairing: pairing, chunk: chunk, run: max(chunk, 2)).keys
            for seconds in Self.intervals.compactMap({ $0 }) {
                XCTAssertEqual(PhotoStackService.groups(inCaptureOrder: order, of: photos, within: seconds),
                               Frozen.captureTimeGroups(photos.filter(pairing.shows), within: seconds),
                               "capture order, chunks of \(chunk), \(seconds) s")
            }
        }
    }

    /// Folding keeps each folded stack's first photo in the list's order, whatever the order and
    /// however the list is split among threads; also for stacks that share photos or an id.
    func testFoldingKeepsEachStacksFirstPhotoInOrder() throws {
        let (photos, duplicates) = catalog()
        let pairing = AssetPairing.rawJpeg(photos)
        var stacks = Frozen.stacks(photos, pairing: pairing, duplicates: duplicates, seconds: 5)
        // odd ones: a stack sharing photos with another, and one under another's id
        stacks.append(PhotoStack(id: "odd-shared", method: "contentHash", assetIds: [stacks[0].assetIds[0], "g7"]))
        stacks.append(PhotoStack(id: stacks[1].id, method: "contentHash", assetIds: ["g8", "g9", "g10"]))
        let orders = [photos, photos.reversed(), photos.sorted { $0.id < $1.id }]
        let foldings = [Set(stacks.map(\.id)), Set(stacks.enumerated().filter { $0.offset % 2 == 0 }.map(\.element.id)),
                        ["odd-shared", stacks[1].id], ["no such stack"], []]
        for (index, list) in orders.enumerated() {
            for folded in foldings {
                let expected = Frozen.visibleAssets(list, stacks: stacks, collapsedStackIds: folded).map(\.id)
                for chunk in [1, 5, 32_768] {
                    XCTAssertEqual(PhotoStackService.visibleAssets(list, stacks: stacks, collapsedStackIds: folded,
                                                                   chunk: chunk).map(\.id),
                                   expected, "order \(index), \(folded.count) folded, chunks of \(chunk)")
                }
            }
        }
    }

    /// The name test reads each byte once, as the four-byte window it replaced did; and every
    /// name the edited-copy pattern matches passes it, so it can stand before the pattern.
    func testEditedCopyNameTestMatchesTheByteWindow() throws {
        var names = ["", "e", "edi", "edit", "EDIT", "eDiT", "xEdIt", "IMG_1-Edit.tif", "IMG_1-编辑.tif", "编", "编辑",
                     "IMG_1.CR3", "ed it", "edjt", "Ｅｄｉｔ", "édit", "\u{E7}\u{BC}", "IMG-Editor", "credits.jpg",
                     "e\u{301}dit", "x编", "编x", "a very long file name of a photo without the word in it.JPG",
                     "IMG_1-Edit (2)", "IMG_1-编辑-2", "-edit", "a-Edit_3", "a-Edit(4)", "a-e\u{301}dit", "a-Ｅｄｉｔ",
                     "a-编辑 \u{661}", "a-Edit-\u{663}", "a-\u{FF25}dit", "a-Edit\n", "a-编辑\u{301}"]
        let alphabet = Array("eEdDiItT编辑x-_. 1()").map(String.init)
        var state: UInt64 = 7
        for _ in 0..<5_000 {
            var name = ""
            for _ in 0..<Int(state % 9) {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                name += alphabet[Int((state >> 33) % UInt64(alphabet.count))]
            }
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            names.append(name)
        }
        names.append(String(NSString(string: "bridged-Edit.tif")))
        for base in ["IMG_1", "a", "", "x-"] {
            for word in ["Edit", "edit", "编辑", "EDIT", "eDit", "Ed1t", "编"] {
                for ending in ["", " (2)", "-3", "_4", "(5)", " 6", "x", "-", " (\u{661})", "-\u{FF13}", "\u{301}"] {
                    names.append(base + "-" + word + ending)
                }
            }
        }
        var edited = 0
        for name in names {
            XCTAssertEqual(EditedVersions.mightBeEditedCopy(name), Frozen.mightBeEditedCopy(name), "“\(name)”")
            guard EditedVersions.originalStem(of: name) != nil else { continue }
            edited += 1
            XCTAssertTrue(EditedVersions.mightBeEditedCopy(name), "“\(name)”")
        }
        XCTAssertGreaterThan(edited, 50)
    }

    /// Each photo's stack badge, the menu's state, and the photo list with every stack folded or
    /// some: as the plain derivation's stacks give them.
    @MainActor
    func testBadgesMenuAndFoldedListFollowTheStacks() throws {
        let (photos, duplicates) = catalog()
        for (pairing, seconds) in [(true, nil), (true, 5), (false, 2)] as [(Bool, Double?)] {
            let app = app(photos, duplicates, pairing: pairing, seconds: seconds)
            let stacks = Frozen.stacks(photos, pairing: app.assetPairing, duplicates: duplicates, seconds: seconds)
            let unfolded = app.list
            XCTAssertEqual(app.hasStacks, !stacks.isEmpty)
            assertBadges(app, photos, stacks, collapsed: [])

            app.setAllStacksCollapsed(true)
            let all = Set(stacks.map(\.id))
            XCTAssertEqual(app.list.map(\.id),
                           Frozen.visibleAssets(unfolded, stacks: stacks, collapsedStackIds: all).map(\.id))
            assertBadges(app, photos, stacks, collapsed: all)

            // every third stack opened again
            var some = all
            for stack in stacks.enumerated().filter({ $0.offset % 3 == 0 }).map(\.element) {
                app.toggleStack(containing: stack.assetIds[stack.assetIds.count / 2])
                some.remove(stack.id)
            }
            XCTAssertEqual(app.list.map(\.id),
                           Frozen.visibleAssets(unfolded, stacks: stacks, collapsedStackIds: some).map(\.id))
            assertBadges(app, photos, stacks, collapsed: some)
        }
    }

    @MainActor
    private func assertBadges(_ app: AppState, _ photos: [Asset], _ stacks: [PhotoStack], collapsed: Set<String>,
                              file: StaticString = #filePath, line: UInt = #line) {
        var byPhoto: [String: PhotoStack] = [:]
        for stack in stacks { for id in stack.assetIds { byPhoto[id] = stack } }
        for asset in photos {
            let info = app.stackInfo(for: asset)
            let stack = byPhoto[asset.id]
            XCTAssertEqual(info?.count, stack?.count, asset.id, file: file, line: line)
            XCTAssertEqual(info?.collapsed, stack.map { collapsed.contains($0.id) }, asset.id, file: file, line: line)
        }
    }

    /// After a rename, a deletion, a new capture time and an import batch, the stacks are what
    /// working them out from the photos as they are then gives.
    @MainActor
    func testStacksFollowStructuralChanges() throws {
        let (photos, duplicates) = catalog()
        for (pairing, seconds) in [(true, 5), (false, 2), (true, nil)] as [(Bool, Double?)] {
            let app = app(photos, duplicates, pairing: pairing, seconds: seconds)
            func check(_ step: String, line: UInt = #line) {
                let expected = Frozen.stacks(app.assets, pairing: app.assetPairing, duplicates: duplicates,
                                             seconds: seconds)
                XCTAssertEqual(app.photoStacks, expected, "\(step), pairing \(pairing)", line: line)
                assertBadges(app, app.assets, expected, collapsed: [], line: line)
            }
            check("loaded")
            func edit(_ id: String, _ change: (inout Asset) -> Void) {
                var updated = app.assets
                change(&updated[updated.firstIndex { $0.id == id }!])
                app.assets = updated
            }
            edit("e1b") { $0.filename = "IMG_0001 copy.tif"; $0.localPath = "/Volumes/Stacks/A/IMG_0001 copy.tif" }
            check("an edited copy renamed")
            edit("c3") { $0.deleted = true }
            check("a burst's shot deleted")
            edit("d2") { $0.deleted = false }
            check("a photo restored")
            edit("x3") { $0.date = self.shot.addingTimeInterval(20_013) }
            check("a capture time changed")

            // an import batch: edited copies of photos already here (one under a name no photo
            // had edited before), shots continuing a burst, a RAW hiding an earlier JPEG, and a
            // JPEG original for an edited copy that had none
            let batch = [
                photo("i1", "/Volumes/Stacks/A/IMG_0001-Edit (3).tif", camera: "", at: 905),
                photo("i2", "/Volumes/Stacks/A/IMG_0002-编辑.tif", camera: "", at: 3_600),
                photo("i3", "/Volumes/Stacks/B/C_6.JPG", at: 20_016),
                photo("i4", "/Volumes/Stacks/B/C_0.JPG", at: 19_996),
                photo("i5", "/Volumes/Stacks/A/IMG_0003.JPG", at: 4_200),
                photo("i6", "/Volumes/Stacks/B/H_2.JPG", camera: "NIKON Z 6_2", at: 24_007),
                photo("i7", "/Volumes/Stacks/B/N_1.NEF", camera: "Leica M11", at: 26_000),
                photo("i8", "/Volumes/Stacks/B/N_2.NEF", camera: "Leica M11", at: 26_001),
                photo("i9", "/Volumes/Stacks/A/IMG_0009-Edit.tif", camera: "", at: 10_100),
                photo("i10", "/Volumes/Stacks/A/IMG_0009.JPG", at: 10_000),
            ]
            app.appendAssets(Array(batch.prefix(5)))
            check("an import batch")
            app.appendAssets(Array(batch.dropFirst(5)))
            check("another import batch")
        }
    }

    /// An import batch carries what stacks are worked out from on to its photos
    /// (`carryStacks`, which `appendAssets` calls) rather than working it out from every photo
    /// again: the stacks are then the plain derivation's. Edited copies of names already edited,
    /// originals arriving for copies that had none, a RAW taking over from a JPEG original or
    /// hiding a burst's JPEG, a second RAW showing a JPEG again, shots tied in time with others:
    /// carried. A camera no photo named, or a copy of a name never edited: worked out again.
    @MainActor
    func testImportBatchesCarryStacksOn() throws {
        let (photos, duplicates) = catalog()
        let a = "/Volumes/Stacks/A", b = "/Volumes/Stacks/B"
        for (pairing, seconds) in [(true, 5), (false, 2), (true, nil), (true, 1e9)] as [(Bool, Double?)] {
            let app = app(photos, duplicates, pairing: pairing, seconds: seconds)
            _ = app.photoStacks
            func append(_ batch: [Asset], carried: Bool = true, orderCarried: Bool = true,
                        line: UInt = #line) {
                let start = app.assets.count
                let before = app.assetPairing
                let derivations = app.stackSourceDerivations
                app.appendAssets(batch)
                let after = app.assetPairing
                let flipped = (0..<start).filter {
                    before.isShown(app.assets[$0], at: $0) != after.isShown(app.assets[$0], at: $0)
                }
                app.carryStacks(appendedFrom: start, flipped: flipped)
                let expected = Frozen.stacks(app.assets, pairing: after, duplicates: duplicates, seconds: seconds)
                XCTAssertEqual(app.photoStacks, expected, "pairing \(pairing), \(seconds.map { "\($0)" } ?? "off")",
                               line: line)
                assertBadges(app, app.assets, expected, collapsed: [], line: line)
                let worked = (carried ? 0 : 1) + (seconds == nil || orderCarried ? 0 : 1)
                XCTAssertEqual(app.stackSourceDerivations - derivations, worked, "worked out again", line: line)
            }
            append([
                photo("b1", "\(a)/IMG_0001-Edit (3).tif", camera: "", at: 905),
                photo("b2", "\(a)/IMG_0008.CR3", at: 8_999.5),   // sorts just before the JPEG it hides
                photo("b3", "\(b)/C_3.CR3", at: 20_006.2),
                photo("b4", "\(b)/H_1.CR3", camera: "NIKON Z 6_2", at: 24_000.5),
                photo("b5", "\(b)/C_6.JPG", at: 20_016),
                photo("t-b", "\(b)/T_0.JPG", camera: "SONY ILCE-7M4", at: 21_000),
            ])
            append([
                photo("b6", "\(b)/N_1.NEF", camera: "Leica M11", at: 26_000),
                photo("b7", "\(b)/N_2.NEF", camera: "Leica M11", at: 26_001),
                photo("b8", "\(a)/IMG_0003.JPG", at: 4_200),
            ], orderCarried: false)
            append([
                photo("b9", "\(a)/IMG_0009-Edit.tif", camera: "", at: 10_100),
                photo("b10", "\(a)/IMG_0009.JPG", at: 10_000),
                photo("b11", "\(b)/C_7.JPG", at: 20_020),
            ], carried: false)
            // a removed photo, a virtual copy of a burst's shot, and two batches with no redraw
            // between them
            append([photo("b12", "\(b)/C_8.JPG", at: 20_021, deleted: true),
                    app.assets.first { $0.id == "c1" }!.virtualCopy(id: "b13", name: "副本 2")])
            let start = app.assets.count
            app.appendAssets([photo("b14", "\(b)/C_9.JPG", at: 20_024)])
            app.carryStacks(appendedFrom: start, flipped: [])
            append([photo("b15", "\(b)/C_10.JPG", at: 20_027),
                    photo("b16", "\(a)/IMG_0001-编辑-4.tif", camera: "", at: 906)])
        }
    }
}

/// The derivation as it was before it was made faster (verbatim but for names): the reference
/// the tests above hold the app to.
private enum Frozen {
    static func stacks(_ assets: [Asset], pairing: AssetPairing, duplicates: [DuplicateGroup],
                       seconds: Double?) -> [PhotoStack] {
        let captureTime = seconds.map { captureTimeGroups(assets.filter(pairing.shows), within: $0) } ?? []
        return stacks(from: editGroups(assets) + duplicates, captureTimeGroups: captureTime)
    }

    static func stacks(from groups: [DuplicateGroup], captureTimeGroups: [[String]] = []) -> [PhotoStack] {
        var used = Set<String>()
        var result: [PhotoStack] = []
        for group in groups {
            let ids = group.items.map(\.id).filter { used.insert($0).inserted }
            guard ids.count > 1 else { continue }
            result.append(PhotoStack(id: stableId(method: group.method, assetIds: ids),
                                     method: group.method,
                                     assetIds: ids))
        }
        for group in captureTimeGroups {
            let ids = group.filter { used.insert($0).inserted }
            guard ids.count > 1 else { continue }
            result.append(PhotoStack(id: stableId(method: "captureTime", assetIds: ids), method: "captureTime", assetIds: ids))
        }
        return result
    }

    static func captureTimeGroups(_ assets: [Asset], within seconds: TimeInterval) -> [[String]] {
        let sorted = assets.filter { !$0.camera.isEmpty }
            .sorted { ($0.camera, $0.date, $0.id) < ($1.camera, $1.date, $1.id) }
        var groups: [[String]] = []
        var current: [String] = []
        var previous: Asset?
        for asset in sorted {
            if let previous, previous.camera == asset.camera, asset.date.timeIntervalSince(previous.date) <= seconds {
                current.append(asset.id)
            } else {
                if current.count > 1 { groups.append(current) }
                current = [asset.id]
            }
            previous = asset
        }
        if current.count > 1 { groups.append(current) }
        return groups
    }

    private static func stableId(method: String, assetIds: [String]) -> String {
        "stack-\(method)-" + assetIds.sorted().joined(separator: "-")
    }

    static func visibleAssets(_ assets: [Asset], stacks: [PhotoStack],
                              collapsedStackIds: Set<String>) -> [Asset] {
        guard !collapsedStackIds.isEmpty else { return assets }
        var stackByAsset: [String: PhotoStack] = [:]
        for stack in stacks where collapsedStackIds.contains(stack.id) {
            for id in stack.assetIds { stackByAsset[id] = stack }
        }

        var seenStacks = Set<String>()
        return assets.filter { asset in
            guard let stack = stackByAsset[asset.id] else { return true }
            return seenStacks.insert(stack.id).inserted
        }
    }

    static func mightBeEditedCopy(_ name: String) -> Bool {
        var window: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
        for byte in name.utf8 {
            let folded = byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte
            window = (window.1, window.2, window.3, folded)
            if window == (0x65, 0x64, 0x69, 0x74) { return true }                  // "edit"
            if window.1 == 0xE7 && window.2 == 0xBC && window.3 == 0x96 { return true } // "编"
        }
        return false
    }

    private static let editedNameEnding = #"-(编辑|[Ee]dit)(?:[-_ ]\(?\d+\)?)?$"#

    static func originalStem(of stem: String) -> String? {
        guard let ending = stem.range(of: editedNameEnding, options: .regularExpression) else { return nil }
        let original = String(stem[..<ending.lowerBound])
        return original.isEmpty ? nil : original
    }

    static func editGroups(_ assets: [Asset]) -> [DuplicateGroup] {
        func split(_ path: String) -> (dir: String, stem: String) {
            (PathString.directory(of: path), String(PathString.splitExtension(PathString.lastComponent(path)).stem))
        }
        var edits: [(asset: Asset, key: String)] = []
        var directories = Set<String>()
        for asset in assets where !asset.deleted && !asset.isVirtualCopy {
            guard mightBeEditedCopy(asset.filename), let path = asset.localPath else { continue }
            let (dir, stem) = split(path)
            guard let original = originalStem(of: stem) else { continue }
            edits.append((asset, dir + "/" + original.lowercased()))
            directories.insert(dir)
        }
        guard !edits.isEmpty else { return [] }
        var originals: [String: Asset] = [:]
        for asset in assets where !asset.deleted && !asset.isVirtualCopy {
            guard let path = asset.localPath else { continue }
            let dir = PathString.directory(of: path)
            guard directories.contains(dir) else { continue }
            let stem = String(PathString.splitExtension(PathString.lastComponent(path)).stem)
            guard originalStem(of: stem) == nil else { continue }
            let key = dir + "/" + stem.lowercased()
            if let existing = originals[key], existing.isRaw || !asset.isRaw { continue }
            originals[key] = asset
        }
        var grouped: [String: [Asset]] = [:]
        var order: [String] = []
        for edit in edits {
            guard originals[edit.key] != nil else { continue }
            if grouped[edit.key] == nil { order.append(edit.key) }
            grouped[edit.key, default: []].append(edit.asset)
        }
        return order.compactMap { key in
            guard let original = originals[key], let copies = grouped[key] else { return nil }
            return DuplicateGroup(id: "edit-" + original.id, method: "edit", score: 1, items: [original] + copies)
        }
    }
}
