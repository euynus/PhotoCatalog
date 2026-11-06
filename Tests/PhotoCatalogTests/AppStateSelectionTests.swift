import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoCatalog

final class AppStateSelectionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        preservingAllPreferences()
        UserDefaults.app.set(false, forKey: "pc_openLast")
        UserDefaults.app.removeObject(forKey: "pc_pinnedSidebarItems")
    }

    func makeCatalogWithOneAsset(at package: URL, assetIndex: Int) throws -> CatalogStore {
        let source = package.deletingLastPathComponent().appendingPathComponent("Source-\(assetIndex)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let store = try CatalogStore(packageURL: package)
        var asset = DemoData.assets[assetIndex]
        let original = source.appendingPathComponent(asset.filename)
        try Data("image \(assetIndex)".utf8).write(to: original)
        asset.localPath = original.path
        asset.status = .ready
        asset.isDemo = false
        asset.deleted = false
        try store.upsert([asset])
        return store
    }

    /// `base` made again through Asset's initializer with these fields changed, and not a demo
    /// photo. Every other field is `base`'s, except masterId, copyName and duration, which it
    /// leaves to the initializer (nil).
    func rebuiltAsset(_ base: Asset, id: String? = nil, preview: String? = nil, filename: String? = nil,
                      type: String? = nil, isRaw: Bool? = nil, folderId: String? = nil,
                      folderName: String? = nil, status: AssetStatus? = nil, localPath: String?) -> Asset {
        Asset(id: id ?? base.id, pid: base.pid, ori: base.ori, thumb: base.thumb, preview: preview ?? base.preview,
              filename: filename ?? base.filename, type: type ?? base.type, isRaw: isRaw ?? base.isRaw,
              folderId: folderId ?? base.folderId, folderName: folderName ?? base.folderName,
              date: base.date, width: base.width, height: base.height,
              orientation: base.orientation, camera: base.camera, lens: base.lens, focal: base.focal,
              aperture: base.aperture, shutter: base.shutter, iso: base.iso,
              colorSpace: base.colorSpace, hasICCProfile: base.hasICCProfile, fileMB: base.fileMB,
              fileModifiedAt: base.fileModifiedAt, fileCreatedAt: base.fileCreatedAt,
              rating: base.rating, flag: base.flag, colorLabel: base.colorLabel,
              keywords: base.keywords, title: base.title, caption: base.caption,
              author: base.author, copyright: base.copyright, makerNotes: base.makerNotes,
              project: base.project, client: base.client, location: base.location, gps: base.gps,
              gpsAltitude: base.gpsAltitude, status: status ?? base.status, importedAt: base.importedAt,
              deleted: base.deleted, localPath: localPath, captureDateSource: base.captureDateSource,
              contentHash: base.contentHash, quickHash: base.quickHash, isDemo: false, faces: base.faces,
              perceptualHash: base.perceptualHash)
    }

    func writeTestJPEG(to url: URL, black: Bool, gps: [CFString: Any]? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil,
                                      width: 80,
                                      height: 60,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw NSError(domain: "PhotoCatalogTests", code: 1)
        }
        context.setFillColor(black ? CGColor.black : CGColor(red: 0.7, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        if !black {
            context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 30))
        }
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                                UTType.jpeg.identifier as CFString,
                                                                1,
                                                                nil) else {
            throw NSError(domain: "PhotoCatalogTests", code: 2)
        }
        var properties: [CFString: Any] = [:]
        if let gps { properties[kCGImagePropertyGPSDictionary] = gps }
        CGImageDestinationAddImage(destination, image, properties.isEmpty ? nil : properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "PhotoCatalogTests", code: 3)
        }
    }
}
