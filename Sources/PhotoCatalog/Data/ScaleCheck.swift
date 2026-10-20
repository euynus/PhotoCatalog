import Foundation
import Darwin

/// Large-catalog benchmark: `PhotoCatalog --scale 500000 [catalog path]`.
/// Generates a realistic synthetic catalog once (reused by later runs of the same size), then
/// times what a user waits for at that size and reports memory. Build Release for real numbers.
enum ScaleCheck {
    @MainActor
    static func run(arguments: [String]) -> Int32 {
        let count = arguments.first.flatMap { Int($0) } ?? 100_000
        let url = arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("pc-scale-\(count).photolibrary")
        report("catalog \(url.path)")
        let baseline = footprint()

        guard let store = try? CatalogStore(packageURL: url) else {
            report("could not open the catalog")
            return 1
        }
        let existing = (try? store.loadAssetPage(limit: 0).totalCount) ?? 0
        if existing < count {
            let start = ContinuousClock.now
            generate(count - existing, from: existing, into: store)
            report("generate \(count - existing): \(seconds(since: start)) s, db \(megabytes(fileSize(url))) MB")
        }

        let (firstPage, pageTime) = timed { () -> AssetPage? in
            guard let fresh = try? CatalogStore(packageURL: url) else { return nil }
            return try? fresh.loadAssetPage(limit: 240)
        }
        report("open + first page (\(firstPage?.assets.count ?? 0)): \(pageTime) ms")

        let beforeLoad = footprint()
        let (loaded, loadTime) = timed { (try? store.loadAssets()) ?? [] }
        let live = loaded.filter { !$0.isDemo && !$0.deleted }
        report("hydrate \(live.count): \(loadTime) ms, \(delta(footprint(), beforeLoad)) MB")

        let app = AppState.selfCheckFixture(store: store)
        app.runsBackgroundMaintenance = false
        let beforeApply = footprint()
        let (_, applyTime) = timed { app.applyLoadedCatalogForScaleCheck(live, from: store) }
        report("apply catalog: \(applyTime) ms, \(delta(footprint(), beforeApply)) MB")
        // settings other runs of the app may have changed, which move the numbers
        report("RAW+JPEG pairing \(app.pairRawAndJpeg ? "on" : "off"), auto-stack "
            + (app.autoStackSeconds.map { "\($0) s" } ?? "off"))

        // PC_SCALE_LOOP=rate|name|keywords|dates|hydrate|apply|keyword-edit|sidebar|list|stacks|stacked|search-album|offline
        // repeats one operation for 20 s, to sample it
        if let loop = ProcessInfo.processInfo.environment["PC_SCALE_LOOP"] {
            let ids = app.list.prefix(1000).map(\.id)
            if loop == "sidebar" { app.smartAlbums = sidebarSmartAlbums }
            if loop == "search-album" { app.smartAlbums = [searchSmartAlbum] }
            if loop == "stacked" { addStackSources(app) }
            let end = Date().addingTimeInterval(20)
            var rounds = 0
            while Date() < end {
                switch loop {
                case "rate":
                    app.setPrimary(ids[rounds % ids.count])
                    _ = app.handleKey(String(rounds % 5 + 1), hasCommand: false)
                case "name":
                    app.sort = Sort(field: .name, descending: rounds % 2 == 0)
                    _ = app.list.count
                case "keywords":
                    app.assets = app.assets
                    _ = app.keywordList.count
                case "dates":
                    app.assets = app.assets
                    _ = app.captureDateGroups.count
                case "hydrate":
                    _ = try? store.loadAssets()
                case "apply":
                    let fresh = AppState.selfCheckFixture(store: store)
                    fresh.runsBackgroundMaintenance = false
                    fresh.applyLoadedCatalogForScaleCheck(live, from: store)
                case "keyword-edit":
                    app.selectedIds = Set(ids)
                    app.addKeyword("循环\(rounds)")
                case "sidebar":
                    app.smartAlbums = app.smartAlbums   // drops the sidebar's counts, and only them
                    _ = app.countForSmartAlbum(app.smartAlbums[0])
                case "list":
                    app.assets = app.assets
                    _ = app.assetPairing
                    _ = app.hasStacks
                    _ = app.list.count
                case "offline":
                    // 50,000 photos offline, then back (not a slice of the photos: held, it would be copied)
                    let drive = Array(app.assets.prefix(50_000))
                    app.applyAvailabilityChanges(drive.map {
                        AssetAvailabilityUpdate(assetId: $0.id, status: rounds % 2 == 0 ? .offline : .ready,
                                                localPath: $0.localPath)
                    })
                    _ = app.libraryCounts
                case "stacks", "stacked":
                    app.assets = app.assets
                    _ = app.assetPairing
                    _ = app.hasStacks
                case "search-album":
                    app.select(rounds % 2 == 0
                        ? Selection(type: .smart, id: searchSmartAlbum.id, name: searchSmartAlbum.name)
                        : Selection(type: .lib, id: "all", name: "全部照片"))
                    _ = app.list.count
                default:
                    break
                }
                rounds += 1
            }
            report("loop \(loop): \(rounds) rounds in 20 s")
            return 0
        }

        var line: [String] = []
        func step(_ label: String, _ body: () -> Void) {
            let (_, ms) = timed(body)
            line.append("\(label) \(ms)")
        }
        step("all") { _ = app.list.count }
        step("name↑") {
            app.sort = Sort(field: .name, descending: false)
            _ = app.list.count
        }
        step("rating") {
            app.sort = Sort(field: .rating, descending: true)
            _ = app.list.count
        }
        app.sort = Sort()
        step("≥3★") {
            app.filters.minRating = 3
            _ = app.list.count
        }
        app.filters = Filters()
        step("search") {
            app.search = "IMG_12"
            _ = app.list.count
        }
        app.search = ""
        step("keyword") {
            app.select(Selection(type: .keyword, id: "旅行", name: "旅行"))
            _ = app.list.count
        }
        step("folder") {
            app.select(Selection(type: .folder, id: "src-scale-3", name: "Root 3"))
            _ = app.list.count
        }
        app.smartAlbums = sidebarSmartAlbums
        step("smart album") {
            app.select(Selection(type: .smart, id: "scale-smart-canon-portraits", name: "canon-portraits"))
            _ = app.list.count
        }
        app.select(Selection(type: .lib, id: "all", name: "全部照片"))
        step("back to all") { _ = app.list.count }
        report("list ms: " + line.joined(separator: " · "))

        line = []
        step("library") { _ = app.libraryCounts }
        step("keywords") { _ = app.keywordList.count }
        step("dates") { _ = app.captureDateGroups.count }
        step("folders") { _ = app.folderTree.count }
        // a structural change re-derives stacks, edited copies' included
        step("stacks") {
            app.assets = app.assets
            if let first = app.list.first { _ = app.stackInfo(for: first) }
        }
        step("xmp candidates") { _ = app.xmpCheckCandidates().count }
        report("counts ms: " + line.joined(separator: " · "))

        line = []
        let ids = app.list.prefix(1000).map(\.id)
        step("select") { if let id = ids.first { app.setPrimary(id) } }
        step("rate 1") { _ = app.handleKey("3", hasCommand: false) }
        // The sidebar shows every album's count and re-reads them after each edit. The generated
        // catalog has no albums: these are a few smart albums of the kinds people make, and an album.
        app.smartAlbums = sidebarSmartAlbums
        app.albums = [Album(id: "scale-album", name: "Scale album", assetIds: ids)]
        func readSidebar() {
            for album in app.smartAlbums { _ = app.countForSmartAlbum(album) }
            for album in app.albums { _ = app.countForAlbum(album) }
        }
        step("sidebar") { readSidebar() }
        // the median of a few ratings, each on another photo, then the sidebar as it redraws
        // (to a tenth of a millisecond: with the counts patched in place it's well under one)
        var rounds: [Double] = []
        for round in 0..<5 {
            app.setPrimary(ids[(round + 1) % ids.count])
            let start = ContinuousClock.now
            _ = app.handleKey(String(round + 1), hasCommand: false)
            readSidebar()
            let elapsed = ContinuousClock.now - start
            rounds.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        }
        line.append("rate 1 + sidebar " + String(format: "%.1f", rounds.sorted()[rounds.count / 2]))
        // a title, then the sidebar's project and client lists as it redraws
        _ = app.projectList
        _ = app.clientList
        step("title 1 + lists") {
            app.mutate([ids[6]]) { $0.title = "Scale \(Date().timeIntervalSince1970)" }
            _ = app.projectList
            _ = app.clientList
        }
        step("project 1 + lists") {
            app.mutate([ids[6]]) { $0.project = $0.project.isEmpty ? "Scale project" : "" }
            _ = app.projectList
            _ = app.clientList
        }
        report("edits ms: " + line.joined(separator: " · "))

        // A structural change (an import batch, Move to Trash, a move or rename) drops what's
        // derived from every photo. The sidebar's recount alone; then a change, and what the
        // window works out again as it redraws, part by part; then the first ratings after it.
        line = []
        step("recount") {
            app.smartAlbums = app.smartAlbums   // drops the sidebar's counts, and only them
            readSidebar()
        }
        step("change") { app.assets = app.assets }
        step("pairing") { _ = app.assetPairing }
        step("keywords") { _ = app.keywordList }
        step("projects") {
            _ = app.projectList
            _ = app.clientList
        }
        step("sidebar") { readSidebar() }
        step("grid") {
            _ = app.list.count
            _ = app.libraryCounts
        }
        step("first rate") {
            app.setPrimary(ids[7])
            _ = app.handleKey("2", hasCommand: false)
            readSidebar()
        }
        step("next rate") {
            app.setPrimary(ids[8])
            _ = app.handleKey("3", hasCommand: false)
            readSidebar()
        }
        report("structure ms: " + line.joined(separator: " · "))
        structureParts(app, readSidebar: readSidebar)
        inPlaceChanges(app, readSidebar: readSidebar)

        line = []
        step("select all") { _ = app.handleKey("a", hasCommand: true) }
        app.selectedIds = Set(ids)
        app.primaryId = ids.first
        step("rate 1000") { _ = app.handleKey("4", hasCommand: false) }
        // values differ per run: the benchmark catalog keeps earlier runs' edits
        let run = Int(Date().timeIntervalSince1970) % 100_000
        step("keyword 1000") { app.addKeyword("批量测试\(run)") }
        step("develop 1000") {
            var edit = DevelopSettings()
            edit.exposure = Double(run % 400) / 100 - 2
            app.commitDevelop(Dictionary(uniqueKeysWithValues: ids.map { ($0, edit) }), undoName: "测试")
        }
        step("history 1000") {
            var edit = DevelopSettings()
            edit.contrast = Double(run % 100)
            _ = try? store.appendDevelopHistory(Dictionary(uniqueKeysWithValues: ids.map { ($0, (name: "测试", settings: edit)) }))
        }
        report("batch edits ms: " + line.joined(separator: " · "))

        // The photo list: All Photographs worked out again after a structural change (the pairing
        // and stacks first, which the grid's tiles and the menus read anyway), a smart album with
        // a full-text search condition, and ratings of RAW+JPEG pairs, which reach the JPEG
        // behind each tile (median of five).
        line = []
        app.select(Selection(type: .lib, id: "all", name: "全部照片"))
        app.sort = Sort()
        app.filters = Filters()
        app.search = ""
        app.assets = app.assets
        _ = app.assetPairing
        _ = app.hasStacks
        step("list after change") { _ = app.list.count }
        app.smartAlbums = sidebarSmartAlbums + [searchSmartAlbum]
        step("search album") {
            app.select(Selection(type: .smart, id: searchSmartAlbum.id, name: searchSmartAlbum.name))
            _ = app.list.count
        }
        app.select(Selection(type: .lib, id: "all", name: "全部照片"))
        let pairs = app.list.prefix(5_000).filter { !app.companions(of: $0).isEmpty }.prefix(5).map(\.id)
        var pairRatings: [Double] = []
        for (round, id) in pairs.enumerated() {
            app.setPrimary(id)
            _ = app.listPosition(of: id)
            let start = ContinuousClock.now
            _ = app.handleKey(String(round % 5 + 1), hasCommand: false)
            let elapsed = ContinuousClock.now - start
            pairRatings.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        }
        if !pairRatings.isEmpty {
            line.append("rate pair " + String(format: "%.1f", pairRatings.sorted()[pairRatings.count / 2]))
        }
        report("photo list ms: " + line.joined(separator: " · "))
        stackParts(app)
        report("footprint \(delta(footprint(), baseline)) MB since start, \(megabytes(footprint())) MB total")
        return 0
    }

