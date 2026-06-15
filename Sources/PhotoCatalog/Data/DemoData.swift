// ============================================================
//  PhotoCatalog Mac — demo dataset
//  Faithful port of app/data.jsx. The RNG call sequence is preserved
//  exactly so the deterministic distribution (ratings / flags / folders /
//  smart-album counts) matches the design mock.
// ============================================================
import Foundation

/// Linear-congruential RNG — mirrors `rng(seed)` in data.jsx.
final class SeededRNG {
    private var s: Int
    init(seed: Int) { s = seed * 9301 + 49297 }
    func next() -> Double {
        s = (s * 9301 + 49297) % 233280
        return Double(s) / 233280.0
    }
    /// `Math.floor(next() * n)`
    func int(_ n: Int) -> Int { Int(next() * Double(n)) }
}

private struct Rig { let make, model, lens, type: String }

enum DemoData {
    // ---- pools (verbatim from data.jsx) ----
    private static let rigs: [Rig] = [
        Rig(make: "Sony", model: "α7 IV", lens: "FE 24-70mm F2.8 GM", type: "ARW"),
        Rig(make: "Canon", model: "EOS R5", lens: "RF 50mm F1.2 L USM", type: "CR3"),
        Rig(make: "Nikon", model: "Z 6II", lens: "NIKKOR Z 24-120 F4 S", type: "NEF"),
        Rig(make: "FUJIFILM", model: "X-T5", lens: "XF 35mmF1.4 R", type: "RAF"),
        Rig(make: "Leica", model: "Q2", lens: "Summilux 28mm f/1.7", type: "DNG"),
        Rig(make: "Apple", model: "iPhone 15 Pro", lens: "Main Camera 24mm f/1.78", type: "HEIC"),
    ]
    private static let prefix: [String: String] =
        ["ARW": "DSC", "CR3": "IMG", "NEF": "DSC", "RAF": "DSCF", "DNG": "L1", "HEIC": "IMG"]
    static let keywordPool = ["旅行", "城市", "风光", "人像", "街拍", "建筑", "海岸", "山脉", "日落", "夜景", "森林", "京都"]

    static let folders: [Folder] = [
        Folder(id: "fld-tokyo", name: "2026 东京之旅"),
        Folder(id: "fld-iceland", name: "2025 冰岛环岛"),
        Folder(id: "fld-street", name: "城市街拍"),
    ]

    private static let shots: [(String, String)] = [
        ("1506744038136-46273834b3fb", "l"), ("1469474968028-56623f02e42e", "l"), ("1470071459604-3b5ec3a7fe05", "l"),
        ("1447752875215-b2761acb3c5d", "l"), ("1441974231531-c6227db76b6e", "l"), ("1501785888041-af3ef285b470", "l"),
        ("1518837695005-2083093ee35b", "p"), ("1505765050516-f72dcac9c60e", "l"), ("1439066615861-d1af74d74000", "l"),
        ("1426604966848-d7adac402bff", "l"), ("1444464666168-49d633b86797", "l"), ("1454496522488-7a8e488e8606", "p"),
        ("1432405972618-c60b0225b8f9", "l"), ("1433086966358-54859d0ed716", "l"), ("1490750967868-88aa4486c946", "l"),
        ("1500534623283-312aade485b7", "p"), ("1418985991508-e47386d96a71", "l"), ("1444703686981-a3abbc4d4fe3", "l"),
        ("1454942901704-3c44c11b2ad1", "p"), ("1465146344425-f00d5f5c8f07", "l"), ("1472214103451-9374bd1c798e", "l"),
        ("1418065460487-3e41a6c84dc5", "l"), ("1469854523086-cc02fe5d8800", "p"), ("1473773508845-188df298d2d1", "l"),
        ("1485470733090-0aae1788d5af", "l"), ("1487730116645-74489c95b41b", "p"), ("1492011221367-f47e3ccd77a0", "l"),
        ("1493246507139-91e8fad9978e", "l"), ("1500964757637-c85e8a162699", "p"), ("1502082553048-f009c37129b9", "l"),
        ("1504198266287-1659872e6590", "l"), ("1510784722466-f2aa9c52fff6", "l"), ("1511497584788-876760111969", "l"),
        ("1513836279014-a89f7a76ae86", "p"), ("1518173946687-a4c8892bbd9f", "l"), ("1519681393784-d120267933ba", "l"),
        ("1520962880247-cfaf541c8724", "p"), ("1523712999610-f77fbcfc3843", "l"), ("1524429656589-6633a470097c", "l"),
        ("1526772662000-3f88f10405ff", "p"), ("1542273917363-3b1817f69a2d", "l"), ("1546587348-d12660c30c50", "l"),
        ("1551632811-561732d1e306", "l"), ("1558979158-65a1eaa08691", "l"),
    ]

