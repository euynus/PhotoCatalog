import Foundation
import ImageIO
import CoreGraphics

extension PipelineCheck.Run {
    /// 21. memory-card import: detect already-imported photos, copy with pairs renamed together,
    /// sidecars and a backup alongside, then catalog the copies
    func cardImport() {
        let card = tmp.appendingPathComponent("CARD/DCIM/100CANON", isDirectory: true)
        try? fm.createDirectory(at: card, withIntermediateDirectories: true)
        let shot = [kCGImagePropertyExifDateTimeOriginal: "2024:03:09 10:15:00"] as [CFString: Any]
        writeTestImage(to: card.appendingPathComponent("IMG_7001.JPG"), width: 320, height: 200, seed: 71, exif: shot)
        writeTestImage(to: card.appendingPathComponent("IMG_7001.TIF"), width: 320, height: 200, seed: 72, exif: shot)
        writeTestImage(to: card.appendingPathComponent("IMG_7002.JPG"), width: 320, height: 200, seed: 73, exif: shot)
        try? Data("<x:xmpmeta/>".utf8).write(to: card.appendingPathComponent("IMG_7001.xmp"))
        let knownURL = card.appendingPathComponent("IMG_7002.JPG")
        let knownBytes = (try? knownURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        var known = assets[0]
        known.filename = "IMG_7002.JPG"
        known.fileMB = Double(knownBytes) / (1024 * 1024)
        let cardFiles = CardImportService.scan(card.deletingLastPathComponent(),
                                               catalog: CardImportService.CatalogIndex([known]))
        check(cardFiles.count == 3 && cardFiles.filter(\.alreadyImported).map(\.name) == ["IMG_7002.JPG"],
              "card scan lists photos and spots one already in the catalog by size and name")

        let library = tmp.appendingPathComponent("CardLibrary", isDirectory: true)
        let cardBackup = tmp.appendingPathComponent("CardBackup", isDirectory: true)
        var cardOptions = CardImportOptions(destination: library)
        cardOptions.rename = true
        cardOptions.renameTemplate = "{date}_{seq}"
        cardOptions.sequenceStart = 5
        cardOptions.backupEnabled = true
        cardOptions.backup = cardBackup
        let toImport = cardFiles.filter { !$0.alreadyImported }
        let copier = CardCopier(options: cardOptions, files: toImport)
        let cardAssets = coordinator.importFiles(toImport.map(\.url), from: library, mode: .referenced,
                                                 readSidecar: false, preparer: copier)
        let dayFolder = library.appendingPathComponent("2024/2024-03-09")
        let copiedNames = Set((try? fm.contentsOfDirectory(atPath: dayFolder.path)) ?? [])
        check(copiedNames == ["20240309_0005.JPG", "20240309_0005.TIF", "20240309_0005.xmp"],
              "a pair lands in its capture-day folder under one renamed base, sidecar included")
        check(cardAssets.count == 2 && cardAssets.allSatisfy { $0.localPath?.hasPrefix(dayFolder.path) == true },
              "the catalog references the copies, never the card")
        let backedUp = (try? fm.contentsOfDirectory(atPath: cardBackup.path))?.first
            .flatMap { day in
                try? fm.contentsOfDirectory(atPath: cardBackup.appendingPathComponent(day)
                    .appendingPathComponent("2024/2024-03-09").path)
            } ?? []
        check(Set(backedUp) == ["20240309_0005.JPG", "20240309_0005.TIF"],
              "a backup copy is written alongside, in the copies' folders under the import day")
        let again = CardCopier(options: cardOptions, files: toImport)
        let recopied = try? again.copy(card.appendingPathComponent("IMG_7001.JPG"))
        check(recopied?.lastPathComponent == "20240309_0005.JPG"
              && ((try? fm.contentsOfDirectory(atPath: dayFolder.path))?.count ?? 0) == 3,
              "copying the same photo again reuses the copy instead of duplicating it")
    }

    /// 22. camera / phone import: photos listed by device path, downloaded to a staging
    /// folder as the import reaches them, then copied into place like card photos
    func cameraImport() {
        let phone = tmp.appendingPathComponent("PHONE", isDirectory: true)
        try? fm.createDirectory(at: phone, withIntermediateDirectories: true)
        let taken = [kCGImagePropertyExifDateTimeOriginal: "2024:05:02 08:30:00"] as [CFString: Any]
        for (name, seed) in [("IMG_8001.JPG", 81), ("IMG_8001.TIF", 82), ("IMG_8002.JPG", 83), ("IMG_8003.JPG", 84)] {
            writeTestImage(to: phone.appendingPathComponent(name), width: 320, height: 200, seed: seed, exif: taken)
        }
        let deviceFiles = ["IMG_8001.JPG", "IMG_8001.TIF", "IMG_8002.JPG", "IMG_8003.JPG"].map { name in
            CardFile(url: CameraDevicePaths.url(device: "test-phone", folders: ["DCIM", "100APPLE"], name: name),
                     size: Int64((try? phone.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey])
                        .fileSize) ?? 0),
                     modified: .now, isRaw: name.hasSuffix(".TIF"), deviceID: "test-phone")
        }
        let phoneLibrary = tmp.appendingPathComponent("PhoneLibrary", isDirectory: true)
        try? fm.createDirectory(at: phoneLibrary, withIntermediateDirectories: true)
        let staging = (try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                   appropriateFor: phoneLibrary, create: true))
            ?? tmp.appendingPathComponent("Staging", isDirectory: true)
        let stagedFiles = deviceFiles.map { $0.staged(in: staging) }
        var sources: [String: any CameraFileSource] = [:]
        for (file, stagedFile) in zip(deviceFiles, stagedFiles) where file.name != "IMG_8003.JPG" {
            sources[stagedFile.url.path] = FixtureCameraFile(fixture: phone.appendingPathComponent(file.name))
        }
        var phoneOptions = CardImportOptions(destination: phoneLibrary)
        phoneOptions.rename = true
        phoneOptions.renameTemplate = "{date}_{seq}"
        phoneOptions.sequenceStart = 11
        let fetcher = DeviceFileFetcher(sources: sources, copier: CardCopier(options: phoneOptions, files: stagedFiles))
        var phoneFailures = 0
        let phoneAssets = coordinator.importFiles(stagedFiles.map(\.url), from: phoneLibrary, mode: .referenced,
                                                  readSidecar: false, preparer: fetcher) { phoneFailures = $0.failed }
        let phoneDay = phoneLibrary.appendingPathComponent("2024/2024-05-02")
        check(Set((try? fm.contentsOfDirectory(atPath: phoneDay.path)) ?? [])
              == ["20240502_0011.JPG", "20240502_0011.TIF", "20240502_0012.JPG"],
              "camera photos are downloaded and filed like card photos, the pair under one number")
        check(phoneAssets.count == 3 && phoneAssets.allSatisfy { $0.localPath?.hasPrefix(phoneDay.path) == true },
              "the catalog references the copies, not the staged downloads")
        let leftovers = (fm.enumerator(atPath: staging.path)?.allObjects as? [String] ?? [])
            .filter { !$0.hasSuffix("100APPLE") && !$0.hasSuffix("DCIM") && !$0.hasSuffix("test-phone") }
        check(leftovers.isEmpty, "each staged download is removed once it is in place")
        check(phoneFailures == 1, "a photo the device no longer offers fails on its own")
        try? fm.removeItem(at: staging)
    }

    /// Stands in for a photo on a connected camera: "downloading" copies a local file.
    private struct FixtureCameraFile: CameraFileSource {
        let fixture: URL
        func download(to destination: URL) throws {
            try FileManager.default.copyItem(at: fixture, to: destination)
        }
    }
}
