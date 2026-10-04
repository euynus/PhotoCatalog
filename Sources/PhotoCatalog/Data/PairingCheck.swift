import Foundation

/// RAW+JPEG pairs present as one photo and edit as one.
enum PairingCheck {
    static func run() {
        checkPathStrings()
        MainActor.assumeIsolated {
            checkPresentationAndEdits()
            checkSelectionSummary()
            checkEditedVersions()
        }
        checkRenameKeepsPairs()
        print("--- RAW+JPEG pairing assertions passed ---")
    }

    /// The string path helpers used in catalog-wide loops agree with URL, without its disk access.
    private static func checkPathStrings() {
        for path in ["/Volumes/Photos/2024/2024-05-01/IMG_0001.CR3", "/a/b/c.tar.gz", "/a/.hidden", "/a/b/noext",
                     "/c.jpg", "/a/b/c.JPG", "/Volumes/SOLIDIGM /Photos/x y.jpg"] {
            let url = URL(fileURLWithPath: path, isDirectory: false)
            let (stem, ext) = PathString.splitExtension(path)
            assert(String(ext) == url.pathExtension && String(stem) == url.deletingPathExtension().path,
                   "splitExtension agrees with URL for \(path)")
            assert(PathString.directory(of: path) == url.deletingLastPathComponent().path
                   && PathString.lastComponent(path) == url.lastPathComponent, "directory and name agree for \(path)")
        }
        assert(PathString.standardized("/a//b/./c/../d/") == "/a/b/d" && PathString.standardized("/a/b") == "/a/b",
               "standardized resolves dot segments and keeps clean paths")
        assert(PathString.standardized("/private/var/folders/x/T/a") == "/var/folders/x/T/a"
               && PathString.standardized("/private/tmp") == "/tmp"
               && PathString.standardized("/Volumes/Photos/2024/") == "/Volumes/Photos/2024",
               "firmlinked /private paths compare equal to their short form")

        let names = ["img_10.jpg", "IMG_9.JPG", "IMG_0009b.jpg", "a.jpg", "a1.jpg", "aa.jpg", "_x.jpg",
                     "20240309_0005.JPG", "20240309_0004.JPG", "Z.jpg", "b.jpg", "IMG_0100.CR3"]
        let sorted = names.sorted { FileNameSortKey($0) < FileNameSortKey($1) }
        assert(sorted == ["_x.jpg", "20240309_0004.JPG", "20240309_0005.JPG", "a.jpg", "a1.jpg", "aa.jpg", "b.jpg",
                          "IMG_9.JPG", "IMG_0009b.jpg", "img_10.jpg", "IMG_0100.CR3", "Z.jpg"],
               "file names sort like the Finder: numbers by value, case ignored")
    }