    /// What the window works out again from every photo after a structural change, part by part
    /// (the photo list aside), as the sidebar, the filter bar and the inspector redraw; then the
    /// same after an import batch, which carries it all on to the new photos instead.
    @MainActor
    private static func structureParts(_ app: AppState, readSidebar: () -> Void) {
        var parts: [String] = []
        var total = 0.0
        func part(_ label: String, _ body: () -> Void) {
            let start = ContinuousClock.now
            body()
            let ms = milliseconds(since: start)
            parts.append(label + " " + String(format: "%.1f", ms))
            total += ms
        }
        func redraw() { rederive(app, readSidebar: readSidebar, part: part) }
        // every derived part dropped, the id index too, as for a new set of photos (changes in
        // place, such as Move to Trash or a rename, carry it all on: inPlaceChanges)
        part("change") { app.assets = app.assets }
        redraw()
        report("rederive ms: " + parts.joined(separator: " · ") + " · total " + String(format: "%.0f", total))

        // An import batch, as one arrives about once a second while importing: JPEGs of RAWs
        // already there (hidden behind them at once), RAWs of JPEGs already there (which hides
        // those), and photos of their own; then what the window reads again, and a check that
        // what was carried on is what working it all out again gives.
        let batch = importBatch(for: app, count: 32)
        (parts, total) = ([], 0)
        part("append \(batch.count)") { app.appendAssets(batch) }
        redraw()
        let differing = app.cachesDifferingFromRecount()
        let pairing = app.assetPairing
        let hidden = batch.filter { pairing.isHiddenCompanion($0.id) }.count
        let hiding = batch.reduce(0) { $0 + (pairing.companionsByPrimary[$1.id]?.count ?? 0) }
        report("import batch ms: " + parts.joined(separator: " · ") + " · total " + String(format: "%.1f", total)
            + " · \(hidden) new JPEGs hidden, \(hiding) earlier ones hidden"
            + (differing.isEmpty ? " · as a recount gives" : " · unlike a recount: " + differing.joined(separator: ", ")))
    }

