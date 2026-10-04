import AppKit
import Foundation

/// Immutable consent snapshot plus a thread-safe invalidation flag. Keys stay in memory only.
final class DescriptionReviewContext: @unchecked Sendable {
    let id = UUID()
    let configuration: LLMConfiguration
    let chinese: Bool
    let catalog: CatalogStore
    let catalogGeneration: Int
    fileprivate let key: String?
    private let invalidation: CancellationFlag
    private let terminationObserver: NSObjectProtocol

    init(configuration: LLMConfiguration, key: String?, chinese: Bool,
         catalog: CatalogStore, catalogGeneration: Int) {
        self.configuration = configuration
        self.key = key
        self.chinese = chinese
        self.catalog = catalog
        self.catalogGeneration = catalogGeneration
        let flag = CancellationFlag()
        invalidation = flag
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in flag.set() }
    }

    deinit { NotificationCenter.default.removeObserver(terminationObserver) }

    var isInvalidated: Bool { invalidation.isSet }
    func invalidate() { invalidation.set() }

    func matches(store: CatalogStore?, generation: Int, isLoading: Bool) -> Bool {
        !isInvalidated && !isLoading && store === catalog && generation == catalogGeneration
    }

    var configurationError: LLMError? {
        if !configuration.isComplete { return .notConfigured }
        if !configuration.acceptsImages { return .imagesNotSupported }
        if configuration.needsKey && (key ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .missingKey
        }
        return nil
    }
}

private struct DescriptionWorkItem: Sendable {
    let id: String
    let filename: String
    let source: (url: URL, isRaw: Bool)?
    let settings: DevelopSettings
    let preview: URL?
    let details: PhotoDescriber.Details
}

private struct DescriptionRequestFailure: Error, Sendable {
    let message: String
    var stopsBatch = false
    var isCancellation = false

    static var cancelled: Self { Self(message: L("已取消，可重新请求"), isCancellation: true) }

    init(message: String, stopsBatch: Bool = false, isCancellation: Bool = false) {
        self.message = message
        self.stopsBatch = stopsBatch
        self.isCancellation = isCancellation
    }

    init(error: Error) {
        // Service responses can echo credentials or request contents; never retain their raw text.
        switch error as? LLMError {
        case .notConfigured, .missingKey, .imagesNotSupported:
            message = (error as? LLMError)?.message ?? L("AI 服务配置不可用")
            stopsBatch = true
        case .http(let status, _):
            message = L("服务返回错误（\(status)）")
            stopsBatch = status == 401 || status == 403 || status == 404
        case .network:
            message = L("无法连接 AI 服务，请检查连接后重试")
        case .malformed:
            message = L("没有得到可用的描述")
        case nil:
            message = L("生成描述失败，请重试")
        }
    }
}

extension AppState {
    typealias DescribeOptions = DescriptionReview.Options

    var descriptionConfiguration: LLMConfiguration {
        descriptionReviewContext?.configuration ?? llmConfiguration
    }

    var hasDescriptionReview: Bool {
        guard let context = descriptionReviewContext, isCurrentDescriptionContext(context) else { return false }
        return descriptionReview?.items.isEmpty == false
    }

    var canDescribePhotos: Bool {
        onboarded && !isLoadingCatalog && sheet == nil && describeProgress == nil
            && (hasDescriptionReview || selectionSummary.hasLive)
    }

    var canStartDescribingPhotos: Bool {
        guard let context = descriptionReviewContext else { return false }
        return isCurrentDescriptionContext(context) && context.configurationError == nil
            && describeProgress == nil && descriptionReview == nil
            && !describeTargets.isEmpty && !describeOptions.isEmpty
    }

    func showDescribePhotos() {
        guard onboarded, !isLoadingCatalog, sheet == nil, describeProgress == nil else { return }
        if hasDescriptionReview {
            showDescriptionReview()
            return
        }
        invalidateDescriptionReview()
        let ids = selectedIds.isEmpty ? Set(primaryId.map { [$0] } ?? []) : selectedIds
        let targets = list.filter { ids.contains($0.id) && !$0.deleted && !$0.isDemo }
        guard let store, !targets.isEmpty else {
            push("请选择已导入的照片", "info")
            return
        }
        descriptionReviewContext = DescriptionReviewContext(
            configuration: llmConfiguration, key: llmKey, chinese: PhotoDescriber.answersInChinese,
            catalog: store, catalogGeneration: catalogLoadGeneration)
        describeOptions.includeMetadata = false
        describeTargets = targets
        sheet = "describe"
    }