    @MainActor
    private static func checkPresentationAndEdits() {
        let raws = DemoData.assets.filter(\.isRaw)
        let jpegs = DemoData.assets.filter { !$0.isRaw }
        func asset(_ base: Asset, _ path: String) -> Asset {
            var copy = base
            copy.localPath = path
            copy.filename = URL(fileURLWithPath: path).lastPathComponent
            copy.rating = 0
            copy.flag = .none
            copy.keywords = []
            copy.date = CaptureDates.interval(for: "2024-02-29")!.start
            return copy
        }
        let raw = asset(raws[0], "/tmp/pc-pairing/IMG_0001.CR3")
        let jpeg = asset(jpegs[0], "/tmp/pc-pairing/img_0001.jpg")
        let solo = asset(raws[1], "/tmp/pc-pairing/IMG_0002.CR3")
        let twinRaw = asset(raws[2], "/tmp/pc-pairing/IMG_0003.CR3")
        let twinOther = asset(raws[3], "/tmp/pc-pairing/IMG_0003.NEF")

        let app = AppState.selfCheckFixture()
        app.pairRawAndJpeg = true
        app.assets = [raw, jpeg, solo, twinRaw, twinOther]
        app.duplicateGroupsCache = []
        app.select(Selection(type: .lib, id: "all", name: "Pairing check"))

        assert(Set(app.list.map(\.id)) == [raw.id, solo.id, twinRaw.id, twinOther.id]
               && app.libraryCounts.all == 4,
               "a RAW and its same-name JPEG are one tile and one photo; two RAWs never pair")
        assert(app.companions(of: raw).map(\.id) == [jpeg.id], "the RAW owns its JPEG companion")
        let datePin = PinnedSidebarItem(type: .captureDate, selectionId: "2024-02-29", name: "Pairing day")
        assert(app.countForPinnedSidebarItem(datePin) == "4",
               "pinned date badges count a RAW/JPEG pair once, matching the date tree and visible photos")

        // the bundle derived on the loading thread matches what the getters compute
        let derived = AppState.CatalogDerivedData.derive(from: app.assets, pairsRawJpeg: true,
                                                         recentCutoff: app.recentCutoff)
        assert(derived.pairing.primaryByCompanion == app.assetPairing.primaryByCompanion
               && derived.libraryCounts == app.libraryCounts
               && derived.projects == app.projectList && derived.clients == app.clientList
               && derived.captureDateGroups.map { "\($0.id)=\($0.count)" } == app.captureDateGroups.map { "\($0.id)=\($0.count)" }
               && derived.indexById.count == app.assets.count,
               "background-derived catalog data equals the lazily computed caches")

        app.setPrimary(raw.id)
        _ = app.handleKey("4", hasCommand: false)
        let rated = Dictionary(uniqueKeysWithValues: app.assets.map { ($0.id, $0.rating) })
        assert(rated[raw.id] == 4 && rated[jpeg.id] == 4 && rated[solo.id] == 0,
               "rating the tile writes both files of the pair")
        assert(app.libraryCounts.unrated == 3, "counts follow the photo, not its files")

        let undo = UndoManager()
        undo.groupsByEvent = false
        app.undoManager = undo
        undo.beginUndoGrouping()
        _ = app.handleKey("2", hasCommand: false)
        undo.endUndoGrouping()
        undo.undo()
        assert(app.assets.filter { [raw.id, jpeg.id].contains($0.id) }.allSatisfy { $0.rating == 4 },
               "undoing a paired rating restores both files")
        app.undoManager = nil

        app.addKeyword("pairing")
        assert(app.assets.filter { $0.keywords.contains("pairing") }.map(\.id).sorted()
               == [raw.id, jpeg.id].sorted(), "keywords reach the companion")

        app.pairRawAndJpeg = false
        assert(app.list.count == 5 && app.libraryCounts.all == 5, "turning pairing off lists every file")
        assert(app.countForPinnedSidebarItem(datePin) == "5", "pinned date badges refresh when pairing is disabled")
        app.pairRawAndJpeg = true
        assert(app.list.count == 4, "turning it back on folds the JPEG again")
        assert(app.countForPinnedSidebarItem(datePin) == "4", "pinned date badges refresh when pairing is enabled")

        app.setPrimary(raw.id)
        app.removeSelected()
        assert(!app.assets.contains { !$0.deleted && ($0.id == raw.id || $0.id == jpeg.id) }
               && app.assets.contains { !$0.deleted && $0.id == solo.id },
               "removing the photo removes both of its files")
    }

    /// A TIFF made for an external editor stacks with its original by name, in either language.
    @MainActor
    private static func checkEditedVersions() {
        for (stem, original) in [("IMG_1-编辑", "IMG_1"), ("IMG_1-Edit", "IMG_1"), ("IMG_1-编辑-2", "IMG_1"),
                                 ("IMG_1-Edit (2)", "IMG_1"), ("my-edit-trip-Edit", "my-edit-trip")] {
            assert(EditedVersions.originalStem(of: stem) == original, "\(stem) is an edited copy of \(original)")
        }
        assert(["IMG_1", "IMG_1-edited", "Edit", "IMG-Editor"].allSatisfy { EditedVersions.originalStem(of: $0) == nil },
               "other names aren't edited copies")
        let raws = DemoData.assets.filter(\.isRaw)
        let jpegs = DemoData.assets.filter { !$0.isRaw }
        func real(_ base: Asset, _ path: String) -> Asset {
            Asset(id: base.id, pid: base.pid, ori: base.ori, thumb: base.thumb, preview: base.preview,
                  filename: PathString.lastComponent(path), type: base.type, isRaw: base.isRaw,
                  folderId: base.folderId, folderName: base.folderName, date: base.date,
                  width: base.width, height: base.height, orientation: base.orientation,
                  camera: base.camera, lens: base.lens, focal: base.focal, aperture: base.aperture,
                  shutter: base.shutter, iso: base.iso, colorSpace: base.colorSpace, fileMB: base.fileMB,
                  rating: 0, flag: .none, keywords: [], title: "", caption: "", location: "", gps: base.gps,
                  status: .ready, importedAt: base.importedAt, localPath: path, isDemo: false)
        }
        let raw = real(raws[0], "/tmp/pc-edit/IMG_1.CR3")
        let jpeg = real(jpegs[0], "/tmp/pc-edit/IMG_1.jpg")
        let edit = real(jpegs[1], "/tmp/pc-edit/IMG_1-编辑.tif")
        let second = real(jpegs[2], "/tmp/pc-edit/IMG_1-Edit-2.tif")
        let alone = real(raws[1], "/tmp/pc-edit/IMG_2.CR3")
        let elsewhere = real(jpegs[3], "/tmp/pc-other/IMG_2-编辑.tif")
        let assets = [raw, jpeg, edit, second, alone, elsewhere]
        let groups = EditedVersions.groups(assets)
        assert(groups.count == 1 && groups[0].items.map(\.id) == [raw.id, edit.id, second.id],
               "edited copies stack with the RAW they were made from, and only in its folder")
        let app = AppState.selfCheckFixture()
        app.assets = assets
        assert(app.stackInfo(for: edit)?.count == 3 && app.stackInfo(for: alone) == nil,
               "the library shows an original and its edited copies as one stack")
    }

