import Foundation
import CryptoKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum ImportSafetyCheck {
    static func run() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-import-safety-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try checkHashes(in: directory)
            checkISO(in: directory)
            try checkManagedCopyFailure(in: directory)
            print("--- import safety assertions passed ---")
        } catch {
            fatalError("Import safety check failed: \(error)")
        }
    }

    private static func checkHashes(in directory: URL) throws {
        let original = directory.appendingPathComponent("hash.bin")
        try Data("abc".utf8).write(to: original)
        assert(HashService.contentHash(original)
               == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
               "full hash must match the known SHA-256 digest")
        let quick = SHA256.hash(data: Data("3abc".utf8)).map { String(format: "%02x", $0) }.joined()
        assert(HashService.quickHash(original, fileSize: 3) == quick,
               "quick hash must retain its size and content format")
        assert(HashService.contentHash(directory) == nil,
               "an unreadable input must not produce an empty-content digest")
        assert(HashService.quickHash(directory, fileSize: 3 * 1024 * 1024) == nil,
               "an unreadable input must not produce a size-only digest")

        // A pipe supplies a readable prefix but cannot seek; no hash API injection is needed.
        let pipe = Pipe()
        defer { try? pipe.fileHandleForReading.close() }
        try pipe.fileHandleForWriting.write(contentsOf: Data("abc".utf8))
        try pipe.fileHandleForWriting.close()
        let pipeURL = URL(fileURLWithPath: "/dev/fd/\(pipe.fileHandleForReading.fileDescriptor)")
        let probe = try FileHandle(forReadingFrom: pipeURL)
        defer { try? probe.close() }
        do {
            try probe.seek(toOffset: 1)
            assertionFailure("pipe fixture must reject seeking")
        } catch {}
        assert(HashService.quickHash(pipeURL, fileSize: 3 * 1024 * 1024) == nil,
               "a failed seek after a readable prefix must not produce a partial quick hash")
    }

    private static func checkISO(in directory: URL) {
        let speed: [CFString: Any] = [kCGImagePropertyExifISOSpeed: 800]
        assert(MetadataReader.isoSpeed(in: speed) == 800, "ISOSpeed must be read")
        let unusableValues: [Any] = [0, -1, [Int](), [0], "unknown", NSNull(),
                                     NSNumber(value: true), NSNumber(value: Double.nan), 1.5]
        for unusable in unusableValues {
            var exif = speed
            exif[kCGImagePropertyExifISOSpeedRatings] = unusable
            exif["PhotographicSensitivity" as CFString] = 0
            assert(MetadataReader.isoSpeed(in: exif) == 800,
                   "unusable preferred values must not block a valid ISO fallback")
        }
        assert(MetadataReader.isoSpeed(in: [kCGImagePropertyExifISOSpeedRatings: [640],
                                           kCGImagePropertyExifISOSpeed: 800]) == 640,
               "valid preferred ISO values retain priority")
        assert(MetadataReader.isoSpeed(in: [:]) == nil, "missing ISO stays unknown")

        for zeroPreferred in [false, true] {
            var exif = speed
            if zeroPreferred { exif[kCGImagePropertyExifISOSpeedRatings] = [0] }
            let image = directory.appendingPathComponent("iso-\(zeroPreferred).jpg")
            writeJPEG(to: image, exif: exif)
            assert(MetadataReader.read(image).iso == 800,
                   "ImageIO file metadata must reach the same valid-value ISO fallback")
        }
    }

    private static func checkManagedCopyFailure(in directory: URL) throws {
        let source = directory.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let original = source.appendingPathComponent("original.jpg")
        writeJPEG(to: original, exif: [kCGImagePropertyExifDateTimeOriginal: "2024:06:15 12:00:00"])
        let originalData = try Data(contentsOf: original)
        let store = try CatalogStore(packageURL: directory.appendingPathComponent("Check.photolibrary"))
        let year = Calendar.captureWallClock.component(.year, from: MetadataReader.read(original).captureDate)
        let blocked = store.originalsURL.appendingPathComponent(String(format: "%04d", year))
        let blockerData = Data("not a directory".utf8)
        try blockerData.write(to: blocked)

        var progress: [ImportProgress] = []
        let imported = ImportCoordinator(store: store).importFiles(
            [original], from: source, mode: .managed, readSidecar: false
        ) { progress.append($0) }
        assert(imported.isEmpty && progress.last?.processed == 0 && progress.last?.failed == 1,
               "a failed managed copy must not be a successful referenced import")
        assert(progress.last?.latestAsset == nil && progress.last?.latestFailure?.path == original.path,
               "managed copy failure must identify the failed source file")
        assert(progress.last?.latestFailure?.reason.contains("\u{590D}\u{5236}\u{539F}\u{4EF6}\u{5931}\u{8D25}") == true,
               "managed copy failure must surface a copy error, not a metadata error")
        let unchangedOriginal = try Data(contentsOf: original)
        let unchangedBlocker = try Data(contentsOf: blocked)
        assert(unchangedOriginal == originalData && unchangedBlocker == blockerData,
               "failed import must leave the source original and destination blocker untouched")
        assert(store.assetCount() == 0, "failed import must not create catalog assets")
    }

    private static func writeJPEG(to url: URL, exif: [CFString: Any]) {
        guard let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
                                      bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
              ) else { fatalError("Could not create synthetic JPEG") }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyExifDictionary: exif] as CFDictionary)
        precondition(CGImageDestinationFinalize(destination), "Could not write synthetic JPEG")
    }
}