    /// What the sidebar, the filter bar and the inspector read as the window redraws (the photo
    /// list aside), part by part.
    @MainActor
    private static func rederive(_ app: AppState, readSidebar: () -> Void, part: (String, () -> Void) -> Void) {
        part("pairing") { _ = app.assetPairing }
        part("index") { _ = app.assets.last.flatMap { app.asset(id: $0.id) } }
        part("library") { _ = app.libraryCounts }
        part("keywords") { _ = app.keywordList }
        part("lists") {
            _ = app.projectList
            _ = app.clientList
        }
        part("gear") { _ = app.gearCounts }
        withoutActuallyEscaping(readSidebar) { readSidebar in part("sidebar") { readSidebar() } }
        part("dates") { _ = app.captureDateGroups }
        part("folders") { for item in app.folderTree { _ = app.countForFolderTreeItem(item) } }
    }

    /// Changes that leave every photo where it is, each followed by what the window reads again as
    /// it redraws: Move to Trash of a RAW+JPEG pair and of a thousand photos, a rename, a hundred
    /// photos (their JPEGs with them) moved to another folder, a drive of 50,000 photos going
    /// offline and coming back, ten photos removed and imported again. Each is reported as the
    /// change (saving it included) + the redraw, in ms; then whether all that was carried on is
    /// what working it out again gives.
    @MainActor
    private static func inPlaceChanges(_ app: AppState, readSidebar: () -> Void) {
        var line: [String] = []
        var redraws = 0.0
        func step(_ label: String, _ change: () -> Void) {
            let start = ContinuousClock.now
            change()
            let changed = milliseconds(since: start)
            var redrawn = 0.0
            rederive(app, readSidebar: readSidebar) { _, body in
                let start = ContinuousClock.now
                body()
                redrawn += milliseconds(since: start)
            }
            redraws += redrawn
            line.append(label + " " + String(format: "%.1f+%.1f", changed, redrawn))
        }
        rederive(app, readSidebar: readSidebar) { $1() }   // all worked out before the first change
        let count = app.assets.count
        /// Live originals the library shows, from a place in the catalog on.
        func shown(from start: Int) -> [Int] {
            let (photos, pairing) = (app.assets, app.assetPairing)
            return (start ..< photos.count).filter {
                pairing.isShown(photos[$0], at: $0) && !photos[$0].isVirtualCopy && photos[$0].localPath != nil
            }
        }

        // a RAW and its JPEG, as Move to Trash takes them together
        let pairing = app.assetPairing
        let raw = shown(from: count / 2).first { pairing.companionsByPrimary[app.assets[$0].id] != nil } ?? count / 2
        let pair = pairing.withCompanions([app.assets[raw].id])
        step("trash 1") { app.applyTrashedOriginals(OriginalTrashReport(trashedIds: pair)) }
        let thousand = app.assetPairing.withCompanions(Set(shown(from: count * 3 / 5).prefix(1_000).map { app.assets[$0].id }))
        step("trash 1000") { app.applyTrashedOriginals(OriginalTrashReport(trashedIds: thousand)) }

        let solo = shown(from: count * 13 / 20).first { app.assetPairing.companionsByPrimary[app.assets[$0].id] == nil }
            ?? count * 13 / 20
        let renamed = app.assets[solo]
        let renamedURL = URL(fileURLWithPath: PathString.directory(of: renamed.localPath ?? "/"))
            .appendingPathComponent("RENAMED_\(solo).\(renamed.type)")
        step("rename 1") { _ = app.applyRenamedOriginals([renamed.id: renamedURL]) }

        // to the folder of a photo far from them
        let destination = URL(fileURLWithPath: PathString.directory(of: app.assets[shown(from: count / 10)[0]].localPath ?? "/"))
        let moving = app.assetPairing.withCompanions(Set(shown(from: count * 7 / 10).prefix(100).map { app.assets[$0].id }))
        var locations: [String: URL] = [:]
        for photo in app.assets where moving.contains(photo.id) {
            locations[photo.id] = destination.appendingPathComponent(photo.filename)
        }
        step("move 100") { _ = app.applyMovedOriginalLocations(locations) }

        // whole source folders' photos, as a drive unplugged takes them, up to 50,000
        var perSource: [String: Int] = [:]
        for photo in app.assets where !photo.deleted && !photo.isDemo { perSource[photo.folderId, default: 0] += 1 }
        var drive = Set<String>(), onDrive = 0
        for (source, number) in perSource.sorted(by: { $0.key < $1.key }) where onDrive < 50_000 {
            drive.insert(source)
            onDrive += number
        }
        let unplugged = app.assets.filter { !$0.deleted && !$0.isDemo && drive.contains($0.folderId) }
        step("offline \(unplugged.count)") {
            app.applyAvailabilityChanges(unplugged.map {
                AssetAvailabilityUpdate(assetId: $0.id, status: .offline, localPath: $0.localPath)
            })
        }
        step("online") {
            app.applyAvailabilityChanges(unplugged.map {
                AssetAvailabilityUpdate(assetId: $0.id, status: .ready, localPath: $0.localPath)
            })
        }

        // as they were before they were removed: the import reads them again
        let returning = shown(from: count * 4 / 5).prefix(10).map { app.assets[$0] }
        step("remove 10") { _ = app.mutate(Set(returning.map(\.id))) { $0.deleted = true } }
        step("revive 10") { app.addImportBatch(returning, revivedIds: Set(returning.map(\.id)), album: nil) }

        let differing = app.cachesDifferingFromRecount()
        report("in place ms (change+redraw): " + line.joined(separator: " · ")
            + " · redraws " + String(format: "%.0f", redraws)
            + (differing.isEmpty ? " · as a recount gives" : " · unlike a recount: " + differing.joined(separator: ", ")))
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }

