// ============================================================
//  ImportControl — cooperative pause/resume for import workers
// ============================================================
import Foundation

final class ImportControl: @unchecked Sendable {
    private let condition = NSCondition()
    private var paused = false

    var isPaused: Bool {
        condition.lock()
        defer { condition.unlock() }
        return paused
    }

    func pause() {
        condition.lock()
        paused = true
        condition.unlock()
    }

    func resume() {
        condition.lock()
        paused = false
        condition.broadcast()
        condition.unlock()
    }

    func waitIfPaused() {
        condition.lock()
        while paused {
            condition.wait()
        }
        condition.unlock()
    }
}
