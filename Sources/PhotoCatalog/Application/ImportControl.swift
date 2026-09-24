// ============================================================
//  ImportControl — cooperative pause/resume/cancellation for import workers
// ============================================================
import Foundation

final class ImportControl: @unchecked Sendable {
    private let condition = NSCondition()
    private var paused = false
    private var cancelled = false

    var isPaused: Bool {
        condition.lock()
        defer { condition.unlock() }
        return paused
    }

    func pause() {
        condition.lock()
        if !cancelled { paused = true }
        condition.unlock()
    }

    func resume() {
        condition.lock()
        paused = false
        condition.broadcast()
        condition.unlock()
    }

    func cancel() {
        condition.lock()
        cancelled = true
        paused = false
        condition.broadcast()
        condition.unlock()
    }

    @discardableResult
    func waitIfPaused() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while paused && !cancelled {
            condition.wait()
        }
        return !cancelled
    }
}
