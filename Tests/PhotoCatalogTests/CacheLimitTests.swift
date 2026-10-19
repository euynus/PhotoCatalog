import XCTest
@testable import PhotoCatalog

/// The automatic cache limit: about 0.5 MB a photo, at least 2 GB, at most a quarter of the room
/// the cache has on its disk (the free space and what the cache already takes), and never more
/// than Settings offers.
final class CacheLimitTests: CatalogTestCase {
    private let gb: Int64 = 1 << 30

    private func automatic(photos: Int, previewMaxPixel: Int = 2_048, free: Int64?, cache: Int64 = 0) -> Int {
        CacheLimit.automaticMB(photos: photos, previewMaxPixel: previewMaxPixel, freeBytes: free, cacheBytes: cache)
    }

    func testLimitFollowsThePhotosBetweenTheFloorAndTheRoom() {
        XCTAssertEqual(automatic(photos: 1_000, free: 500 * gb), 2_048, "never under 2 GB")
        XCTAssertEqual(automatic(photos: 14_000, free: 500 * gb), 7_000)
        XCTAssertEqual(automatic(photos: 14_000, previewMaxPixel: 1_600, free: 500 * gb), 5_250)
        XCTAssertEqual(automatic(photos: 14_000, free: 20 * gb), 5_120, "a quarter of the room")
    }

    func testUnknownFreeSpaceGivesTheFloor() {
        // a volume that reports no free space (as "for important usage" does off the startup disk)
        XCTAssertEqual(automatic(photos: 40_000, free: 0, cache: 5 * gb), 2_048)
        XCTAssertEqual(automatic(photos: 40_000, free: nil), 2_048)
    }

    func testCacheFillingTheDiskDoesNotLowerTheLimit() {
        // 40,000 photos want 20,000 MB; 40 GB are free before the cache fills, 32 GB after 8 GB of it
        let empty = automatic(photos: 40_000, free: 40 * gb, cache: 0)
        let filled = automatic(photos: 40_000, free: 32 * gb, cache: 8 * gb)
        XCTAssertEqual(empty, 10_240)
        XCTAssertEqual(filled, empty, "what the cache takes is room it has")
    }

    func testLimitStaysInsideWhatSettingsOffers() {
        XCTAssertEqual(automatic(photos: 1_000_000, free: 4_096 * gb), CacheLimit.rangeMB.upperBound)
    }

    @MainActor
    func testChosenLimitAboveWhatSettingsOffersIsClamped() {
        let saved = UserDefaults.app.object(forKey: "pc_cacheLimitMB")
        defer {
            if let saved { UserDefaults.app.set(saved, forKey: "pc_cacheLimitMB") }
            else { UserDefaults.app.removeObject(forKey: "pc_cacheLimitMB") }
        }
        // stepped down from an automatic limit that was above the Stepper's range
        UserDefaults.app.set(149_744, forKey: "pc_cacheLimitMB")
        let app = AppState()
        XCTAssertEqual(app.cacheLimitMB, CacheLimit.rangeMB.upperBound)
        XCTAssertEqual(app.effectiveCacheLimitMB, CacheLimit.rangeMB.upperBound)
    }
}
