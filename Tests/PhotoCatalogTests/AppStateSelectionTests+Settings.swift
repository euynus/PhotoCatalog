import XCTest
@testable import PhotoCatalog

extension AppStateSelectionTests {
    @MainActor
    func testSettingsPersistAcrossAppStateInstances() throws {
        let keys = [
            "pc_importMode", "pc_managedArchive", "pc_importDuplicateStrategy",
            "pc_importPostKeywords", "pc_importPostColorLabel", "pc_importPostAlbumName",
            "pc_exportXMP", "pc_readXMP", "pc_autoWriteXMP", "pc_exportDirectoryStructure",
            "pc_exportPresets", "pc_recentDays", "pc_lowPower", "pc_vision",
            "pc_cacheLimitMB", "pc_previewMaxPixel", "pc_autoBackupFrequency",
        ]
        let defaults = UserDefaults.app
        let saved = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        keys.forEach { defaults.removeObject(forKey: $0) }
        defer {
            for key in keys {
                if let value = saved[key] ?? nil {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        let app = AppState()
        app.onboarded = true
        app.importMode = .managed
        app.managedArchiveRule = .camera
        app.importDuplicateStrategy = .skipExact
        app.importPostKeywords = "旅行,客户"
        app.importPostColorLabel = ColorLabel.blue.rawValue
        app.importPostAlbumName = "客户交付"
        app.exportDirectoryStructure = .album
        app.exportWritesXMP = true
        app.readXMPSidecar = false
        app.autoWriteXMPSidecar = true
        app.recentImportDays = 30
        app.reduceBackgroundOnLowPower = false
        app.visionEnabled = true
        app.cacheLimitMB = 4_096
        app.previewMaxPixel = 1_600
        app.automaticBackupFrequency = "daily"
        app.saveExportPreset(name: "客户交付")

        let restored = AppState()

        XCTAssertEqual(restored.importMode, .managed)
        XCTAssertEqual(restored.managedArchiveRule, .camera)
        XCTAssertEqual(restored.importDuplicateStrategy, .skipExact)
        XCTAssertEqual(restored.importPostKeywords, "旅行,客户")
        XCTAssertEqual(restored.importPostColorLabel, ColorLabel.blue.rawValue)
        XCTAssertEqual(restored.importPostAlbumName, "客户交付")
        XCTAssertEqual(restored.exportDirectoryStructure, .album)
        XCTAssertTrue(restored.exportWritesXMP)
        XCTAssertFalse(restored.readXMPSidecar)
        XCTAssertTrue(restored.autoWriteXMPSidecar)
        XCTAssertEqual(restored.recentImportDays, 30)
        XCTAssertFalse(restored.reduceBackgroundOnLowPower)
        XCTAssertTrue(restored.visionEnabled)
        XCTAssertEqual(restored.cacheLimitMB, 4_096)
        XCTAssertEqual(restored.previewMaxPixel, 1_600)
        XCTAssertEqual(restored.automaticBackupFrequency, "daily")
        XCTAssertEqual(restored.exportPresets, [
            ExportPreset(name: "客户交付", directoryStructure: "album", writesXMP: true)
        ])
    }

    @MainActor
    func testAutomaticBackupFrequencyRejectsInvalidDefaults() {
        let defaults = UserDefaults.app
        let previous = defaults.object(forKey: "pc_autoBackupFrequency")
        defer {
            if let previous {
                defaults.set(previous, forKey: "pc_autoBackupFrequency")
            } else {
                defaults.removeObject(forKey: "pc_autoBackupFrequency")
            }
        }

        defaults.set("sometimes", forKey: "pc_autoBackupFrequency")
        let app = AppState()
        XCTAssertEqual(app.automaticBackupFrequency, "weekly")

        app.automaticBackupFrequency = "hourly"
        XCTAssertEqual(app.automaticBackupFrequency, "weekly")
        XCTAssertEqual(defaults.string(forKey: "pc_autoBackupFrequency"), "weekly")
    }
}