    /// Stacks worked out again after a structural change, alone: the change, and the pairing they
    /// read, come before the clock starts. Then what a redraw reads of them: the menu's state and
    /// a screenful of tiles' badges. As the catalog is (auto-stacking as the run's settings have
    /// it: `-pc_autoStackSeconds '<real>5</real>'`, as a plain 5 is read as text), then with edited
    /// copies and duplicate groups, every stack folded, the photo list folding them, and after an
    /// import batch, worked out again or carried on. Median of five each.
    @MainActor
    private static func stackParts(_ app: AppState) {
        var parts: [String] = []
        func median(_ label: String, prepare: () -> Void, _ body: () -> Void) {
            var times: [Double] = []
            for _ in 0..<5 {
                prepare()
                let start = ContinuousClock.now
                body()
                let elapsed = ContinuousClock.now - start
                times.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
            }
            parts.append(label + " " + String(format: "%.1f", times.sorted()[times.count / 2]))
        }
        func change() {
            app.assets = app.assets
            _ = app.assetPairing
        }
        let tiles = Array(app.list.prefix(200))
        func read() {
            _ = app.hasStacks
            for tile in tiles { _ = app.stackInfo(for: tile) }
        }
        median("derive", prepare: change, read)
        let plain = app.photoStacks

        addStackSources(app)
        median("+ edits, duplicates", prepare: change, read)
        let stacks = app.photoStacks
        app.setAllStacksCollapsed(true)
        median("folded", prepare: change, read)
        median("fold list", prepare: {
            app.setAllStacksCollapsed(false)
            _ = app.list.count
        }) {
            app.setAllStacksCollapsed(true)
            _ = app.list.count
        }
        median("import batch", prepare: {
            app.appendAssets(importBatch(for: app, count: 32))
            _ = app.assetPairing
        }, read)
        // the same, what stacks are worked out from carried on to the batch (as `appendAssets`
        // is to do, with the earlier photos the pairing hides or shows again found as it does)
        var carry: (start: Int, flipped: [Int]) = (0, [])
        median("import batch, carried", prepare: {
            let (start, before) = (app.assets.count, app.assetPairing)
            app.appendAssets(importBatch(for: app, count: 32))
            let after = app.assetPairing
            carry = (start, (0..<start).filter {
                before.isShown(app.assets[$0], at: $0) != after.isShown(app.assets[$0], at: $0)
            })
        }) {
            app.carryStacks(appendedFrom: carry.start, flipped: carry.flipped)
            read()
        }
        app.setAllStacksCollapsed(false)
        app.duplicateGroupsCache = []
        func photos(_ stacks: [PhotoStack]) -> Int { stacks.reduce(0) { $0 + $1.count } }
        report("stacks ms: " + parts.joined(separator: " · ")
            + " · \(plain.count) stacks of \(photos(plain)) photos, then \(stacks.count) of \(photos(stacks))")
    }

