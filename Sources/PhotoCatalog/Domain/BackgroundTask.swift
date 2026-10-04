import Foundation

/// A task-center snapshot, not an execution or retry queue. The owning engine supplies outcomes.
struct BackgroundTask: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case importPhotos, exportPhotos, enhance, ai, preview, backup, restore, analysis, other
    }

    enum State: String, Codable, Sendable {
        case queued, running, paused, completed, failed, cancelled, interrupted

        var isActive: Bool { self == .queued || self == .running || self == .paused }
    }

    struct Failure: Identifiable, Codable, Equatable, Sendable {
        var id = UUID()
        var item: String
        var message: String
        var assetID: String? = nil
        var path: String? = nil
    }

    /// Callbacks are supplied afresh by the engine and never persisted. Retry must capture
    /// the original task inputs, not current library selection. Its callback must preserve
    /// confirmation for overwriting outputs or sending data online; recovery never invokes it.
    struct Actions {
        typealias Handler = @MainActor () -> Void

        var cancel: Handler? = nil
        var retry: Handler? = nil
        var revealDestination: Handler? = nil
        var selectFailures: Handler? = nil
        var retryTitle: String = L("重试任务")
        var cancelTitle: String = L("取消任务")
        var pause: Handler? = nil
        var resume: Handler? = nil
        /// Opens retained results without rerunning work or making a new network request.
        var review: Handler? = nil
    }

    let id: UUID
    var kind: Kind
    var title: String
    var state: State
    let createdAt: Date
    var updatedAt: Date
    var finishedAt: Date?
    var totalCount: Int?
    /// Items acknowledged by the engine, including skips and failures when applicable.
    var completedCount = 0
    var succeededCount = 0
    var failedCount = 0
    var skippedCount = 0
    var detail = ""
    var errorMessage: String?
    var failures: [Failure] = []
    var destination: URL?

    init(id: UUID = UUID(), kind: Kind, title: String, state: State = .queued,
         createdAt: Date = .now, totalCount: Int? = nil, destination: URL? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.state = state
        self.createdAt = createdAt
        updatedAt = createdAt
        self.totalCount = totalCount
        self.destination = destination
    }

    var failureCount: Int { max(failedCount, failures.count) }
    var hasPartialFailure: Bool { !state.isActive && failureCount > 0 && succeededCount > 0 }
    var needsAttention: Bool { state == .failed || state == .interrupted || failureCount > 0 }

    var fractionCompleted: Double? {
        guard let totalCount, totalCount > 0 else { return nil }
        return min(1, max(0, Double(completedCount) / Double(totalCount)))
    }

    var omittedFailureCount: Int { max(0, failureCount - failures.count) }

    func availableActions(_ offered: Actions) -> Actions {
        var result = offered
        if !state.isActive { result.cancel = nil }
        if state.isActive || (state == .completed && failureCount == 0) { result.retry = nil }
        if state != .running { result.pause = nil }
        if state != .paused { result.resume = nil }
        if destination?.isFileURL != true { result.revealDestination = nil }
        if !failures.contains(where: { $0.assetID != nil }) { result.selectFailures = nil }
        return result
    }

    /// Excludes missing/deleted assets and duplicates; never falls back to current selection.
    func failureAssetIDs(availableAssetIDs: Set<String>) -> [String] {
        var seen = Set<String>()
        return failures.compactMap { failure in
            guard let id = failure.assetID, availableAssetIDs.contains(id), seen.insert(id).inserted else {
                return nil
            }
            return id
        }
    }

    static func ordered(_ tasks: [Self]) -> [Self] {
        tasks.sorted { lhs, rhs in
            if lhs.state.isActive != rhs.state.isActive { return lhs.state.isActive }
            let left = lhs.state.isActive ? lhs.createdAt : lhs.updatedAt
            let right = rhs.state.isActive ? rhs.createdAt : rhs.updatedAt
            if left != right { return left > right }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    static func selected(in tasks: [Self], id: UUID?) -> Self? {
        tasks.first { $0.id == id } ?? ordered(tasks).first
    }
}