    /// Menu states come from one cached, early-exiting pass over the selection; they must agree
    /// with a plain scan through selection, edit, catalog, pairing and view changes.
    @MainActor
    private static func checkSelectionSummary() {
        let raws = DemoData.assets.filter(\.isRaw)
        let jpegs = DemoData.assets.filter { !$0.isRaw }
        func real(_ base: Asset, _ path: String, status: AssetStatus = .ready, preview: String? = nil) -> Asset {
            Asset(id: base.id, pid: base.pid, ori: base.ori, thumb: base.thumb, preview: preview ?? base.preview,
                  filename: PathString.lastComponent(path), type: base.type, isRaw: base.isRaw,
                  folderId: base.folderId, folderName: base.folderName, date: base.date,
                  width: base.width, height: base.height, orientation: base.orientation,
                  camera: base.camera, lens: base.lens, focal: base.focal, aperture: base.aperture,
                  shutter: base.shutter, iso: base.iso, colorSpace: base.colorSpace,
                  hasICCProfile: base.hasICCProfile, fileMB: base.fileMB,
                  fileModifiedAt: base.fileModifiedAt, fileCreatedAt: base.fileCreatedAt,
                  rating: 0, flag: .none, colorLabel: nil, keywords: [], title: "", caption: "",
                  author: "", copyright: "", makerNotes: "", project: "", client: "", location: "",
                  gps: base.gps, gpsAltitude: nil, status: status, importedAt: base.importedAt,
                  deleted: false, localPath: path, captureDateSource: base.captureDateSource,
                  contentHash: nil, quickHash: nil, isDemo: false, faces: 0, perceptualHash: nil)
        }
        let offlineRaw = real(raws[0], "/tmp/pc-summary/IMG_0001.CR3", status: .offline)
        let companion = real(jpegs[0], "/tmp/pc-summary/IMG_0001.jpg")
        let solo = real(raws[1], "/tmp/pc-summary/IMG_0002.CR3")
        let previewOnly = real(raws[2], "/tmp/pc-summary/IMG_0003.CR3", status: .missing,
                               preview: "/tmp/pc-summary/cache/IMG_0003.jpg")
        let demo = jpegs[1]   // a demo photo: remote preview, no original

        let app = AppState.selfCheckFixture()
        app.pairRawAndJpeg = true
        app.assets = [offlineRaw, companion, solo, previewOnly, demo]
        app.duplicateGroupsCache = []
        app.select(Selection(type: .lib, id: "all", name: "Summary check"))

        func expected() -> AppState.SelectionSummary {
            let byId = Dictionary(app.assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let ids = !app.selectedIds.isEmpty ? app.selectedIds : Set(app.primaryId.map { [$0] } ?? [])
            let live = ids.compactMap { byId[$0] }.filter { !$0.deleted }
            func local(_ a: Asset) -> Bool { !a.deleted && !a.isDemo && a.status == .ready && a.localPath != nil }
            func localReference(_ path: String) -> Bool { !path.isEmpty && !path.hasPrefix("http") }
            var summary = AppState.SelectionSummary()
            summary.hasLive = !live.isEmpty
            summary.hasPrimaryOriginal = live.contains(where: local)
            summary.hasLocalOriginal = live.contains { local($0) || app.companions(of: $0).contains(where: local) }
            summary.hasPreviewReference = live.contains {
                !$0.isDemo && (local($0) || localReference($0.preview) || localReference($0.thumb))
            }
            let developable = (app.view == .develop ? app.primaryId.flatMap { byId[$0] }.map { [$0] } ?? [] : live)
                .filter { !$0.deleted && app.canDevelop($0) }
            summary.hasDevelopable = !developable.isEmpty
            summary.hasDevelopEdit = developable.contains { app.developSettings[$0.id] != nil }
            return summary
        }
        let selections: [(selected: Set<String>, primary: String?)] = [
            ([], nil), ([], solo.id), ([offlineRaw.id], offlineRaw.id), ([previewOnly.id], previewOnly.id),
            ([demo.id], demo.id), ([offlineRaw.id, previewOnly.id, demo.id], demo.id),
            ([offlineRaw.id, solo.id, demo.id], offlineRaw.id),
            ([offlineRaw.id, solo.id, previewOnly.id, demo.id], solo.id),
        ]
        func checkAll(_ situation: String) {
            for (selected, primary) in selections {
                app.selectedIds = selected
                app.primaryId = primary
                assert(app.selectionSummary == expected(), "selection summary matches a full scan \(situation)")
            }
        }
        checkAll("as imported")
        app.selectedIds = [offlineRaw.id]
        app.primaryId = offlineRaw.id
        let offline = app.selectionSummary
        assert(offline.hasLocalOriginal && !offline.hasPrimaryOriginal && demo.isDemo && demo.localPath == nil,
               "an offline RAW still reaches its local JPEG, but has no original of its own to render")

        var edit = DevelopSettings()
        edit.exposure = 0.5
        app.commitDevelop([previewOnly.id: edit], undoName: "check")
        checkAll("with one edit")
        app.commitDevelop([solo.id: edit, offlineRaw.id: edit, demo.id: edit], undoName: "check")
        checkAll("with more edits than selected photos")

        app.selectedIds = [offlineRaw.id, solo.id, previewOnly.id, demo.id]
        app.primaryId = demo.id
        app.view = .develop
        assert(app.selectionSummary == expected() && !app.selectionSummary.hasDevelopable,
               "in Develop only the photo on screen decides develop commands")
        app.primaryId = solo.id
        assert(app.selectionSummary == expected() && app.selectionSummary.hasDevelopEdit,
               "Develop follows the photo on screen")
        app.view = .grid

        if let index = app.assets.firstIndex(where: { $0.id == solo.id }) { app.assets[index].status = .offline }
        checkAll("after a photo goes offline")
        app.pairRawAndJpeg = false
        checkAll("with pairing off")
    }

    private static func checkRenameKeepsPairs() {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pc-pair-rename-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["A.CR3", "A.JPG", "A.xmp", "Shoot_0001.JPG", "C.CR3", "Other_0001.tif"] {
            fm.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data(name.utf8))
        }
        var raw = DemoData.assets.first(where: \.isRaw)!
        raw.localPath = dir.appendingPathComponent("A.CR3").path
        var jpeg = DemoData.assets.first { !$0.isRaw }!
        jpeg.localPath = dir.appendingPathComponent("A.JPG").path

        // Shoot_0001 is free for the RAW but taken for its JPEG, so both move to _1.
        let map = RenameService.renameWithTemplate([raw], template: "Shoot_{seq}", companions: [raw.id: [jpeg]])
        assert(map[raw.id]?.lastPathComponent == "Shoot_0001_1.CR3"
               && map[jpeg.id]?.lastPathComponent == "Shoot_0001_1.JPG"
               && fm.fileExists(atPath: dir.appendingPathComponent("Shoot_0001.JPG").path),
               "batch rename moves a RAW and its JPEG to one free base name")
        assert(fm.fileExists(atPath: dir.appendingPathComponent("Shoot_0001_1.xmp").path)
               && !fm.fileExists(atPath: dir.appendingPathComponent("A.xmp").path),
               "the pair's sidecar is renamed with it")

        // a name another file has, in any extension, is taken: C.CR3 beside Other_0001.tif
        // would otherwise pair with it
        var solo = DemoData.assets.filter(\.isRaw)[1]
        solo.localPath = dir.appendingPathComponent("C.CR3").path
        let preview = RenameService.plan([solo], template: "Other_{seq}", folders: RenameService.FolderNames(for: [solo]))
        assert(preview.taken == 1, "the preview warns of a name already used in the folder")
        let soloMap = RenameService.renameWithTemplate([solo], template: "Other_{seq}")
        assert(soloMap[solo.id]?.lastPathComponent == "Other_0001_1.CR3", "a stem used by another file is skipped")
        let kept = RenameService.renameWithTemplate([solo].map { var a = $0; a.localPath = soloMap[solo.id]?.path; return a },
                                                    template: "{original}")
        assert(kept[solo.id]?.lastPathComponent == "Other_0001_1.CR3", "a photo can keep its own name")

        // moving an original takes its sidecar along, and putting it back brings it back
        fm.createFile(atPath: dir.appendingPathComponent("Other_0001_1.xmp").path, contents: Data("xmp".utf8))
        var moving = solo
        moving.localPath = soloMap[solo.id]?.path
        let elsewhere = dir.appendingPathComponent("elsewhere")
        let report = OriginalFileOperationService.perform(.move, assets: [moving], destination: elsewhere)
        assert(report.moved == 1 && fm.fileExists(atPath: elsewhere.appendingPathComponent("Other_0001_1.xmp").path)
               && !fm.fileExists(atPath: dir.appendingPathComponent("Other_0001_1.xmp").path),
               "moving an original moves its sidecar")
        _ = OriginalFileOperationService.rollBackMoves(report.updatedLocations, originals: [moving])
        assert(fm.fileExists(atPath: dir.appendingPathComponent("Other_0001_1.xmp").path),
               "rolling a move back brings the sidecar back")
    }
}