    /// An edited copy of one photo in fifty, and duplicates of two in twenty.
    @MainActor
    private static func addStackSources(_ app: AppState) {
        let shown = app.list
        app.appendAssets(stride(from: 0, to: shown.count, by: 50).compactMap { editedCopy(of: shown[$0]) })
        app.duplicateGroupsCache = stride(from: 1, to: shown.count - 1, by: 20).map {
            DuplicateGroup(id: "scale-dup-\($0)", method: "contentHash", score: 1, items: [shown[$0], shown[$0 + 1]])
        }
    }

    /// The TIFF an external editor would write for `model`, beside it.
    private static func editedCopy(of model: Asset) -> Asset? {
        guard let path = model.localPath else { return nil }
        let file = "\(PathString.splitExtension(path).stem)-Edit.tif"
        return Asset(id: "edit-\(UUID().uuidString)", pid: model.pid, ori: model.ori, thumb: "", preview: "",
                     filename: PathString.lastComponent(file), type: "TIF", isRaw: false, folderId: model.folderId,
                     folderName: model.folderName, date: model.date, width: model.width, height: model.height,
                     orientation: 1, camera: model.camera, lens: model.lens, focal: model.focal,
                     aperture: model.aperture, shutter: model.shutter, iso: model.iso, colorSpace: "Adobe RGB",
                     hasICCProfile: true, fileMB: model.fileMB * 4, rating: 0, flag: .none, keywords: model.keywords,
                     title: "", caption: "", location: "", gps: (0, 0), status: .ready, importedAt: Date(),
                     localPath: file, isDemo: false)
    }

