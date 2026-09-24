// ============================================================
//  Headless dataset sanity check — verifies the demo generator
//  reproduces the counts shown in the design mock.
// ============================================================
import Foundation
import ImageIO
import AppKit
import SwiftUI

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
        let savedFilterConditions = filters.smartConditions(search: "IMG")
        assert(savedFilterConditions.map(\.field) == ["rating", "datePreset", "gps", "status", "search"],
               "saved filter condition fields")
        let savedFilterRule = SmartRule(match: "all", conditions: savedFilterConditions)
        let savedIds = Set(SmartMatcher.match(ready, savedFilterRule).map(\.id))
        assert(SmartMatcher.count(ready, savedFilterRule) == savedIds.count,
               "smart matcher count matches filtered results")
        let expectedIds = Set(ready.filter { asset in
            asset.rating >= 3
                && asset.status == .missing
                && asset.hasGPS
                && Calendar.captureWallClock.component(.year, from: asset.date) == Calendar.current.component(.year, from: .now)
                && [asset.filename, asset.camera, asset.lens, asset.title, asset.caption, asset.location]
                    .joined(separator: " ")
                    .localizedStandardContains("IMG")
        }.map(\.id))
        assert(savedIds == expectedIds, "saved filter rule matches converted conditions")
        let sample = ready[0]
        let cameraNeedle = String(sample.camera.prefix(4))
        let lensNeedle = String(sample.lens.prefix(5))
        let metadataFilters = Filters(camera: cameraNeedle, lens: lensNeedle)
        let metadataConditions = metadataFilters.smartConditions(search: "")
        assert(metadataFilters.activeCount == 2
               && metadataConditions.map(\.field) == ["camera", "lens"],
               "camera and lens filters convert to smart conditions")
        let metadataRule = SmartRule(match: "all", conditions: metadataConditions)
        let metadataIds = Set(SmartMatcher.match(ready, metadataRule).map(\.id))
        let expectedMetadataIds = Set(ready.filter {
            $0.camera.localizedStandardContains(cameraNeedle)
                && $0.lens.localizedStandardContains(lensNeedle)
        }.map(\.id))
        assert(metadataIds == expectedMetadataIds, "camera and lens filters match assets")
        let hierarchicalKeywords = KeywordService.normalize("旅行/日本/东京, 旅行 > 日本 > 东京;客户精选")
        assert(hierarchicalKeywords == ["旅行", "旅行/日本", "旅行/日本/东京", "客户精选"],
               "hierarchical keywords expand and dedupe")
        let suggestedKeywords = KeywordService.suggestions(for: "日本", pool: hierarchicalKeywords,
                                                           excluding: ["旅行/日本"])
        assert(suggestedKeywords == ["旅行/日本/东京"], "keyword autocomplete uses current keyword pool")
        let projectNames = Set(ready.map(\.project).filter { !$0.isEmpty })
        let clientNames = Set(ready.map(\.client).filter { !$0.isEmpty })
        assert(projectNames.count == 3 && clientNames == ["Northstar Studio", "City Magazine"],
               "project and client dimensions are present")
        let stackGroup = DuplicateGroup(id: "stack-test", method: "perceptualHash",
                                        score: 0.9, items: Array(ready.prefix(3)))
        let stacks = PhotoStackService.stacks(from: [stackGroup])
        let collapsedStackIds = Set(stacks.map(\.id))
        let collapsedAssets = PhotoStackService.visibleAssets(ready, stacks: stacks,
                                                              collapsedStackIds: collapsedStackIds)
        let stackedIds = Set(stackGroup.items.map(\.id))
        assert(stacks.first?.count == 3
               && collapsedAssets.filter { stackedIds.contains($0.id) }.count == 1,
               "photo stacks collapse to one visible representative")
        let makerProps: [CFString: Any] = [
            "MakerNikonDictionary" as CFString: [
                "LensID" as CFString: "NIKKOR Z",
                "Firmware" as CFString: "1.2",
            ],
            kCGImagePropertyExifDictionary: [
                "MakerNote" as CFString: Data([1, 2, 3, 4]),
            ],
        ]
        let makerSummary = MetadataReader.makerNotesSummary(from: makerProps)
        assert(makerSummary.contains("LensID=NIKKOR Z") && makerSummary.contains("MakerNote: 4 bytes"),
               "maker notes summary reads vendor dictionaries")
        let pinned = PinnedSidebarItem(type: .folder, selectionId: "fld-tokyo", name: "2026 东京之旅")
        let pinnedData = try? JSONEncoder().encode([pinned])
        let restoredPins = pinnedData.flatMap { try? JSONDecoder().decode([PinnedSidebarItem].self, from: $0) }
        assert(pinned.id == "folder:fld-tokyo" && restoredPins == [pinned], "pinned sidebar item persists")
        checkThemeContrast()
        InteractionCheck.run()
        ImportSafetyCheck.run()
        ImportPersistenceCheck.run()
        CaptureAnalysisCheck.run()
        assert(CompareView.stageColumnCount(itemCount: 4, size: CGSize(width: 785, height: 1200)) == 2
               && CompareView.stageColumnCount(itemCount: 4, size: CGSize(width: 2064, height: 1200)) == 4
               && CompareView.stageColumnCount(itemCount: 4, size: CGSize(width: 480, height: 440)) == 4
               && CompareView.stageColumnCount(itemCount: 2, size: CGSize(width: 785, height: 1200)) == 2
               && CompareView.stageColumnCount(itemCount: 1, size: CGSize(width: 785, height: 1200)) == 1,
               "comparison layout keeps every panel visible in wide, short, and portrait windows")
        print("--- all structural assertions passed ---")
    }

    private static func checkThemeContrast() {
        func luminance(_ color: Color) -> Double {
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else {
                preconditionFailure("theme colors must resolve to sRGB")
            }
            func linear(_ value: CGFloat) -> Double {
                let channel = Double(value)
                return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(rgb.redComponent)
                + 0.7152 * linear(rgb.greenComponent)
                + 0.0722 * linear(rgb.blueComponent)
        }

        // Workspace tokens are dynamic: hold every pair in both appearances.
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                checkContrastPairs(luminance)
            }
        }
    }

    private static func checkContrastPairs(_ luminance: (Color) -> Double) {
        for (index, (foreground, background, minimum)) in [
            (Theme.text, Theme.bgPanel, 4.5), (Theme.text2, Theme.bgSidebar, 4.5),
            (Theme.text3, Theme.bgSidebar, 4.5), (Theme.accent, Theme.bgPanel, 4.5),
            (Theme.accent, Theme.surface, 4.5), (Theme.text3, Theme.surface, 4.5),
            (Theme.green, Theme.bgPanel, 4.5), (Theme.red, Theme.bgPanel, 4.5),
            (Theme.yellow, Theme.bgPanel, 3.0),
            (Theme.onAccent, Theme.accentFill, 4.5), (Theme.onAccent, Theme.accentFillHover, 4.5),
            (Theme.canvasText, Theme.canvas, 4.5),
            (Theme.canvasText2, Theme.canvasSurface, 4.5), (Theme.canvasText3, Theme.canvasSurface, 4.5),
            (Theme.canvasText2, Theme.canvasSurfaceHi, 4.5),
            (Theme.green, Theme.canvasSurface, 3.0), (Theme.red, Theme.canvasSurface, 3.0),
            (Theme.rating, Theme.canvasSurface, 3.0), (Theme.rating, Theme.bgPanel, 3.0),
            (Theme.starInactive, Theme.canvasSurface, 3.0), (Theme.starInactive, Theme.bgPanel, 3.0),
            (Theme.rating, Theme.canvasSurfaceHi, 3.0), (Theme.starInactive, Theme.canvasSurfaceHi, 3.0),
        ].enumerated() {
            let lightness = [luminance(foreground), luminance(background)].sorted()
            let ratio = (lightness[1] + 0.05) / (lightness[0] + 0.05)
            assert(ratio >= minimum,
                   "workspace text and photo controls must retain readable contrast "
                   + "(\(NSAppearance.currentDrawing().name.rawValue) pair \(index): "
                   + "\(String(format: "%.2f", ratio)) < \(minimum))")
        }
    }
}
