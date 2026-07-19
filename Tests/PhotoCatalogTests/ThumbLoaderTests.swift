import AppKit
import XCTest
@testable import PhotoCatalog

@MainActor
final class ThumbLoaderTests: XCTestCase {
    func testCacheKeyIncludesMaxPixel() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-thumb-loader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("image.jpg")
        try writeJPEG(to: url)

        let loader = ThumbLoader()
        loader.load(url.path, maxPixel: 32)
        let small = try await image(from: loader, minPixels: 1)

        loader.load(url.path, maxPixel: 96)
        let large = try await image(from: loader, minPixels: 80)

        XCTAssertGreaterThan(pixelWidth(large), pixelWidth(small))
    }

    func testCacheGenerationForcesReload() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-thumb-loader-generation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("image.jpg")
        try writeJPEG(to: url, size: 32)

        let loader = ThumbLoader()
        loader.load(url.path, maxPixel: 128, cacheGeneration: 0)
        let small = try await image(from: loader, minPixels: 1)

        try writeJPEG(to: url, size: 128)
        loader.load(url.path, maxPixel: 128, cacheGeneration: 0)
        XCTAssertEqual(pixelWidth(loader.image ?? small), pixelWidth(small))

        loader.load(url.path, maxPixel: 128, cacheGeneration: 1)
        let large = try await image(from: loader, minPixels: 80)

        XCTAssertGreaterThan(pixelWidth(large), pixelWidth(small))
    }

    func testCancelAndReleaseDropsImageAndAllowsReload() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-thumb-loader-release-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("image.jpg")
        try writeJPEG(to: url)

        let loader = ThumbLoader()
        loader.load(url.path, maxPixel: 96)
        _ = try await image(from: loader, minPixels: 80)

        loader.cancelAndRelease()
        XCTAssertNil(loader.image)
        XCTAssertFalse(loader.failed)

        loader.load(url.path, maxPixel: 96)
        let reloaded = try await image(from: loader, minPixels: 80)
        XCTAssertGreaterThanOrEqual(pixelWidth(reloaded), 80)
    }

    private func image(from loader: ThumbLoader, minPixels: Int) async throws -> NSImage {
        for _ in 0..<50 {
            if let image = loader.image, pixelWidth(image) >= minPixels { return image }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for thumbnail decode")
        throw NSError(domain: "ThumbLoaderTests", code: 1)
    }

    private func pixelWidth(_ image: NSImage) -> Int {
        image.representations.map(\.pixelsWide).max() ?? Int(image.size.width)
    }

    private func writeJPEG(to url: URL, size: CGFloat = 128) throws {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [:]) else {
            XCTFail("failed to create JPEG fixture")
            return
        }
        try data.write(to: url)
    }
}