    /// New photos beside some already in the catalog: a quarter the JPEGs of RAWs shot without
    /// one, a quarter the RAWs of JPEGs shot alone, the rest photos of their own in the same folder.
    @MainActor
    private static func importBatch(for app: AppState, count: Int) -> [Asset] {
        let pairing = app.assetPairing
        var raws: [Asset] = [], jpegs: [Asset] = []
        for asset in app.assets.reversed() where !asset.deleted && !asset.isVirtualCopy && asset.localPath != nil {
            if asset.isRaw, pairing.companionsByPrimary[asset.id] == nil, raws.count < count / 4 {
                raws.append(asset)
            } else if !asset.isRaw, pairing.shows(asset), jpegs.count < count / 4 {
                jpegs.append(asset)
            }
            if raws.count == count / 4, jpegs.count == count / 4 { break }
        }
        func twin(of model: Asset, ext: String, name: String? = nil) -> Asset {
            let path = model.localPath ?? ""
            let file = name.map { "\(PathString.directory(of: path))/\($0).\(ext)" } ?? "\(PathString.splitExtension(path).stem).\(ext)"
            return Asset(id: "import-\(UUID().uuidString)", pid: model.pid, ori: model.ori, thumb: "",
                         preview: "", filename: PathString.lastComponent(file), type: ext, isRaw: ext == "CR3",
                         folderId: model.folderId, folderName: model.folderName, date: model.date, width: model.width,
                         height: model.height, orientation: 1, camera: model.camera, lens: model.lens, focal: model.focal,
                         aperture: model.aperture, shutter: model.shutter, iso: model.iso, colorSpace: model.colorSpace,
                         hasICCProfile: true, fileMB: model.fileMB, rating: 0, flag: .none,
                         keywords: name == nil ? model.keywords : model.keywords + ["导入批次"], title: "", caption: "",
                         location: "", gps: (0, 0), status: .ready, importedAt: Date(), localPath: file, isDemo: false)
        }
        var batch = raws.map { twin(of: $0, ext: "JPG") } + jpegs.map { twin(of: $0, ext: "CR3") }
        while batch.count < count, let model = jpegs.first ?? raws.first {
            batch.append(twin(of: model, ext: "JPG", name: "IMPORT_\(batch.count)"))
        }
        return batch
    }

