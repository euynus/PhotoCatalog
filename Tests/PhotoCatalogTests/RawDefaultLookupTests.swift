import XCTest
@testable import PhotoCatalog

/// Tethered capture and 复位 find a photo's RAW default the way an import does: the camera's own,
/// or every camera's when the camera has none or its chosen preset has been deleted, and none
/// for a camera kept as shot.
@MainActor
final class RawDefaultLookupTests: XCTestCase {
    override func setUp() {
        super.setUp()
        openingNoCatalogAtLaunch()
    }

    private func raw(_ id: String, camera: String) -> Asset {
        Asset(id: id, pid: 1, ori: "l", thumb: "", preview: "", filename: "\(id).CR3", type: "CR3", isRaw: true,
              folderId: "src", folderName: "Source", date: .now, width: 600, height: 400, orientation: 1, camera: camera,
              lens: "", focal: 0, aperture: 0, shutter: "", iso: 0, colorSpace: "sRGB", fileMB: 0.01, rating: 0,
              flag: .none, keywords: [], title: "", caption: "", location: "", gps: (0, 0), status: .ready,
              importedAt: .now, localPath: "/tmp/pc-raw-default-lookup/\(id).CR3", isDemo: false)
    }

    /// An import's frozen options, the RAW defaults taken from `app` as an import takes them.
    private func snapshot(_ app: AppState, preset: DevelopPreset?) -> ImportOptionsSnapshot {
        let ids = app.rawDefaultPresetIds
        return ImportOptionsSnapshot(duplicateStrategy: "skip", keywords: [], colorLabel: nil, author: "", copyright: "",
                                     albumName: "", albumId: nil, preset: preset,
                                     rawDefaults: ids.compactMapValues { id in app.allDevelopPresets.first { $0.id == id } },
                                     rawDefaultOptOuts: Set(ids.filter { $0.value == "none" }.map(\.key)),
                                     bookmark: nil, revivableIds: nil)
    }

    /// A camera whose chosen preset was deleted: a tethered shot and 复位 get every camera's
    /// default, as an import does.
    func testADeletedCameraPresetFallsBackToEveryCamerasDefault() {
        let app = AppState.selfCheckFixture()
        let shot = raw("tethered", camera: "Camera A")
        app.assets = [shot]
        app.rawDefaultPresetIds = ["Camera A": "user.deleted", "": "builtin.punch"]

        app.applyImportDevelopSettings(to: [shot], preset: nil)

        XCTAssertEqual(app.developSettings[shot.id]?.contrast, 35, "a tethered shot gets every camera's default")
        XCTAssertEqual(app.defaultDevelopSettings(for: shot).contrast, 35, "复位 goes to every camera's default")
        let steps = snapshot(app, preset: nil).developSteps(for: shot)
        XCTAssertEqual(steps.last?.settings, app.developSettings[shot.id], "an import gives the same")
        XCTAssertEqual(steps.map(\.name), [L("RAW 默认设置“\(L("高对比"))”")])
    }

    /// Every combination of a camera's choice and every camera's (unset, a preset, a deleted one,
    /// as shot) gives the same settings and history on all three paths, with an import preset
    /// on top or without.
    func testTetheringResetAndImportAgreeForEveryChoice() {
        let choices: [String?] = [nil, "builtin.punch", "user.deleted", "none"]
        let everyCamera: [String?] = [nil, "builtin.soft", "user.deleted", "none"]
        for preset in [nil, DevelopPreset.builtIns.first { $0.id == "builtin.bw" }] {
            for camera in choices {
                for every in everyCamera {
                    let app = AppState.selfCheckFixture()
                    let shot = raw("shot", camera: "Camera A")
                    app.assets = [shot]
                    var ids: [String: String] = [:]
                    ids["Camera A"] = camera
                    ids[""] = every
                    app.rawDefaultPresetIds = ids
                    let label = "camera \(camera ?? "unset"), every camera \(every ?? "unset"), preset \(preset?.id ?? "none")"

                    let steps = snapshot(app, preset: preset).developSteps(for: shot)
                    _ = app.developHistory(for: shot.id)   // shown, so its history is kept without a catalog
                    let before = app.developHistory(for: shot.id).count
                    app.applyImportDevelopSettings(to: [shot], preset: preset)

                    XCTAssertEqual(app.developSettings[shot.id] ?? .neutral, steps.last?.settings ?? .neutral, label)
                    XCTAssertEqual(app.developHistory(for: shot.id).dropFirst(before).map(\.name), steps.map(\.name), label)
                    let reset = snapshot(app, preset: nil).developSteps(for: shot).last?.settings ?? .neutral
                    XCTAssertEqual(app.defaultDevelopSettings(for: shot), reset, label)
                }
            }
        }
    }
}