    // ---- helpers ----
    private static func hashId(_ s: String) -> Int {
        var h: UInt32 = 0
        for u in s.utf16 { h = h &* 31 &+ UInt32(u) }
        return Int(h % 100000)
    }
    private static func imgURL(_ uid: String, _ w: Int, _ h: Int) -> String {
        "https://images.unsplash.com/photo-\(uid)?w=\(w)&h=\(h)&q=72&auto=format&fit=crop"
    }
    private static func iso(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s) ?? Date(timeIntervalSince1970: 0)
    }
    private static func pad(_ n: Int) -> String { String(format: "%04d", n) }

    // ---- build ----
    static let assets: [Asset] = buildAssets()
    static let duplicateGroups: [DuplicateGroup] = buildDuplicateGroups(assets)

    private static func buildAssets() -> [Asset] {
        var result: [Asset] = []
        let baseTokyo = iso("2026-06-08T09:14:00+09:00").timeIntervalSince1970
        let baseIce = iso("2025-09-22T16:40:00+00:00").timeIntervalSince1970
        let baseStreet = iso("2026-05-03T18:05:00+08:00").timeIntervalSince1970
        let baseImport = iso("2026-06-12T20:00:00+08:00").timeIntervalSince1970

        let focals = [24, 28, 35, 50, 70, 85, 120]
        let apertures = [1.4, 1.8, 2.0, 2.8, 4.0, 5.6]
        let shutters = ["1/2000", "1/1000", "1/500", "1/250", "1/125", "1/60", "1/30"]
        let isos = [100, 200, 400, 640, 800, 1600, 3200]

        for (i, shot) in shots.enumerated() {
            let (uid, ori) = shot
            let seed = hashId(uid)
            let r = SeededRNG(seed: seed + i * 7)
            let rig = rigs[r.int(rigs.count)]                       // (A)

            let folder: Folder
            let base: TimeInterval
            let locName: String
            let gps: (Double, Double)
            let bucket = i % 10
            if bucket < 5 {
                folder = folders[0]; base = baseTokyo; locName = "日本 · 东京"
                gps = (35.659 + r.next() * 0.06, 139.700 + r.next() * 0.06)   // (B)(C)
            } else if bucket < 8 {
                folder = folders[1]; base = baseIce; locName = "冰岛 · 维克"
                gps = (63.41 + r.next() * 0.3, -19.05 - r.next() * 0.3)        // (B)(C)
            } else {
                folder = folders[2]; base = baseStreet; locName = "中国 · 上海"
                gps = (31.23 + r.next() * 0.05, 121.47 + r.next() * 0.05)      // (B)(C)
            }

            let dt = Date(timeIntervalSince1970: base + Double(i * 60 * (7 + r.int(40))))  // (D)
            let isPortrait = ori == "p"
            let W = isPortrait ? 4000 : 6000
            let H = isPortrait ? 6000 : 4000
            let focal = focals[r.int(7)]                            // (E)
            let ap = apertures[r.int(apertures.count)]              // (F)

            let ratingRoll = r.next()                               // (G)
            var rating = 0
            if ratingRoll > 0.82 { rating = 5 }
            else if ratingRoll > 0.66 { rating = 4 }
            else if ratingRoll > 0.5 { rating = 3 }
            else if ratingRoll > 0.4 { rating = 2 }
            else if ratingRoll > 0.34 { rating = 1 }
            else { rating = 0 }

            // flag — preserve JS short-circuit r() consumption exactly
            var flag: Flag = .none
            if rating >= 4 && r.next() > 0.4 { flag = .pick }       // (H) only when rating>=4
            else if rating == 0 && r.next() > 0.86 { flag = .reject } // (H') only when rating==0

            var colorLabel: ColorLabel? = nil
            let cl = r.next()                                       // (I)
            if cl > 0.88 { colorLabel = .red }
            else if cl > 0.78 { colorLabel = .green }
            else if cl > 0.7 { colorLabel = .blue }

            var kws: [String] = []
            let nk = 1 + r.int(3)                                   // (J)
            while kws.count < nk {
                let k = keywordPool[r.int(keywordPool.count)]      // (K) repeated
                if !kws.contains(k) { kws.append(k) }
            }
            if folder.id == "fld-tokyo" && !kws.contains("旅行") { kws.insert("旅行", at: 0) }

            let fileMB = rig.type == "HEIC" ? (2 + r.next() * 3) : (24 + r.next() * 22)  // (L)
            let fn = "\(prefix[rig.type] ?? "IMG")_\(pad(4000 + i)).\(rig.type)"

            var status: AssetStatus = .ready
            if folder.id == "fld-iceland" && r.next() > 0.6 { status = .offline }  // (M)

            // (N) shutter then (O) iso — consumed last, inside the object literal
            let shutter = shutters[r.int(shutters.count)]
            let isoVal = isos[r.int(isos.count)]

            result.append(Asset(
                id: "a\(i)",
                pid: seed,
                ori: ori,
                thumb: imgURL(uid, isPortrait ? 500 : 600, isPortrait ? 750 : 400),
                preview: imgURL(uid, isPortrait ? 1300 : 1700, isPortrait ? 1950 : 1133),
                filename: fn,
                type: rig.type,
                isRaw: ["ARW", "CR3", "NEF", "RAF", "DNG"].contains(rig.type),
                folderId: folder.id,
                folderName: folder.name,
                date: dt,
                width: W, height: H,
                orientation: 1,
                camera: "\(rig.make) \(rig.model)",
                lens: rig.lens,
                focal: focal, aperture: ap,
                shutter: shutter, iso: isoVal,
                colorSpace: rig.type == "HEIC" ? "Display P3" : "AdobeRGB",
                fileMB: fileMB,
                rating: rating, flag: flag, colorLabel: colorLabel,
                keywords: kws,
                title: "", caption: "",
                location: locName, gps: gps,
                status: status,
                importedAt: Date(timeIntervalSince1970: baseImport + Double(i * 60))
            ))
        }

        // one explicit missing file (a relocated original)
        if let idx = result.firstIndex(where: { $0.folderId == "fld-street" }) {
            result[idx].status = .missing
        }
        return result
    }

    private static func buildDuplicateGroups(_ assets: [Asset]) -> [DuplicateGroup] {
        let ready = assets.filter { $0.status == .ready }
        var groups: [DuplicateGroup] = []
        var g = 0
        while g < 3 && g * 2 + 1 < ready.count {
            let a = ready[g * 3]
            var clone = a
            clone = Asset(
                id: a.id + "-dup", pid: a.pid, ori: a.ori, thumb: a.thumb, preview: a.preview,
                filename: a.filename.replacingOccurrences(
                    of: #"\.(\w+)$"#, with: " (1).$1", options: .regularExpression),
                type: a.type, isRaw: a.isRaw, folderId: a.folderId, folderName: a.folderName,
                date: a.date, width: a.width, height: a.height, orientation: a.orientation,
                camera: a.camera, lens: a.lens, focal: a.focal, aperture: a.aperture,
                shutter: a.shutter, iso: a.iso, colorSpace: a.colorSpace, fileMB: a.fileMB,
                rating: a.rating, flag: a.flag, colorLabel: a.colorLabel, keywords: a.keywords,
                title: a.title, caption: a.caption, location: a.location, gps: a.gps,
                status: a.status, importedAt: a.importedAt)
            groups.append(DuplicateGroup(
                id: "dg\(g)",
                method: g == 2 ? "perceptualHash" : "contentHash",
                score: g == 2 ? 0.94 : 1.0,
                items: [a, clone]))
            g += 1
        }
        return groups
    }

    // ---- initial collections (built in app.jsx) ----
    static func initialAlbums(_ assets: [Asset]) -> [Album] {
        let picks = assets.filter { $0.flag == .pick }.map { $0.id }
        let tokyo = assets.filter { $0.folderId == "fld-tokyo" }.prefix(6).map { $0.id }
        return [
            Album(id: "al-portfolio", name: "客户精选", assetIds: Array(picks.prefix(8))),
            Album(id: "al-ig", name: "Instagram 发布", assetIds: Array(tokyo)),
        ]
    }

    static func initialSmartAlbums(_ assets: [Asset]) -> [SmartAlbum] {
        let fiveStar = SmartRule(match: "all", conditions: [
            SmartCondition(field: "rating", op: ">=", value: "5")
        ])
        let trip = SmartRule(match: "all", conditions: [
            SmartCondition(field: "keywords", op: "包含", value: "旅行"),
            SmartCondition(field: "rating", op: ">=", value: "3"),
        ])
        return [
            SmartAlbum(id: "sm-5", name: "五星精选", rule: fiveStar,
                       count: SmartMatcher.match(assets, fiveStar).count),
            SmartAlbum(id: "sm-trip", name: "旅行 · 3★以上", rule: trip,
                       count: SmartMatcher.match(assets, trip).count),
        ]
    }
}