    /// Smart albums by rating, keyword, capture date and camera, matched against every photo.
    private static let sidebarSmartAlbums: [SmartAlbum] = {
        func album(_ id: String, _ match: String, _ conditions: [(String, String, String)]) -> SmartAlbum {
            SmartAlbum(id: "scale-smart-\(id)", name: id,
                       rule: SmartRule(match: match, conditions: conditions.map {
                           SmartCondition(field: $0.0, op: $0.1, value: $0.2)
                       }), count: 0)
        }
        return [
            album("rated", "all", [("rating", ">=", "4")]),
            album("travel", "all", [("keywords", "包含", "旅行")]),
            album("picks-2023", "all", [("captureYear", "=", "2023"), ("flag", "=", "pick")]),
            album("recent", "any", [("datePreset", "=", "thisYear"), ("captureDate", ">=", "2025-06-01")]),
            album("canon-portraits", "all", [("camera", "包含", "Canon"), ("keywords", "包含", "人像"),
                                             ("rating", ">=", "3")]),
        ]
    }()

    /// A smart album saved from a search: its 全文搜索 condition looks through every photo's text.
    private static let searchSmartAlbum = SmartAlbum(
        id: "scale-smart-search", name: "search",
        rule: SmartRule(match: "all", conditions: [SmartCondition(field: "search", op: "包含", value: "IMG_12")]),
        count: 0)

    // ---- synthetic catalog ----

