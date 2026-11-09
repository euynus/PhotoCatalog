import Foundation

/// How the headless checks wait: they run step by step on the main thread, so work that finishes
/// later (on the main actor, or off it) is waited for here.
enum CheckWait {
    /// Turns the main run loop every `poll` seconds until `done`, or until `timeout` seconds have
    /// passed; the caller asserts what it waited for.
    @MainActor
    static func until(_ timeout: TimeInterval, poll: TimeInterval = 0.02, _ done: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(poll)) }
    }

    /// Runs `body` on the main actor, turning the run loop until it's done.
    @MainActor
    static func onMain<T>(_ body: @escaping @MainActor () async -> T) -> T {
        var result: T?
        Task { @MainActor in result = await body() }
        while result == nil { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
        return result!
    }

    /// `body` run to completion off the main actor, blocking the calling thread until it's done.
    static func blocking<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: T?
        Task.detached {
            result = await body()
            semaphore.signal()
        }
        semaphore.wait()
        return result!
    }
}
