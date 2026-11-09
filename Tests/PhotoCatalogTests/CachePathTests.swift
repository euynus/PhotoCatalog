import CryptoKit
import Foundation
import XCTest
@testable import PhotoCatalog

/// Cache paths are stored in the catalog (an asset's preview) and found again on disk, so the
/// paths built from cached folder strings must be the ones URL appending built, byte for byte.
final class CachePathTests: CatalogTestCase {
    private let kinds: [ThumbnailService.Kind] = [.thumb256, .thumb512, .preview1600, .preview2048]

    // The formulas as they were, kept as the oracle.
    private func oldCachePath(_ store: CatalogStore, assetId: String, kind: ThumbnailService.Kind) -> URL {
        let digest = SHA256.hash(data: Data(assetId.utf8)).compactMap { String(format: "%02x", $0) }.joined()
        let a = String(digest.prefix(2))
        let b = String(digest.dropFirst(2).prefix(2))
        return kind.baseURL(store)
            .appendingPathComponent(a).appendingPathComponent(b)
            .appendingPathComponent("\(assetId).jpg")
    }

    private func oldEditedCachePath(_ store: CatalogStore, assetId: String, kind: ThumbnailService.Kind,
                                    settings: DevelopSettings) -> URL {
        let plain = oldCachePath(store, assetId: assetId, kind: kind)
        let shard = plain.deletingLastPathComponent()
        let relative = shard.path.replacingOccurrences(of: store.cacheURL.path, with: "")
        return store.cacheURL.appendingPathComponent("Edited")
            .appendingPathComponent(relative)
            .appendingPathComponent("\(assetId)-\(settings.fingerprint).jpg")
    }

    private func assertSame(_ new: URL, _ old: URL, _ message: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        guard new != old || new.path != old.path || new.absoluteString != old.absoluteString else { return }
        XCTFail("\(message): \(new.absoluteString) ≠ \(old.absoluteString)", file: file, line: line)
    }

    private func edits() -> [DevelopSettings] {
        var exposure = DevelopSettings()
        exposure.exposure = 0.7
        var cropped = exposure
        cropped.rotation = 90
        return [DevelopSettings(), exposure, cropped]
    }

    /// Ids of every shape: the app's own, and characters a URL escapes, decomposed and
    /// precomposed accents, other scripts, dots, and slashes (which keep the old formula).
    func testHandPickedIdsMatchTheOldFormula() throws {
        let store = try CatalogStore(packageURL: scratch.appendingPathComponent("Bibliothèque 写真 #1.photolibrary"))
        let service = ThumbnailService(store: store)
        let ids = ["r0123456789abcdef", "v89abcdef01234567", "a12", "", " ", "a b", "ü漢字", "x%20y", "a#b",
                   "a?b", "a;b", "a/b", "a//b", "..", ".", "/abs", "trail/", "/", "a\\b", "\u{0}x", "e\u{301}",
                   "\u{e9}", "~", "a:b", "😀", "ﬁ", "a+b&c=d", "'\"", "\u{0600}x", "x\u{200d}y", ".hidden",
                   String(repeating: "长", count: 80)]
        for (index, id) in ids.enumerated() {
            for kind in kinds {
                if index.isMultiple(of: 2) {
                    try FileManager.default.createDirectory(
                        at: oldCachePath(store, assetId: id, kind: kind).deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                }
                assertSame(service.cachePath(assetId: id, kind: kind), oldCachePath(store, assetId: id, kind: kind),
                           "cachePath \(id.debugDescription)")
                for settings in edits() {
                    assertSame(service.editedCachePath(assetId: id, kind: kind, settings: settings),
                               oldEditedCachePath(store, assetId: id, kind: kind, settings: settings),
                               "editedCachePath \(id.debugDescription)")
                }
            }
        }
    }

    /// 10,000 random ids × the four kinds, half with their shard folders already on disk (where
    /// URL appending gives the folder a trailing slash).
    func testRandomIdsMatchTheOldFormula() throws {
        let store = try CatalogStore(packageURL: scratch.appendingPathComponent("Library.photolibrary"))
        let service = ThumbnailService(store: store)
        let pieces = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789").map(String.init)
            + [" ", "%", "#", "?", ";", ":", "\\", ".", "..", "-", "_", "~", "+", "&", "=", "@", "!", "'", "\"",
               "[", "]", "{", "}", "|", "^", "`", "<", ">", "\t", "é", "e\u{301}", "ü", "Å", "漢", "写真", "😀",
               "👩‍👩‍👧", "ﬁ", "\u{0600}", "\u{200d}", "\u{301}", "/"]
        let settings = edits()
        var generator = SplitMix64(seed: 0xcac4e)
        for index in 0..<10_000 {
            let id: String
            switch index % 3 {
            case 0:   // the app's own form: a letter and 16 hex digits
                id = "r" + String(format: "%016llx", generator.next())
            default:
                let length = Int(generator.next() % 20)
                id = (0..<length).map { _ in pieces[Int(generator.next() % UInt64(pieces.count))] }.joined()
            }
            for kind in kinds {
                let old = oldCachePath(store, assetId: id, kind: kind)
                // never for an id with a slash: "../" in it could name a folder outside the scratch one
                if index.isMultiple(of: 2), !id.contains("/") {
                    try FileManager.default.createDirectory(at: old.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                }
                assertSame(service.cachePath(assetId: id, kind: kind),
                           oldCachePath(store, assetId: id, kind: kind), "cachePath \(id.debugDescription)")
            }
            let kind = kinds[index % kinds.count]
            let edit = settings[index % settings.count]
            let oldEdited = oldEditedCachePath(store, assetId: id, kind: kind, settings: edit)
            if index % 4 == 1, !id.contains("/") {
                try FileManager.default.createDirectory(at: oldEdited.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
            }
            assertSame(service.editedCachePath(assetId: id, kind: kind, settings: edit),
                       oldEditedCachePath(store, assetId: id, kind: kind, settings: edit),
                       "editedCachePath \(id.debugDescription)")
        }
    }
}

/// A small seeded generator, so a failure repeats.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}
