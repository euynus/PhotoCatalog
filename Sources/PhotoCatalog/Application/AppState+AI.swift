import AppKit
import Foundation

@MainActor
extension AppState {
    // ---------- AI: language models (Settings → AI) ----------
    /// The API key saved for the current service.
    var llmKey: String? { llmKeyOverride ?? LLMKeychain.key(for: llmConfiguration) }

    /// Why the AI features can't ask the service yet, if they can't.
    var llmSetupError: LLMError? {
        llmConfiguration.isComplete ? llmConfiguration.keyError(for: llmKey) : .notConfigured
    }

    var isLLMReady: Bool { llmSetupError == nil }

    /// One request to the configured service.
    func askLLM(_ request: LLMRequest) async throws -> String {
        if let llmOverride { return try await llmOverride(request) }
        return try await LLMClient.complete(request, configuration: llmConfiguration, key: llmKey)
    }

    /// Settings → AI → 测试连接: a one-word exchange with the service.
    func testLLMConnection() {
        guard !llmTesting else { return }
        llmTesting = true
        llmTestResult = nil
        let request = LLMRequest(system: "You are a connection test.", prompt: "Reply with the single word OK.", maxTokens: 16)
        Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.askLLM(request)
                let excerpt = String(reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
                self.llmTestResult = (true, L("连接成功：\(excerpt)"))
            } catch {
                self.llmTestResult = (false, (error as? LLMError)?.message ?? error.localizedDescription)
            }
            self.llmTesting = false
        }
    }

    // ---------- AI: natural-language search ----------
    /// 编辑 → 用自然语言查找…
    func showNaturalSearch() {
        guard onboarded, sheet == nil else { return }
        sheet = "naturalSearch"
    }

    /// The dialog's 查找: the search, which closes the dialog once it shows. Cancel, Esc, or the
    /// dialog closing any other way cancels it (see `sheet`).
    func startNaturalSearch(_ query: String) {
        naturalSearchTask?.cancel()
        naturalSearchTask = Task { [weak self] in
            guard let self, await self.searchNaturally(query), self.sheet == "naturalSearch" else { return }
            self.sheet = nil
        }
    }

    func cancelNaturalSearch() {
        naturalSearchTask?.cancel()
        naturalSearchTask = nil
    }

    /// What the catalog holds, for the model to pick from: cameras, lenses and keywords by how
    /// often they're used, and the file types present.
    func searchVocabulary() -> PhotoSearch.Vocabulary {
        let live = assets.filter { !$0.deleted }
        return PhotoSearch.Vocabulary(
            cameras: countMetadataValues(\.camera).sorted { $0.count > $1.count }.map(\.name),
            lenses: countMetadataValues(\.lens).sorted { $0.count > $1.count }.map(\.name),
            keywords: keywordList.sorted { $0.count > $1.count }.map(\.name),
            types: Array(Set(live.map { $0.type.uppercased() })).sorted())
    }

    /// Reads `query` with the language model and shows what it asks for: the filter bar and the
    /// search box set, within the current source. True when the sentence was understood.
    func searchNaturally(_ query: String) async -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !naturalSearchRunning else { return false }
        if let error = llmSetupError {
            push(verbatim: error.message, "warning")
            return false
        }
        naturalSearchRunning = true
        defer { naturalSearchRunning = false }
        naturalSearchQuery = query
        let vocabulary = searchVocabulary()
        do {
            let reply = try await askLLM(PhotoSearch.request(query, today: .now, vocabulary: vocabulary,
                                                             chinese: PhotoDescriber.answersInChinese))
            // cancelled with its dialog: a reply that comes anyway changes nothing
            guard !Task.isCancelled else { return false }
            guard let interpretation = PhotoSearch.parse(reply, vocabulary: vocabulary, query: query) else {
                push("没能理解这句话，请换个说法", "warning")
                return false
            }
            filters = interpretation.filters
            search = interpretation.text
            // as the filter bar does: photos the new list hides leave the selection, or the next key edits them unseen
            ensurePrimaryValid()
            push("按“\(query)”找到 \(list.count) 张照片", "sparkles")
            return true
        } catch {
            // the request stopped because its dialog closed: nothing to report
            guard !Task.isCancelled else { return false }
            push(verbatim: (error as? LLMError)?.message ?? error.localizedDescription, "warning")
            return false
        }
    }

    // ---------- AI: develop by text ----------
    private static let photoSendingConsentKey = "pc_developByTextConsent"

    func mayDevelopByTextSendPhoto() -> Bool {
        let destination = PhotoDescriber.Destination(configuration: llmConfiguration)
        guard !destination.isLoopback, let endpoint = destination.endpoint else { return true }
        var allowed = UserDefaults.app.stringArray(forKey: Self.photoSendingConsentKey) ?? []
        guard !allowed.contains(endpoint) else { return true }
        guard confirmSendingPhoto(destination.provider, endpoint) else { return false }
        allowed.append(endpoint)
        UserDefaults.app.set(allowed, forKey: Self.photoSendingConsentKey)
        return true
    }

    static func confirmSendingPhoto(provider: String, endpoint: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = L("把这张照片发送给 \(provider)？")
        alert.informativeText = L("用文字修图会把照片的预览图（最长边 1024 像素，不发送原文件）和当前的修图参数发送到 \(endpoint)，由它的模型给出调整。同意后，再发送给这个服务时不再询问。")
        alert.addButton(withTitle: L("发送"))
        alert.addButton(withTitle: L("取消"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    func developByText(_ description: String) async -> Bool {
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty, !developByTextRunning, view == .develop, let asset = primary, canDevelop(asset) else {
            return false
        }
        if let error = llmSetupError {
            push(verbatim: error.message, "warning")
            return false
        }
        guard !llmConfiguration.acceptsImages || mayDevelopByTextSendPhoto() else { return false }
        developByTextRunning = true
        defer { developByTextRunning = false }
        developByTextQuery = description
        let id = asset.id
        let settings = developSettings[id] ?? .neutral
        let source = developSource(for: asset)
        let isRaw = source?.isRaw ?? false
        let wantsImage = llmConfiguration.acceptsImages
        // the photo as it looks now, and a RAW's as-shot white balance, read off the main thread
        let seen = await ThumbnailRepairQueue.run(.visible) { () -> (image: Data?, asShot: DevelopByText.AsShot) in
            guard let source, let photo = DevelopRenderer.Source(url: source.url, isRaw: source.isRaw, maxPixel: 1400) else {
                return (nil, DevelopByText.AsShot())
            }
            let image = wantsImage ? photo.image(settings).flatMap(DevelopRenderer.render).flatMap { LLMClient.jpeg($0) } : nil
            return (image, DevelopByText.AsShot(temperature: photo.asShotTemperature, tint: photo.asShotTint))
        } ?? (image: nil, asShot: DevelopByText.AsShot())
        do {
            let reply = try await askLLM(DevelopByText.request(description, settings: settings, isRaw: isRaw, asShot: seen.asShot,
                                                               image: seen.image, chinese: PhotoDescriber.answersInChinese))
            guard let look = DevelopByText.parse(reply, onto: developSettings[id] ?? settings, isRaw: isRaw, asShot: seen.asShot) else {
                push("没能从回复中得到调整，请换个说法", "warning")
                return false
            }
            commitDevelop([id: look.settings], undoName: L("AI 调整"))
            if look.explanation.isEmpty { push("已按描述调整", "sparkles") } else { push(verbatim: look.explanation, "sparkles") }
            return true
        } catch {
            push(verbatim: (error as? LLMError)?.message ?? error.localizedDescription, "warning")
            return false
        }
    }

    // ---------- enhance: AI denoise and super resolution ----------
    var canEnhance: Bool {
        onboarded && sheet == nil && enhanceProgress == nil && !selectionTargetIds.isEmpty && canOperateOnSelectedOriginals
            && AIModels.isAvailable(.denoise) && AIModels.isAvailable(.superResolution)
    }

    /// 照片 → 增强…: AI denoise and super resolution for the selected photos, with a preview.
    func showEnhance() {
        // the right-click menu offers this when the menu bar's is disabled: its dialog would do nothing
        guard enhanceProgress == nil else {
            push("正在增强照片，请等它完成", "info")
            return
        }
        guard AIModels.isAvailable(.denoise), AIModels.isAvailable(.superResolution) else {
            push("这个版本的应用没有增强所用的 AI 模型", "warning")
            return
        }
        let targets = photoMergeCandidates().filter { developSource(for: $0) != nil }
        guard !targets.isEmpty else {
            push("请选择有原件的照片", "info")
            return
        }
        enhanceTargets = targets
        sheet = "enhance"
    }

    /// Where a photo's pixels come from for Enhance: its original (a RAW over its JPEG).
    func enhanceSource(for asset: Asset) -> (url: URL, isRaw: Bool)? { developSource(for: asset) }

    /// Runs Enhance on each target in turn: its pixels as shot, denoised and/or enlarged, saved
    /// as `<name>-Enhanced.tif` beside the original with its metadata, added to the catalog
    /// with the photo's catalog details and develop settings (less the white balance, which the
    /// new file already carries).
    func enhancePhotos() {
        let targets = enhanceTargets, options = enhanceOptions
        guard !targets.isEmpty, !options.isEmpty, enhanceProgress == nil, let coordinator, let store else { return }
        let sources = targets.map { developSource(for: $0) }
        let previewSize = previewMaxPixel
        let albumId = selection.type == .album ? selection.id : nil
        let cancellation = CancellationFlag()
        enhanceCancellation = cancellation
        enhanceProgress = (0, targets.count, 0)
        let originHistory = taskHistory
        let outputFolders = Set(sources.compactMap { $0?.url.deletingLastPathComponent() })
        let initial = BackgroundTask(kind: .enhance, title: L("增强照片"), state: .running,
                                     totalCount: targets.count,
                                     destination: outputFolders.count == 1 ? outputFolders.first : nil)
        if let originHistory {
            recordBackgroundTask(initial, originHistory: originHistory,
                                 actions: .init(cancel: { cancellation.set() }))
        }
        Task { [weak self, targets, coordinator, store, originHistory, initial] in
            var task = initial
            var made: [(url: URL, source: Asset, asset: Asset?)] = []
            var unreadable = 0, readOnly = 0
            var failedIDs = Set<String>()
            func fail(_ target: Asset, _ reason: String, path: String? = nil) {
                guard failedIDs.insert(target.id).inserted else { return }
                task.failedCount += 1
                task.failures.append(.init(item: target.filename, message: reason, assetID: target.id,
                                           path: path ?? target.localPath))
                task.failures = Array(task.failures.suffix(BackgroundTaskHistory.failureDetailLimit))
            }
            work: for (index, target) in targets.enumerated() {
                guard !cancellation.isSet else { break }
                let source = sources[index]
                let outcome: EnhanceOutcome = await withCheckedContinuation { continuation in
                    Enhance.queue.async {
                        guard let source,
                              let image = DevelopRenderer.Source(url: source.url, isRaw: source.isRaw, maxPixel: nil)?.image(.neutral)
                        else { return continuation.resume(returning: .unreadable) }
                        let folder = source.url.deletingLastPathComponent()
                        guard FileManager.default.isWritableFile(atPath: folder.path) else {
                            return continuation.resume(returning: .readOnly)
                        }
                        let planes = Enhance.enhance(image, options: options, progress: { fraction in
                            Task { @MainActor [weak self] in
                                guard let self, self.enhanceCancellation === cancellation else { return }
                                self.enhanceProgress = (index, targets.count, fraction)
                            }
                        }, cancelled: { cancellation.isSet })
                        guard let planes, let result = Enhance.image(planes) else {
                            return continuation.resume(returning: cancellation.isSet ? .cancelled : .unreadable)
                        }
                        let url = Self.freeURL(in: folder, stem: source.url.deletingPathExtension().lastPathComponent + "-Enhanced",
                                               extension: "tif")
                        guard Enhance.writeTIFF(result, to: url, metadataFrom: source.url) else {
                            return continuation.resume(returning: .unreadable)
                        }
                        let imported = coordinator.importFiles([url], from: folder, readSidecar: false,
                                                               previewMaxPixel: previewSize,
                                                               reusingRemovedIds: false).first
                        continuation.resume(returning: .made(url: url, asset: imported))
                    }
                }
                switch outcome {
                case .made(let url, let asset):
                    made.append((url, target, asset))
                    if asset == nil { fail(target, L("增强文件已生成，但无法读取结果以加入目录库"), path: url.path) }
                case .unreadable:
                    unreadable += 1
                    fail(target, L("无法读取照片或生成增强结果"))
                case .readOnly:
                    readOnly += 1
                    fail(target, L("原件所在文件夹不可写入"))
                case .cancelled: break work
                }
                task.completedCount += 1
                task.detail = L("已生成 \(made.count) 个增强文件")
                if let originHistory { self?.recordBackgroundTask(task, originHistory: originHistory) }
            }
            guard let self else { return }
            if self.enhanceCancellation === cancellation {
                self.enhanceProgress = nil
                self.enhanceCancellation = nil
            }
            var importedIDs = Set<String>()
            if self.store === store, !made.isEmpty {
                let imported = self.finishExternalEdit(made, editor: nil, expected: made.count, albumId: albumId)
                importedIDs = imported.importedIDs
                task.errorMessage = imported.errorMessage
                for result in made {
                    guard let asset = result.asset else { continue }
                    if !importedIDs.contains(asset.id) {
                        fail(result.source, imported.errorMessage ?? L("增强文件未加入目录库"), path: result.url.path)
                    } else if let message = imported.errorMessage {
                        fail(result.source, message, path: result.url.path)
                    }
                }
                // the new photos keep the look their originals were given
                var carried: [String: DevelopSettings] = [:]
                for result in made {
                    guard let asset = result.asset, importedIDs.contains(asset.id),
                          let settings = self.developSettings[result.source.id] else { continue }
                    carried[asset.id] = settings.withoutWhiteBalance
                }
                if !carried.isEmpty {
                    self.commitDevelop(carried, undoName: L("增强"))
                    for result in made {
                        guard let asset = result.asset, let settings = carried[asset.id],
                              (self.developSettings[asset.id] ?? .neutral) != settings else { continue }
                        fail(result.source, L("增强文件已入库，但修图设置未能保存"), path: result.url.path)
                    }
                }
            } else if !made.isEmpty {
                let message = L("原目录库已关闭或重新打开，增强结果未加入当前目录库")
                task.errorMessage = message
                for result in made { fail(result.source, message, path: result.url.path) }
            }
            task.succeededCount = made.filter {
                guard let asset = $0.asset else { return false }
                return importedIDs.contains(asset.id) && !failedIDs.contains($0.source.id)
            }.count
            task.detail = L("已生成 \(made.count) 个增强文件 · 已加入目录库 \(importedIDs.count) 张照片")
            task.state = cancellation.isSet ? .cancelled : (task.failedCount > 0 ? .failed : .completed)
            if let originHistory { self.recordBackgroundTask(task, originHistory: originHistory, actions: .init()) }
            guard self.store === store else { return }
            if cancellation.isSet {
                self.push(made.isEmpty ? "已取消增强" : "已取消增强，已完成 \(made.count) 张", "info")
            } else if task.failedCount == 0 {
                self.push(made.count == 1 ? "已增强照片" : "已增强 \(made.count) 张照片", "wand.and.stars")
            } else if readOnly > 0 {
                self.push("有 \(readOnly) 张照片所在的文件夹是只读的，无法保存增强结果", "warning")
            } else if unreadable > 0 {
                self.push("有 \(unreadable) 张照片无法读取，未能增强", "warning")
            } else {
                self.push("已生成 \(made.count) 个增强文件，\(task.failedCount) 张未完成入库或修图设置保存", "warning")
            }
        }
    }

    private enum EnhanceOutcome: Sendable {
        case made(url: URL, asset: Asset?)
        case unreadable, readOnly, cancelled
    }

    /// `<stem>.<ext>` in `folder`, or `<stem>-2.<ext>`… when that's taken.
    nonisolated static func freeURL(in folder: URL, stem: String, extension ext: String) -> URL {
        var url = folder.appendingPathComponent("\(stem).\(ext)"), number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(stem)-\(number).\(ext)")
            number += 1
        }
        return url
    }
}
