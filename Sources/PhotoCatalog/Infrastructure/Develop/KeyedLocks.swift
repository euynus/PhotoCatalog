// ============================================================
//  Keyed locks — one lock per thing being worked out
// ============================================================
import Foundation

/// A lock per key, there while someone holds or waits for it: two renders working out the same
/// photo's measurement wait for each other and share it, while other photos go ahead.
final class KeyedLocks: @unchecked Sendable {
    private let lock = NSLock()
    private var locks: [String: (lock: NSLock, users: Int)] = [:]

    func withLock<T>(_ key: String, _ body: () throws -> T) rethrows -> T {
        let keyed = lock.withLock {
            let entry = locks[key] ?? (NSLock(), 0)
            locks[key] = (entry.lock, entry.users + 1)
            return entry.lock
        }
        defer {
            lock.withLock {
                if let entry = locks[key] { locks[key] = entry.users > 1 ? (entry.lock, entry.users - 1) : nil }
            }
        }
        return try keyed.withLock(body)
    }
}
