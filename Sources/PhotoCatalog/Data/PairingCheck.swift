import Foundation

/// RAW+JPEG pairs present as one photo and edit as one.
enum PairingCheck {
    static func run() {
        MainActor.assumeIsolated { checkPresentationAndEdits() }
        checkRenameKeepsPairs()
        print("--- RAW+JPEG pairing assertions passed ---")
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

        app.setPrimary(raw.id)
        _ = app.handleKey("4", hasCommand: false)
        let rated = Dictionary(uniqueKeysWithValues: app.assets.map { ($0.id, $0.rating) })
        assert(rated[raw.id] == 4 && rated[jpeg.id] == 4 && rated[solo.id] == 0,
               "rating the tile writes both files of the pair")
        assert(app.libraryCounts.unrated == 3, "counts follow the photo, not its files")

        app.addKeyword("pairing")
        assert(app.assets.filter { $0.keywords.contains("pairing") }.map(\.id).sorted()
               == [raw.id, jpeg.id].sorted(), "keywords reach the companion")

        app.pairRawAndJpeg = false
        assert(app.list.count == 5 && app.libraryCounts.all == 5, "turning pairing off lists every file")
        app.pairRawAndJpeg = true
        assert(app.list.count == 4, "turning it back on folds the JPEG again")

        app.setPrimary(raw.id)
        app.removeSelected()
        assert(!app.assets.contains { !$0.deleted && ($0.id == raw.id || $0.id == jpeg.id) }
               && app.assets.contains { !$0.deleted && $0.id == solo.id },
               "removing the photo removes both of its files")
    }

    private static func checkRenameKeepsPairs() {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pc-pair-rename-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["A.CR3", "A.JPG", "Shoot_0001.JPG"] {
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
    }
}