    /// Deterministic generator (SplitMix64) so every run measures the same catalog.
    private struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
        mutating func chance(_ p: Double) -> Bool { Double(next() % 10_000) < p * 10_000 }
    }

    private static let cameras = ["Canon EOS R5", "Canon EOS R6m2", "SONY ILCE-7M4", "NIKON Z 6_2", "FUJIFILM X-T4",
                                  "iPhone 15 Pro", "Canon EOS 5D Mark IV", "SONY ILCE-7RM5"]
    private static let lenses = ["RF24-70mm F2.8 L IS USM", "RF50mm F1.2 L USM", "RF85mm F1.2 L USM", "FE 24-70mm F2.8 GM II",
                                 "FE 35mm F1.4 GM", "NIKKOR Z 24-70mm f/4 S", "XF23mmF1.4 R", "iPhone 15 Pro back camera",
                                 "EF70-200mm f/2.8L IS III USM", "FE 90mm F2.8 Macro G OSS", "RF15-35mm F2.8 L IS USM",
                                 "XF56mmF1.2 R"]
    private static let keywordPool: [String] = {
        let roots = ["旅行", "人像", "家庭", "风光", "街拍", "建筑", "美食", "宠物", "婚礼", "活动"]
        var pool: [String] = []
        for root in roots {
            pool.append(root)
            for child in 0..<29 { pool.append("\(root)/主题\(child)") }
        }
        return pool
    }()

    private static func hex(_ random: inout Random, words: Int) -> String {
        (0..<words).map { _ in String(format: "%016llx", random.next()) }.joined()
    }

    private static func generate(_ count: Int, from offset: Int, into store: CatalogStore) {
        var random = Random(state: UInt64(offset) &+ 42)
        let package = store.packageURL.path
        let start = Date(timeIntervalSince1970: 1_451_606_400)   // 2016-01-01
        let span = 10 * 365 * 86_400.0
        var batch: [Asset] = []
        batch.reserveCapacity(5_000)
        var index = offset
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        day.timeZone = .captureWallClock
        func flush() {
            try? store.upsert(batch)
            batch.removeAll(keepingCapacity: true)
            if index % 50_000 < 5_000 { report("  … \(index)") }
        }
        while index < offset + count {
            let date = start.addingTimeInterval(Double(random.next() % UInt64(span)))
            let root = random.int(40)
            let camera = cameras[random.int(cameras.count)]
            let lens = lenses[random.int(lenses.count)]
            let folder = "/Volumes/ScaleBench/Root\(root)/\(day.string(from: date).prefix(4))/\(day.string(from: date))"
            let number = 10_000 + index
            // one in five RAWs is shot RAW+JPEG
            let variants = random.chance(0.2) ? ["CR3", "JPG"] : [random.chance(0.7) ? "CR3" : "JPG"]
            let keywordCount = random.chance(0.4) ? 0 : 1 + random.int(4)
            let keywords = KeywordService.normalize((0..<keywordCount).map { _ in keywordPool[random.int(keywordPool.count)] })
            let rating = random.chance(0.7) ? 0 : 1 + random.int(5)
            let flag: Flag = random.chance(0.05) ? .pick : random.chance(0.03) ? .reject : .none
            let gps: (Double, Double) = random.chance(0.2) ? (20 + Double(random.int(2000)) / 100, 100 + Double(random.int(3000)) / 100) : (0, 0)
            for ext in variants where index < offset + count {
                let path = "\(folder)/IMG_\(number).\(ext)"
                let id = "r" + String(format: "%016llx", random.next())
                let shard = "\(id.dropFirst().prefix(2))/\(id.dropFirst(3).prefix(2))"
                var asset = Asset(
                    id: id, pid: index % 100_000, ori: random.chance(0.7) ? "l" : "p",
                    thumb: "\(package)/Cache/Thumbnails/512/\(shard)/\(id).jpg",
                    preview: "\(package)/Cache/Previews/2048/\(shard)/\(id).jpg",
                    filename: "IMG_\(number).\(ext)", type: ext, isRaw: ext == "CR3",
                    folderId: "src-scale-\(root)", folderName: "Root \(root)",
                    date: date, width: 6000, height: 4000, orientation: 1,
                    camera: camera, lens: lens, focal: 24 + random.int(176), aperture: 1.2 + Double(random.int(100)) / 10,
                    shutter: "1/\(60 << random.int(6))", iso: 100 << random.int(6), colorSpace: "sRGB",
                    hasICCProfile: true,
                    fileMB: ext == "CR3" ? 20 + Double(random.int(1500)) / 100 : 3 + Double(random.int(500)) / 100,
                    fileModifiedAt: date, fileCreatedAt: date,
                    rating: rating, flag: flag, colorLabel: random.chance(0.05) ? .red : nil,
                    keywords: keywords, title: "", caption: "",
                    author: "", copyright: "",
                    makerNotes: "MakerCanon: ColorSpace=1, FirmwareVersion=Firmware Version 1.5.0, ImageType=\(camera), LensModel=\(lens), ModelID=\(2_147_484_000 + random.int(999)), OwnerName=",
                    location: Asset.locationLabel(gps.0 == 0 ? nil : gps), gps: gps, gpsAltitude: nil,
                    status: .ready, importedAt: date.addingTimeInterval(86_400), deleted: false,
                    localPath: path, captureDateSource: "EXIF · DateTimeOriginal",
                    contentHash: hex(&random, words: 4), quickHash: hex(&random, words: 4), isDemo: false)
                asset.perceptualHash = random.next()
                batch.append(asset)
                index += 1
                if batch.count >= 5_000 { flush() }
            }
        }
        if !batch.isEmpty { flush() }
    }

    // ---- measurement ----

    private static func timed<T>(_ body: () -> T) -> (T, Int) {
        let start = ContinuousClock.now
        let value = body()
        let elapsed = ContinuousClock.now - start
        return (value, Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000))
    }

    private static func seconds(since start: ContinuousClock.Instant) -> String {
        let elapsed = ContinuousClock.now - start
        return String(format: "%.1f", Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
    }

    private static func report(_ text: String) {
        FileHandle.standardError.write(Data("[scale] \(text)\n".utf8))
    }

    private static func megabytes(_ bytes: UInt64) -> Int { Int(bytes / 1_048_576) }

    /// Signed change in megabytes ("+950"), as memory can also shrink between samples.
    private static func delta(_ after: UInt64, _ before: UInt64) -> String {
        let change = (Int64(after) - Int64(before)) / 1_048_576
        return change >= 0 ? "+\(change)" : "\(change)"
    }

    private static func fileSize(_ package: URL) -> UInt64 {
        let db = package.appendingPathComponent("catalog.sqlite").path
        return ((try? FileManager.default.attributesOfItem(atPath: db))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