    func showDescriptionReview() {
        guard hasDescriptionReview else {
            invalidateDescriptionReview()
            return
        }
        guard sheet == nil || sheet == "describe" || sheet == "descriptionReview" else { return }
        sheet = "descriptionReview"
    }

    /// The consent dialog and requests use the same service, key, language and catalog snapshot.
    func describePhotos() {
        guard let context = descriptionReviewContext, isCurrentDescriptionContext(context) else {
            invalidateDescriptionReview()
            push("目录库已切换，请重新选择照片", "warning")
            return
        }
        guard describeProgress == nil, descriptionReview == nil, !describeOptions.isEmpty else { return }
        if let error = context.configurationError {
            push(verbatim: error.message, "warning")
            return
        }
        let targets = describeTargets.compactMap { asset(id: $0.id) }.filter { !$0.deleted && !$0.isDemo }
        guard !targets.isEmpty else {
            invalidateDescriptionReview()
            push("没有可描述的照片", "info")
            return
        }
        descriptionReview = DescriptionReview(targets: targets, options: describeOptions)
        describeTargets = []
        if sheet == "describe" { sheet = nil }
        startDescriptionBatch(targets, context: context)
    }

    func cancelDescribePhotos() {
        describeCancellation?.set()
        describeTask?.cancel()
    }

    func discardDescriptionReview() { invalidateDescriptionReview() }

    /// Call when starting a catalog switch or detaching it, before releasing file access.
    func invalidateDescriptionReview() {
        descriptionReviewContext?.invalidate()
        cancelDescribePhotos()
        for task in backgroundTasks where task.kind == .ai {
            taskActions[task.id]?.review = nil
        }
        describeTask = nil
        describeCancellation = nil
        describeProgress = nil
        describeTargets = []
        descriptionReview = nil
        descriptionReviewContext = nil
        if sheet == "describe" || sheet == "descriptionReview" { sheet = nil }
    }

    func retryDescriptionFailures(_ ids: [String]) {
        guard describeProgress == nil, let context = descriptionReviewContext,
              isCurrentDescriptionContext(context), let review = descriptionReview else { return }
        let requested = Set(ids).intersection(Set(review.failedIDs))
        guard !requested.isEmpty else { return }
        let targets = review.items.compactMap { item -> Asset? in
            guard requested.contains(item.id), let photo = asset(id: item.id), !photo.deleted, !photo.isDemo else { return nil }
            return photo
        }
        let unavailable = requested.subtracting(targets.map(\.id))
        descriptionReview?.record(failures: Dictionary(uniqueKeysWithValues: unavailable.map {
            ($0, L("照片已删除或不在当前目录库中"))
        }))
        guard !targets.isEmpty else { return }

        let destination = PhotoDescriber.Destination(configuration: context.configuration)
        let alert = NSAlert()
        alert.messageText = L("重新发送 \(targets.count) 张照片？")
        alert.informativeText = [
            destination.isLoopback ? L("本机服务") : L("网络服务"),
            L("服务：\(destination.provider)"), L("模型：\(destination.model)"), destination.endpoint ?? L("未设置"),
            review.options.includeMetadata
                ? L("发送范围：预览图、拍摄日期、相机、位置和已有关键词")
                : L("发送范围：仅预览图"),
            L("照片预览图（最长边 1024 像素，不发送原文件）")
        ].joined(separator: "\n")
        alert.addButton(withTitle: L("重新发送"))
        alert.addButton(withTitle: L("取消"))
        guard alert.runModal() == .alertFirstButtonReturn,
              isCurrentDescriptionContext(context), describeProgress == nil else { return }
        let liveTargets = targets.compactMap { asset(id: $0.id) }.filter { !$0.deleted && !$0.isDemo }
        guard !liveTargets.isEmpty else { return }
        startDescriptionBatch(liveTargets, context: context)
    }

