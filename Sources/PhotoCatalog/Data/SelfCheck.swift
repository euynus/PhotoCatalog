// ============================================================
//  Headless dataset sanity check — verifies the demo generator
//  reproduces the counts shown in the design mock.
// ============================================================
import Foundation

enum SelfCheck {
    static func run() {
        let a = DemoData.assets
        let ready = a.filter { !$0.deleted }
        func folder(_ id: String) -> Int { ready.filter { $0.folderId == id }.count }

        print("=== PhotoCatalog demo dataset self-check ===")
        print("assets total        : \(a.count)            (expect 44)")
        print("folder tokyo         : \(folder("fld-tokyo"))            (expect 24)")
        print("folder iceland       : \(folder("fld-iceland"))            (expect 12)")
        print("folder street        : \(folder("fld-street"))            (expect 8)")
        print("unrated              : \(ready.filter { $0.rating == 0 && $0.flag != .reject }.count)")
        print("picks                : \(ready.filter { $0.flag == .pick }.count)")
        print("rejected             : \(ready.filter { $0.flag == .reject }.count)")
        print("missing/offline      : \(ready.filter { $0.status == .missing || $0.status == .offline }.count)")
        print("missing only         : \(ready.filter { $0.status == .missing }.count)")
        print("offline only         : \(ready.filter { $0.status == .offline }.count)")
        print("duplicate groups     : \(DemoData.duplicateGroups.count)            (expect 3)")
        let smart = DemoData.initialSmartAlbums(a)
        for s in smart { print("smart '\(s.name)' : \(s.count)") }
        let albums = DemoData.initialAlbums(a)
        for al in albums { print("album '\(al.name)' : \(al.assetIds.count)") }

        // keyword top list (first-encounter order + stable sort, like the sidebar)
        var order: [String] = []
        var kw: [String: Int] = [:]
        for asset in ready {
            for k in asset.keywords {
                if kw[k] == nil { order.append(k) }
                kw[k, default: 0] += 1
            }
        }
        let top = order.map { ($0, kw[$0] ?? 0) }.sorted { $0.1 > $1.1 }.prefix(8)
        print("top keywords         : " + top.map { "\($0.0)=\($0.1)" }.joined(separator: " "))

        // basic integrity assertions
        assert(a.count == 44, "expected 44 assets")
        assert(folder("fld-tokyo") == 24, "tokyo count")
        assert(folder("fld-iceland") == 12, "iceland count")
        assert(folder("fld-street") == 8, "street count")
        assert(DemoData.duplicateGroups.count == 3, "duplicate groups")
        let filters = Filters(minRating: 3, date: "thisYear", gps: "yes", status: "missing")
        assert(filters.activeCount == 4, "extended filter active count")
        print("--- all structural assertions passed ---")
    }
}
