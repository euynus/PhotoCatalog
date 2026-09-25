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
        app.select(Selection(type: .lib, id: "all", name: "全部照片"))
        step("back to all") { _ = app.list.count }
        report("list ms: " + line.joined(separator: " · "))

        line = []
        step("library") { _ = app.libraryCounts }
        step("keywords") { _ = app.keywordList.count }
        step("dates") { _ = app.captureDateGroups.count }
        step("folders") { _ = app.folderTree.count }
        report("counts ms: " + line.joined(separator: " · "))

        line = []
        let ids = app.list.prefix(1000).map(\.id)
        step("select") { if let id = ids.first { app.setPrimary(id) } }
        step("rate 1") { _ = app.handleKey("3", hasCommand: false) }
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
        report("edits ms: " + line.joined(separator: " · "))
        report("footprint \(delta(footprint(), baseline)) MB since start, \(megabytes(footprint())) MB total")
        return 0
    }

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
