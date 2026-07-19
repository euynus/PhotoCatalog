import CoreFoundation
import Foundation
import OSLog

@MainActor
final class InteractionLatencyTracker {
    static let shared = InteractionLatencyTracker()

    private struct PendingInteraction {
        let id: UInt64
        let name: String
        let startedAt: TimeInterval
        var handlerMilliseconds: Double?
    }

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.photocatalog.app",
        category: "Interaction"
    )
    private var observer: CFRunLoopObserver?
    private var pending: PendingInteraction?
    private var nextID: UInt64 = 0

    func measure(_ name: String, action: () -> Void) {
        installObserverIfNeeded()
        nextID &+= 1
        let id = nextID
        let startedAt = ProcessInfo.processInfo.systemUptime
        pending = PendingInteraction(id: id, name: name, startedAt: startedAt)

        action()

        guard pending?.id == id else { return }
        pending?.handlerMilliseconds = elapsedMilliseconds(since: startedAt)
    }

    private func installObserverIfNeeded() {
        guard observer == nil else { return }
        let observer = CFRunLoopObserverCreateWithHandler(
            nil,
            CFRunLoopActivity.beforeWaiting.rawValue,
            true,
            0
        ) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.finishPendingInteraction()
            }
        }
        self.observer = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    private func finishPendingInteraction() {
        guard let pending else { return }
        self.pending = nil
        let responseMilliseconds = elapsedMilliseconds(since: pending.startedAt)
        let handlerMilliseconds = pending.handlerMilliseconds ?? -1
        logger.info(
            "action=\(pending.name, privacy: .public) response_ms=\(responseMilliseconds, format: .fixed(precision: 1)) handler_ms=\(handlerMilliseconds, format: .fixed(precision: 1))"
        )
    }

    private func elapsedMilliseconds(since start: TimeInterval) -> Double {
        (ProcessInfo.processInfo.systemUptime - start) * 1_000
    }
}
