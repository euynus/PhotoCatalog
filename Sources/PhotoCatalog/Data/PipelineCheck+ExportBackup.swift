import Foundation
import CoreGraphics
import UniformTypeIdentifiers

extension PipelineCheck.Run {
    /// 7. export originals
    func exportOriginals() {
        let exportDir = tmp.appendingPathComponent("export")
        let report = ExportService.copyOriginals(assets, to: exportDir)
        check(report.copied == 7, "exported 7 originals — copied \(report.copied), failed \(report.failed)")
        if let first = assets.first, let firstPath = first.localPath {
            let sourceURL = URL(fileURLWithPath: firstPath)
            let dateParts = Calendar.captureWallClock.dateComponents([.year, .month, .day],
                                                                     from: first.date)
            let dateExportDir = tmp.appendingPathComponent("export-date")
            let dateReport = ExportService.copyOriginals(assets, to: dateExportDir,
                                                         directoryStructure: .date)
            let dateTarget = dateExportDir
                .appendingPathComponent(String(format: "%04d", dateParts.year ?? 0))
                .appendingPathComponent(String(format: "%02d", dateParts.month ?? 1))
                .appendingPathComponent(String(format: "%02d", dateParts.day ?? 1))
                .appendingPathComponent(sourceURL.lastPathComponent)
            check(dateReport.copied == 7 && fm.fileExists(atPath: dateTarget.path),
                  "exported originals into date folders")

            let sourceExportDir = tmp.appendingPathComponent("export-source")
            let sourceReport = ExportService.copyOriginals(
                assets,
                to: sourceExportDir,
                directoryStructure: .sourceFolder,
                sourceRootPathsByFolderId: [first.folderId: src.path])
            let sourceTarget = sourceExportDir
                .appendingPathComponent(src.lastPathComponent)
                .appendingPathComponent(sourceURL.lastPathComponent)
            check(sourceReport.copied == 7 && fm.fileExists(atPath: sourceTarget.path),
                  "exported originals into source folders")

            let albumExportDir = tmp.appendingPathComponent("export-album")
            let albumAssets = Array(assets.prefix(3))
            let albumNames = Dictionary(uniqueKeysWithValues: album.assetIds.map { ($0, album.name) })
            let albumReport = ExportService.copyOriginals(albumAssets, to: albumExportDir,
                                                          directoryStructure: .album,
                                                          albumNamesByAssetId: albumNames)
            let albumTarget = albumExportDir
                .appendingPathComponent(album.name)
                .appendingPathComponent(sourceURL.lastPathComponent)
            check(albumReport.copied == 3 && fm.fileExists(atPath: albumTarget.path),
                  "exported originals into album folders")
        } else {
            check(false, "exported originals into structured folders")
        }
        let metadataJSON = exportDir.appendingPathComponent("metadata.json")
        let metadataCSV = exportDir.appendingPathComponent("metadata.csv")
        var metadataAssets = assets
        metadataAssets[0].author = "Export Author"
        metadataAssets[0].copyright = "Export Copyright"
        metadataAssets[0].makerNotes = "Export MakerNotes"
        metadataAssets[0].project = "Export Project"
        metadataAssets[0].client = "Export Client"
        let exportedJSON = ExportService.exportMetadataJSON(metadataAssets, to: metadataJSON)
        let jsonText = (try? String(contentsOf: metadataJSON, encoding: .utf8)) ?? ""
        check(exportedJSON && jsonText.contains("\"author\"") && jsonText.contains("Export Author")
              && jsonText.contains("\"copyright\"") && jsonText.contains("Export Copyright")
              && jsonText.contains("\"makerNotes\"") && jsonText.contains("Export MakerNotes")
              && jsonText.contains("\"project\"") && jsonText.contains("Export Project")
              && jsonText.contains("\"client\"") && jsonText.contains("Export Client"),
              "exported JSON metadata")
        let jsonRows = (try? JSONSerialization.jsonObject(with: Data(jsonText.utf8)) as? [[String: Any]]) ?? []
        let jsonWithGPS = jsonRows.first { $0["filename"] as? String == metadataAssets[0].filename }
        let jsonMissingGPS = jsonRows.first { $0["filename"] as? String == metadataAssets[1].filename }
        let exportedCSV = ExportService.exportMetadataCSV(metadataAssets, to: metadataCSV)
        let csvText = (try? String(contentsOf: metadataCSV, encoding: .utf8)) ?? ""
        check(exportedCSV && csvText.contains("author,copyright,makerNotes,project,client")
              && csvText.contains("Export Author") && csvText.contains("Export Copyright")
              && csvText.contains("Export MakerNotes") && csvText.contains("Export Project")
              && csvText.contains("Export Client"),
              "exported CSV metadata")
        let missingGPSCSVFields = csvText.split(separator: "\n", omittingEmptySubsequences: false)
            .first { $0.contains(metadataAssets[1].filename) }?
            .split(separator: ",", omittingEmptySubsequences: false)
        check((jsonWithGPS?["gpsLatitude"] as? NSNumber) != nil
              && jsonMissingGPS?["gpsLatitude"] is NSNull
              && jsonMissingGPS?["gpsLongitude"] is NSNull
              && (missingGPSCSVFields?.count ?? 0) > 18
              && missingGPSCSVFields?[17].isEmpty == true
              && missingGPSCSVFields?[18].isEmpty == true,
              "exported metadata omits missing GPS coordinates")
        // regression: attacker-controlled metadata starting with = must be neutralized for
        // spreadsheets, while a legitimate negative number stays a number.
        var injectionAssets = assets
        injectionAssets[0].caption = "=HYPERLINK(\"http://evil\")"
        injectionAssets[1].caption = "\n=HYPERLINK(\"http://evil\")"
        injectionAssets[0].gpsAltitude = -12.5
        let injectionCSV = exportDir.appendingPathComponent("metadata-injection.csv")
        _ = ExportService.exportMetadataCSV(injectionAssets, to: injectionCSV)
        let injectionText = (try? String(contentsOf: injectionCSV, encoding: .utf8)) ?? ""
        check(injectionText.contains("'=HYPERLINK") && injectionText.contains("'\n=HYPERLINK")
              && injectionText.contains("-12.5"),
              "CSV neutralizes formula injection yet preserves negative numbers")
        let previewExportDir = tmp.appendingPathComponent("export-previews")
        let previewReport = ExportService.exportPreviews(assets, to: previewExportDir)
        let previewTargetName = URL(fileURLWithPath: assets[0].filename)
            .deletingPathExtension().lastPathComponent + "-preview.jpg"
        check(previewReport.copied == 7
              && fm.fileExists(atPath: previewExportDir.appendingPathComponent(previewTargetName).path),
              "exported cached previews")
        if let first = assets.first, let originalPath = first.localPath {
            try? fm.removeItem(at: URL(fileURLWithPath: first.preview))
            try? fm.removeItem(at: URL(fileURLWithPath: first.thumb))
            let rebuiltPreviewDir = tmp.appendingPathComponent("export-previews-rebuilt")
            let rebuiltReport = ExportService.exportPreviews([first], to: rebuiltPreviewDir,
                                                             thumbnails: coordinator.thumbnails)
            check(rebuiltReport.copied == 1
                  && fm.fileExists(atPath: first.preview)
                  && fm.fileExists(atPath: originalPath)
                  && fm.fileExists(atPath: rebuiltPreviewDir.appendingPathComponent(previewTargetName).path),
                  "exported previews regenerate missing cache")
            _ = coordinator.thumbnails.ensureCached(from: URL(fileURLWithPath: originalPath),
                                                     assetId: first.id,
                                                     kind: .thumb512)
        } else {
            check(false, "exported previews regenerate missing cache")
        }
        if var fileOpAsset = assets.first, let sourcePath = fileOpAsset.localPath {
            let sourceCopy = tmp.appendingPathComponent("file-op-source.jpg")
            try? fm.copyItem(at: URL(fileURLWithPath: sourcePath), to: sourceCopy)
            fileOpAsset.filename = sourceCopy.lastPathComponent
            fileOpAsset.localPath = sourceCopy.path
            let copyDir = tmp.appendingPathComponent("file-op-copy")
            let copyReport = OriginalFileOperationService.perform(.copy, assets: [fileOpAsset],
                                                                   destination: copyDir)
            check(copyReport.copied == 1
                  && fm.fileExists(atPath: copyDir.appendingPathComponent(sourceCopy.lastPathComponent).path)
                  && fm.fileExists(atPath: sourceCopy.path),
                  "original file operation copies originals")
            let moveDir = tmp.appendingPathComponent("file-op-move")
            let moveReport = OriginalFileOperationService.perform(.move, assets: [fileOpAsset],
                                                                   destination: moveDir)
            let movedURL = moveReport.updatedLocations[fileOpAsset.id]
            check(moveReport.moved == 1 && movedURL != nil
                  && fm.fileExists(atPath: movedURL!.path)
                  && !fm.fileExists(atPath: sourceCopy.path),
                  "original file operation moves originals")
            let sameDirSource = tmp.appendingPathComponent("file-op-same-dir.jpg")
            if let movedURL { try? fm.copyItem(at: movedURL, to: sameDirSource) }
            fileOpAsset.filename = sameDirSource.lastPathComponent
            fileOpAsset.localPath = sameDirSource.path
            let sameDirReport = OriginalFileOperationService.perform(
                .move,
                assets: [fileOpAsset],
                destination: sameDirSource.deletingLastPathComponent())
            check(sameDirReport.skipped == 1
                  && fm.fileExists(atPath: sameDirSource.path)
                  && !fm.fileExists(atPath: tmp.appendingPathComponent("file-op-same-dir (1).jpg").path),
                  "original file operation skips same-folder moves")
        } else {
            check(false, "original file operation copies and moves originals")
        }
    }

    /// 8. backup
    func catalogBackup() {
        let backup = try? BackupService.backup(store)
        if let backup {
            let restorePackage = tmp.appendingPathComponent("restored.photolibrary")
            try? BackupService.restore(backup, intoPackageAt: restorePackage)
            let restoredStore = try? CatalogStore(packageURL: restorePackage)
            let restoredCount = (try? restoredStore?.loadAssets().count) ?? 0
            check(restoredCount == 7, "catalog backup restored — got \(restoredCount) assets")
        } else {
            check(false, "catalog backup restored")
        }
    }
}