    @discardableResult
    func applyReviewedDescriptions(_ results: [String: PhotoDescriber.Description]) -> Bool {
        guard describeProgress == nil, let context = descriptionReviewContext,
              isCurrentDescriptionContext(context), var review = descriptionReview, !results.isEmpty else { return false }
        let selected = review.selectedDescriptions
        guard results.allSatisfy({ selected[$0.key] == $0.value }) else { return false }
        let currentAssets = results.keys.compactMap { asset(id: $0) }.filter { !$0.deleted && !$0.isDemo }
        if review.refreshExisting(from: currentAssets) {
            descriptionReview = review
            push("照片元数据已改变，请重新审阅更新的结果", "warning")
            return false
        }
        let live = results.filter { id, _ in
            guard let photo = asset(id: id) else { return false }
            return !photo.deleted && !photo.isDemo
        }
        let unavailable = Set(results.keys).subtracting(live.keys)
        guard !live.isEmpty else {
            review.record(failures: Dictionary(uniqueKeysWithValues: unavailable.map {
                ($0, L("照片已删除或不在当前目录库中"))
            }))
            descriptionReview = review
            return false
        }
        let outcome = persistDescriptions(live, options: review.options)
        guard outcome.saved else {
            push("AI 描述未保存，所选结果已保留", "warning")
            return false
        }
        review.removeApplied(Set(live.keys))
        review.record(failures: Dictionary(uniqueKeysWithValues: unavailable.map {
            ($0, L("照片已删除或不在当前目录库中"))
        }))
        descriptionReview = review
        if review.items.isEmpty { invalidateDescriptionReview() }
        push("已应用 \(outcome.changed) 张照片的 AI 描述", "check")
        return true
    }

    /// Kept for existing callers; generation never calls this without explicit review acceptance.
    @discardableResult
    func applyDescriptions(_ results: [String: PhotoDescriber.Description], options: DescribeOptions) -> Int {
        let outcome = persistDescriptions(results, options: options)
        return outcome.saved ? outcome.changed : 0
    }

    private func persistDescriptions(_ results: [String: PhotoDescriber.Description],
                                     options: DescribeOptions) -> (saved: Bool, changed: Int) {
        let ids = Set(results.keys.filter { id in
            guard let photo = asset(id: id) else { return false }
            return !photo.deleted && !photo.isDemo
        })
        guard !ids.isEmpty, !options.isEmpty else { return (false, 0) }
        var changed = 0
        let saved = mutate(ids, undoName: L("AI 描述")) { asset in
            guard let description = results[asset.id] else { return }
            let before = (asset.keywords, asset.title, asset.caption)
            if options.keywords {
                for keyword in description.keywords where !keyword.isEmpty && !asset.keywords.contains(keyword) {
                    asset.keywords.append(keyword)
                }
            }
            if options.title, !description.title.isEmpty, options.replace || asset.title.isEmpty { asset.title = description.title }
            if options.caption, !description.caption.isEmpty, options.replace || asset.caption.isEmpty {
                asset.caption = description.caption
            }
            if before != (asset.keywords, asset.title, asset.caption) { changed += 1 }
        }
        return (saved, saved ? changed : 0)
    }

    private func isCurrentDescriptionContext(_ context: DescriptionReviewContext) -> Bool {
        descriptionReviewContext?.id == context.id
            && context.matches(store: store, generation: catalogLoadGeneration, isLoading: isLoadingCatalog)
    }

