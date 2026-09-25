// ============================================================
//  Bounded executors for synchronous cache regeneration
// ============================================================
import Foundation

/// Cache regeneration decodes originals synchronously — seconds per RAW. Run on the
/// Swift cooperative pool, a screenful of repairs took every thread: catalog hydration
/// stalled (leaving the window disabled) and RawCamera deadlocked, its render path
/// waiting on work that needed a free thread. Dedicated queues keep these decodes off
/// the pool and bound how many RAWs decode at once.
enum ThumbnailRepairQueue {
    enum Lane {
        /// Cells on screen: user-initiated, never queued behind backfill.
        case visible
        /// Catalog-wide backfill: background QoS keeps multi-core RAW decodes on the
        /// efficiency cores instead of competing with scrolling and selection.
        case background
    }

    private static let visibleQueue = makeQueue("visible", concurrency: 2, qos: .userInitiated)
    private static let backgroundQueue = makeQueue("backfill", concurrency: 1, qos: .background)

    private static func makeQueue(_ name: String, concurrency: Int, qos: QualityOfService) -> OperationQueue {
        let queue = OperationQueue()
        queue.name = "PhotoCatalog.thumbnail-repair.\(name)"
        queue.maxConcurrentOperationCount = concurrency
        queue.qualityOfService = qos
        return queue
    }

    /// Runs `work` on the lane's queue. Returns nil without running it when the calling
    /// task is cancelled while still queued (e.g. its grid cell scrolled away).
    static func run<T: Sendable>(_ lane: Lane, _ work: @escaping @Sendable () -> T) async -> T? {
        let cancelled = CancellationFlag()
        let queue = lane == .visible ? visibleQueue : backgroundQueue
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.addOperation {
                    continuation.resume(returning: cancelled.isSet ? nil : work())
                }
            }
        } onCancel: {
            cancelled.set()
        }
    }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