    private func startDescriptionBatch(_ targets: [Asset], context: DescriptionReviewContext) {
        guard isCurrentDescriptionContext(context), describeProgress == nil,
              let options = descriptionReview?.options, !targets.isEmpty else { return }
        let originHistory = taskHistory
        var seen: Set<String> = []
        let work = targets.filter { seen.insert($0.id).inserted }.map { asset in
            DescriptionWorkItem(id: asset.id, filename: asset.filename, source: developSource(for: asset),
                                settings: developSettings[asset.id] ?? .neutral,
                                preview: Self.localDescriptionPreview(asset.preview),
                                details: options.includeMetadata
                                    ? .init(date: asset.date, camera: asset.camera, place: asset.location, keywords: asset.keywords)
                                    : .init())
        }
        let cancellation = CancellationFlag()
        describeCancellation = cancellation
        describeProgress = (0, work.count)
        var initialTask = BackgroundTask(kind: .ai, title: L("AI 描述照片"), state: .running, totalCount: work.count)
        initialTask.detail = Self.descriptionTaskDetail(generated: 0, failed: 0, cancelled: 0)
        Self.recordDescriptionTask(initialTask, originHistory: originHistory, owner: self,
                                   context: context, cancellation: cancellation)
        describeTask = Task { @MainActor [weak self, originHistory, initialTask] in
            var snapshot = initialTask
            var finished: Set<String> = []
            var stopped: DescriptionRequestFailure?
            var cancelledCount = 0
            let filenames = Dictionary(uniqueKeysWithValues: work.map { ($0.id, $0.filename) })
            await withTaskGroup(of: (String, Result<PhotoDescriber.Description, DescriptionRequestFailure>).self) { group in
                var next = 0
                @MainActor func start() {
                    guard next < work.count, !cancellation.isSet, !Task.isCancelled, stopped == nil,
                          self?.isCurrentDescriptionContext(context) == true else { return }
                    let item = work[next]
                    next += 1
                    group.addTask { @MainActor [weak self] in
                        guard self?.isCurrentDescriptionContext(context) == true,
                              !cancellation.isSet, !Task.isCancelled else { return (item.id, .failure(.cancelled)) }
                        let image = await ThumbnailRepairQueue.run(.visible) {
                            guard !cancellation.isSet, !context.isInvalidated else { return Data?.none }
                            return PhotoDescriber.image(source: item.source, settings: item.settings, preview: item.preview)
                        } ?? nil
                        guard self?.isCurrentDescriptionContext(context) == true,
                              !cancellation.isSet, !Task.isCancelled else { return (item.id, .failure(.cancelled)) }
                        guard let photo = self?.asset(id: item.id), !photo.deleted, !photo.isDemo else {
                            return (item.id, .failure(.init(message: L("照片已删除或不在当前目录库中"))))
                        }
                        guard let image else { return (item.id, .failure(.init(message: L("无法读取照片预览")))) }
                        do {
                            let reply = try await LLMClient.complete(
                                PhotoDescriber.request(image: image, details: item.details, chinese: context.chinese,
                                                       includeMetadata: options.includeMetadata),
                                configuration: context.configuration, key: context.key)
                            // A received reply is an engine outcome even if its catalog is no longer visible.
                            guard let description = PhotoDescriber.parse(reply, excluding: [item.details.camera]) else {
                                return (item.id, .failure(.init(error: LLMError.malformed)))
                            }
                            return (item.id, .success(description))
                        } catch {
                            switch error as? LLMError {
                            case .http, .malformed, .notConfigured, .missingKey, .imagesNotSupported:
                                return (item.id, .failure(.init(error: error)))
                            default:
                                return (item.id, .failure(cancellation.isSet || Task.isCancelled ? .cancelled : .init(error: error)))
                            }
                        }
                    }
                }
                for _ in 0..<3 { start() }
                for await (id, result) in group {
                    finished.insert(id)
                    switch result {
                    case .success:
                        snapshot.succeededCount += 1
                    case .failure(let error):
                        if error.isCancellation {
                            cancelledCount += 1
                        } else {
                            snapshot.failedCount += 1
                            snapshot.failures.append(.init(item: filenames[id] ?? id, message: error.message, assetID: id))
                            snapshot.failures = Array(snapshot.failures.suffix(BackgroundTaskHistory.failureDetailLimit))
                            if snapshot.errorMessage == nil { snapshot.errorMessage = error.message }
                        }
                        if error.stopsBatch, stopped == nil { stopped = error }
                    }
                    snapshot.completedCount = snapshot.succeededCount + snapshot.failedCount
                    snapshot.updatedAt = .now
                    snapshot.detail = Self.descriptionTaskDetail(
                        generated: snapshot.succeededCount, failed: snapshot.failedCount, cancelled: cancelledCount)
                    Self.recordDescriptionTask(snapshot, originHistory: originHistory, owner: self,
                                               context: context, cancellation: cancellation)
                    guard self?.isCurrentDescriptionContext(context) == true else {
                        group.cancelAll()
                        continue
                    }
                    switch result {
                    case .success(let description): self?.descriptionReview?.record(descriptions: [id: description])
                    case .failure(let error):
                        self?.descriptionReview?.record(failures: [id: error.message])
                    }
                    self?.describeProgress = (finished.count, work.count)
                    if stopped != nil { group.cancelAll() }
                    start()
                }
            }
            cancelledCount += work.count - finished.count
            let sameCatalog = self?.store === context.catalog
                && self?.catalogLoadGeneration == context.catalogGeneration && self?.isLoadingCatalog == false
            let reviewAvailable = self?.isCurrentDescriptionContext(context) == true
            if !sameCatalog || (context.isInvalidated && !cancellation.isSet) {
                snapshot.state = .interrupted
                snapshot.errorMessage = L("目录库或任务上下文已改变，生成已中断")
            } else if cancellation.isSet || Task.isCancelled || !reviewAvailable {
                snapshot.state = .cancelled
            } else if snapshot.failedCount > 0 {
                snapshot.state = .failed
            } else if cancelledCount > 0 {
                snapshot.state = .cancelled
            } else {
                snapshot.state = .completed
            }
            // Cancelled or unattempted photos are not counted as completed generation.
            snapshot.completedCount = snapshot.succeededCount + snapshot.failedCount
            snapshot.updatedAt = .now
            snapshot.finishedAt = snapshot.updatedAt
            snapshot.detail = Self.descriptionTaskDetail(generated: snapshot.succeededCount, failed: snapshot.failedCount,
                                                        cancelled: cancelledCount)
            Self.recordDescriptionTask(snapshot, originHistory: originHistory, owner: self,
                                       context: context, cancellation: cancellation)

            // History belongs to the originating catalog; only live review/UI needs this guard.
            guard let self, self.descriptionReviewContext?.id == context.id else { return }
            guard self.isCurrentDescriptionContext(context) else {
                self.invalidateDescriptionReview()
                return
            }
            let reason = stopped?.message ?? DescriptionRequestFailure.cancelled.message
            self.descriptionReview?.record(failures: Dictionary(uniqueKeysWithValues: work.filter {
                !finished.contains($0.id)
            }.map { ($0.id, reason) }))
            self.descriptionReview?.failPending(reason)
            self.describeProgress = nil
            self.describeCancellation = nil
            self.describeTask = nil
            if self.sheet == nil { self.showDescriptionReview() }
            let successes = self.descriptionReview?.successfulItems.count ?? 0
            let failures = self.descriptionReview?.failedItems.count ?? 0
            if cancellation.isSet {
                self.push("已取消，保留 \(successes) 张照片的待审阅结果", "info")
            } else if failures > 0 {
                self.push("已生成 \(successes) 张照片的描述，\(failures) 张可重试", "warning")
            } else {
                self.push("AI 描述已生成，等待审阅", "sparkles")
            }
        }
    }

    private static func descriptionTaskDetail(generated: Int, failed: Int, cancelled: Int) -> String {
        let counts = L("已生成 \(generated) 张，失败 \(failed) 张，取消 \(cancelled) 张")
        let status = L("生成结果不会自动写入照片元数据，未应用结果仅在当前会话保留")
        return counts + "\n" + status
    }

    private static func recordDescriptionTask(_ snapshot: BackgroundTask, originHistory: BackgroundTaskHistory?,
                                              owner: AppState?, context: DescriptionReviewContext,
                                              cancellation: CancellationFlag) {
        guard let originHistory else { return }
        guard let owner else {
            // upsert stages the terminal snapshot even when saving fails after the owner exits.
            try? originHistory.upsert(snapshot)
            return
        }
        var actions = BackgroundTask.Actions()
        if owner.isCurrentDescriptionContext(context) {
            if snapshot.state.isActive {
                actions.cancel = { [weak owner, weak context] in
                    guard let owner, let context, owner.isCurrentDescriptionContext(context),
                          owner.describeCancellation === cancellation else { return }
                    owner.cancelDescribePhotos()
                }
                actions.cancelTitle = L("取消生成")
            } else if owner.hasDescriptionReview {
                actions.review = { [weak owner, weak context] in
                    guard let owner, let context, owner.isCurrentDescriptionContext(context),
                          owner.describeProgress == nil, owner.hasDescriptionReview else { return }
                    // Only reopen review. Its retry button still asks for explicit send consent.
                    owner.sheet = "descriptionReview"
                }
            }
        }
        owner.recordBackgroundTask(snapshot, originHistory: originHistory, actions: actions)
    }

    private static func localDescriptionPreview(_ path: String) -> URL? {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        guard let url = URL(string: path), url.isFileURL,
              url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
        return url
    }
}
