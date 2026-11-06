import AppKit
import Foundation

@MainActor
extension AppState {
    // ----- slideshow (Lightroom's Slideshow module) -----
    /// What a slideshow plays, a web gallery shows or a book lays out: the selected photos when
    /// several are selected, otherwise every photo in the list, in list order (videos left out).
    func presentationAssets() -> [Asset] {
        let ids = selectedIds
        let base = ids.count > 1 ? list.filter { ids.contains($0.id) } : list
        return base.filter { !$0.isVideo && !$0.preview.isEmpty }
    }

    var canSlideshow: Bool { onboarded && sheet == nil && slideshowPlayer == nil && !list.isEmpty }

    func showSlideshow() {
        guard canSlideshow else { return }
        guard !presentationAssets().isEmpty else {
            push("没有可放映的照片", "info")
            return
        }
        sheet = "slideshow"
    }

    /// The photos in the order the slideshow plays them, shuffled alike every time for them.
    private func slideshowOrder(_ assets: [Asset], settings: SlideshowSettings) -> [Asset] {
        var seed: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in assets.map(\.id).joined(separator: "|").utf8 { seed = (seed ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return settings.order(assets.count, seed: seed).map { assets[$0] }
    }

    private func slideshowMusic(_ settings: SlideshowSettings) -> URL? {
        guard !settings.musicPath.isEmpty else { return nil }
        let url = URL(fileURLWithPath: settings.musicPath)
        FileAccessService.reach(url)
        return FileAccessService.canRead(url.path) ? url : nil
    }

    /// ⌘↩ or 播放: the slideshow full screen with the current settings.
    func playSlideshow() {
        let assets = slideshowOrder(presentationAssets(), settings: slideshowSettings)
        guard !assets.isEmpty, slideshowPlayer == nil else { return }
        sheet = nil
        let music = slideshowMusic(slideshowSettings)
        let seconds = slideshowSettings.slideSeconds(fitting: assets.count, toMusic: music.flatMap(SlideshowVideo.musicDuration))
        let player = SlideshowPlayer(app: self, assets: assets, settings: slideshowSettings, slideSeconds: seconds)
        slideshowPlayer = player
        player.show()
    }

    func slideshowEnded() { slideshowPlayer = nil }

    /// A photo as slideshow videos, web galleries and books render it: its original, with its
    /// develop settings; nil without a local original — never the cached preview of an offline
    /// one, too small for a printed page or a 4K frame. Those are left out, and said so.
    func renderItem(for asset: Asset) -> PrintItem? {
        guard !asset.isVideo, asset.status == .ready, let path = asset.localPath else { return nil }
        return PrintItem(sourcePath: path, isRaw: asset.isRaw,
                         develop: developSettings[asset.id] ?? .neutral,
                         originalSize: CGSize(width: asset.width, height: asset.height),
                         filename: asset.filename, title: asset.title, caption: asset.caption)
    }

    /// Says that `count` photos were left out of a slideshow video, web gallery or book because
    /// their originals are offline or missing.
    private func noteOriginalsLeftOut(_ count: Int) {
        guard count > 0 else { return }
        push("原件离线而未包含的照片：\(count) 张", "warning")
    }

    /// Writes the slideshow as an MP4 video at `url`: the photos with a local original, rendered
    /// with their develop settings at the video's size, and the music.
    func exportSlideshowVideo(to url: URL) {
        guard slideshowExportProgress == nil else { return }
        let settings = slideshowSettings
        let shown = slideshowOrder(presentationAssets(), settings: settings)
        let slides = shown.compactMap { asset -> SlideshowSlide? in
            guard let item = renderItem(for: asset) else { return nil }
            return SlideshowSlide(item: item, caption: settings.caption.text(for: asset))
        }
        guard !slides.isEmpty else {
            push("这些照片没有可用的本地原件", "warning")
            return
        }
        sheet = nil
        noteOriginalsLeftOut(shown.count - slides.count)
        let music = slideshowMusic(settings)
        let seconds = settings.slideSeconds(fitting: slides.count, toMusic: music.flatMap(SlideshowVideo.musicDuration))
        let timeline = SlideshowTimeline(count: slides.count, slide: seconds, fade: settings.fadeSeconds, repeats: false)
        let frames = Int((timeline.duration * Double(SlideshowVideo.framesPerSecond)).rounded())
        var initial = BackgroundTask(kind: .exportPhotos, title: L("导出幻灯片视频"), state: .running,
                                     totalCount: frames, destination: url)
        initial.detail = L("照片 \(slides.count) 张 · 视频帧 \(frames)")
        runArtifactExport(initial, progress: \.slideshowExportProgress, cancellation: \.slideshowCancellation,
                          failureMessage: L("幻灯片视频未能导出"), work: { progress, cancelled in
            SlideshowVideo.export(slides, settings: settings, slideSeconds: seconds, music: music, to: url,
                                  progress: progress, cancelled: cancelled) ? url : nil
        }, done: { app, url in
            app.push(verbatim: L("幻灯片视频已导出：\(url.lastPathComponent)"), "check")
        })
    }

    /// Makes a slideshow video, web gallery or book in the background: the task `initial` in the
    /// task center, how far it has got in `progress`, its cancellation in `cancellation` (one
    /// each, so they can run at once). `work` makes it, reporting progress and checking for
    /// cancellation, and gives back where it is; `done` says so.
    private func runArtifactExport(_ initial: BackgroundTask,
                                   progress: ReferenceWritableKeyPath<AppState, Double?>,
                                   cancellation flag: ReferenceWritableKeyPath<AppState, CancellationFlag?>,
                                   failureMessage: String,
                                   work: @escaping @Sendable (_ progress: @escaping @Sendable (Double) -> Void,
                                                              _ cancelled: @escaping @Sendable () -> Bool) -> URL?,
                                   done: @escaping (AppState, URL) -> Void) {
        let cancellation = CancellationFlag()
        self[keyPath: flag] = cancellation
        self[keyPath: progress] = 0
        let originHistory = taskHistory
        if let originHistory {
            recordBackgroundTask(initial, originHistory: originHistory, actions: .init(cancel: { cancellation.set() }))
        }
        Task { [weak self, originHistory, initial] in
            let owner = self
            let output = await Task.detached(priority: .userInitiated) {
                work({ fraction in
                    Task { @MainActor in
                        guard let self = owner, self[keyPath: flag] === cancellation, fraction.isFinite,
                              fraction >= (self[keyPath: progress] ?? 0) else { return }
                        self[keyPath: progress] = min(1, max(0, fraction))
                        if let originHistory {
                            self.recordArtifactExportProgress(initial, originHistory: originHistory, fraction: fraction)
                        }
                    }
                }, { cancellation.isSet })
            }.value
            guard let self else { return }
            if let originHistory {
                self.finishArtifactExportTask(initial, originHistory: originHistory, output: output,
                                              cancelled: cancellation.isSet, failureMessage: failureMessage)
            }
            guard self[keyPath: flag] === cancellation else { return }
            self[keyPath: progress] = nil
            self[keyPath: flag] = nil
            if let output {
                done(self, output)
            } else if !cancellation.isSet {
                self.push(verbatim: failureMessage, "warning")
            }
        }
    }

    // ----- web gallery (Lightroom's Web module) -----
    var canExportWebGallery: Bool { onboarded && sheet == nil && webGalleryProgress == nil && !list.isEmpty }

    func showWebGallery() {
        guard canExportWebGallery else { return }
        guard presentationAssets().contains(where: { renderItem(for: $0) != nil }) else {
            push("这些照片没有可用的本地原件", "warning")
            return
        }
        sheet = "webGallery"
    }

    /// The name a gallery of what's showing takes by default: the album, folder or collection.
    var webGalleryDefaultTitle: String { selection.name.isEmpty ? L("网页画廊") : selection.name }

    /// Camera, lens and exposure in a line, as under a photo opened in a web gallery.
    static func exposureDetails(_ asset: Asset) -> String {
        var parts: [String] = []
        if !asset.camera.isEmpty { parts.append(asset.camera) }
        if !asset.lens.isEmpty { parts.append(asset.lens) }
        var exposure: [String] = []
        if asset.focal > 0 { exposure.append("\(asset.focal) mm") }
        if asset.aperture > 0 { exposure.append(String(format: "ƒ/%g", asset.aperture)) }
        if !asset.shutter.isEmpty { exposure.append(asset.shutter.hasSuffix("s") ? asset.shutter : asset.shutter + " s") }
        if asset.iso > 0 { exposure.append("ISO \(asset.iso)") }
        if !exposure.isEmpty { parts.append(exposure.joined(separator: " · ")) }
        return parts.joined(separator: " · ")
    }

    /// Writes a web gallery of the photos with local originals into a new folder in `parent`,
    /// then shows it in the Finder.
    func exportWebGallery(to parent: URL) {
        guard webGalleryProgress == nil else { return }
        let settings = webGallerySettings
        let shown = presentationAssets()
        let photos = shown.compactMap { asset -> WebGalleryPhoto? in
            guard let item = renderItem(for: asset) else { return nil }
            let caption = settings.caption.text(for: asset)
            return WebGalleryPhoto(item: item,
                                   baseName: (asset.filename as NSString).deletingPathExtension,
                                   caption: caption, details: Self.exposureDetails(asset))
        }
        guard !photos.isEmpty else {
            push("这些照片没有可用的本地原件", "warning")
            return
        }
        sheet = nil
        noteOriginalsLeftOut(shown.count - photos.count)
        let name = settings.title.isEmpty ? webGalleryDefaultTitle : settings.title
        var initial = BackgroundTask(kind: .exportPhotos, title: L("导出网页画廊"), state: .running,
                                     totalCount: photos.count, destination: parent)
        initial.detail = L("输入照片 \(photos.count) 张")
        runArtifactExport(initial, progress: \.webGalleryProgress, cancellation: \.webGalleryCancellation,
                          failureMessage: L("网页画廊未能导出"), work: { progress, cancelled in
            WebGalleryExporter.export(photos, settings: settings, name: name, in: parent,
                                      progress: progress, cancelled: cancelled)
        }, done: { app, page in
            app.push(verbatim: L("网页画廊已导出：\(page.deletingLastPathComponent().lastPathComponent)"), "check")
            NSWorkspace.shared.activateFileViewerSelecting([page])
        })
    }

    // ----- photo book (Lightroom's Book module) -----
    var canMakeBook: Bool { onboarded && sheet == nil && bookProgress == nil && !list.isEmpty }

    /// The book's photos: those of `presentationAssets` with a local original, as they render.
    func bookItems(caption: BookSettings.Caption) -> [BookItem] {
        presentationAssets().compactMap { asset in
            guard let item = renderItem(for: asset) else { return nil }
            return BookItem(item: item, caption: caption.text(for: asset))
        }
    }

    func showBook() {
        guard canMakeBook else { return }
        guard !bookItems(caption: .none).isEmpty else {
            push("这些照片没有可用的本地原件", "warning")
            return
        }
        sheet = "book"
    }

    /// Asks where, then writes the book as a PDF there and shows it in the Finder.
    func saveBookPDF(_ settings: BookSettings) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (settings.title.isEmpty ? L("画册") : settings.title) + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        bookSettings = settings
        writeBook(settings, to: url)
    }

    func writeBook(_ settings: BookSettings, to url: URL) {
        let items = bookItems(caption: settings.caption)
        guard !items.isEmpty, bookProgress == nil else { return }
        sheet = nil
        noteOriginalsLeftOut(presentationAssets().count - items.count)
        let renderer = BookRenderer(items: items, settings: settings)
        let pageCount = renderer.pages.count
        var initial = BackgroundTask(kind: .exportPhotos, title: L("导出画册 PDF"), state: .running,
                                     totalCount: pageCount, destination: url)
        initial.detail = L("画册页数 \(pageCount)")
        runArtifactExport(initial, progress: \.bookProgress, cancellation: \.bookCancellation,
                          failureMessage: L("画册未能存储"), work: { progress, cancelled in
            renderer.writePDF(to: url, progress: progress, cancelled: cancelled) ? url : nil
        }, done: { app, url in
            app.push(verbatim: L("画册已存储：\(url.lastPathComponent)（\(pageCount) 页）"), "check")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        })
    }

    // ----- print: the selection on paper (Lightroom's Print module) -----
    private static let printQueue = DispatchQueue(label: "PhotoCatalog.print", qos: .userInitiated)

    /// The selection's photos with a local original, in list order, as they print.
    func printItems() -> [PrintItem] {
        renderedExportItems().compactMap { item in
            guard !item.isVideo, let asset = assetIndex[item.assetId].map({ assets[$0] }) else { return nil }
            return PrintItem(sourcePath: item.sourcePath, isRaw: item.isRaw, develop: item.develop,
                             originalSize: item.originalSize, filename: asset.filename, title: asset.title)
        }
    }

    var canPrint: Bool { canRenderedExport }

    func showPrint() {
        guard canPrint else {
            push(selectionTargetIds.isEmpty ? "请先选择照片" : "选中的照片没有可用的本地原件", "warning")
            return
        }
        sheet = "print"
    }

    /// Prints the selection with `settings` through the system print panel, drawing on a
    /// separate thread so RAW decoding never holds up the app.
    func printPhotos(_ settings: PrintSettings) {
        printSettings = settings
        let renderer = PrintRenderer(items: printItems(), settings: settings)
        guard renderer.pageCount > 0 else {
            push("没有可打印的照片（需要本地原件）", "warning")
            return
        }
        sheet = nil
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.paperSize = settings.paper.size
        info.orientation = settings.orientation == .portrait ? .portrait : .landscape
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        info.horizontalPagination = .clip
        info.verticalPagination = .clip
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        let operation = NSPrintOperation(view: PrintPagesView(renderer: renderer), printInfo: info)
        operation.jobTitle = L("PhotoCatalog 打印 \(renderer.items.count) 张照片")
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.canSpawnSeparateThread = true
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    /// Asks where, then writes the pages as a PDF in the background.
    func savePrintPDF(_ settings: PrintSettings) {
        printSettings = settings
        let renderer = PrintRenderer(items: printItems(), settings: settings)
        guard renderer.pageCount > 0 else {
            push("没有可打印的照片（需要本地原件）", "warning")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = L("打印") + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sheet = nil
        let pages = renderer.pageCount
        push("正在生成 PDF…", "printer")
        Self.printQueue.async { [weak self] in
            let written = renderer.writePDF(to: url)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if written {
                    self.push(verbatim: L("已存储 \(String(pages)) 页的 PDF"), "checkmark.circle")
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } else {
                    self.push("无法存储 PDF", "warning")
                }
            }
        }
    }

    /// Menu state: stops at the first photo with a local original.
    var canRenderedExport: Bool {
        guard onboarded, sheet == nil, view != .analysis else { return false }
        return selectionSummary.hasPrimaryOriginal
    }

    /// ⇧⌘E: the export dialog for the selection.
    func showRenderedExport() {
        guard canRenderedExport else {
            push(selectionTargetIds.isEmpty ? "请先选择照片" : "选中的照片没有可用的本地原件", "warning")
            return
        }
        sheet = "renderedExport"
    }

    /// Queues an export of the selection; jobs run one after another in the background.
    func startRenderedExport(settings: ExportSettings, folder: URL) {
        let items = renderedExportItems()
        guard !items.isEmpty else {
            push("没有可导出的照片（需要本地原件）", "warning")
            return
        }
        renderedExportSettings = settings
        renderedExportFolder = folder.path
        FileAccessService.reach(folder)
        let subfolder = settings.subfolder.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        let destination = subfolder.isEmpty ? folder : folder.appendingPathComponent(subfolder, isDirectory: true)
        let job = RenderedExportJob(items: items, settings: settings, folder: destination, history: taskHistory,
                                    originals: originalNames(in: destination))
        renderedExportJobs.append(job)
        recordRenderedExportTask(job, state: .queued)
        if renderedExportJobs.count == 1 {
            runNextRenderedExport()
        } else {
            renderedExportProgress?.queued = renderedExportJobs.count - 1
            push("已加入导出队列 · 前面还有 \(renderedExportJobs.count - 1) 个任务", "export")
        }
    }

    /// Stops the running export after the photos in progress and drops the queued ones.
    func cancelRenderedExport() {
        guard !renderedExportJobs.isEmpty else { return }
        for job in renderedExportJobs.dropFirst() { recordRenderedExportTask(job, state: .cancelled) }
        renderedExportJobs.removeSubrange(1...)
        renderedExportProgress?.queued = 0
        renderedExportCancellation.cancel()
    }

    private func runNextRenderedExport() {
        guard let job = renderedExportJobs.first else {
            renderedExportProgress = nil
            return
        }
        renderedExportProgress = RenderedExportProgress(done: 0, total: job.items.count,
                                                        queued: renderedExportJobs.count - 1)
        recordRenderedExportTask(job, state: .running)
        let cancellation = renderedExportCancellation
        cancellation.reset()
        Self.renderedExportQueue.async { [weak self] in
            let names = ExportNames(originals: job.originals)
            var written: [URL] = [], skipped = 0, failedCount = 0
            var failures: [BackgroundTask.Failure] = []
            var folderReady = true
            do {
                try FileManager.default.createDirectory(at: job.folder, withIntermediateDirectories: true)
            } catch {
                failures.append(.init(item: job.folder.lastPathComponent,
                                      message: L("无法创建导出文件夹：\(error.localizedDescription)"),
                                      path: job.folder.path))
                failedCount = 1
                folderReady = false
            }
            // two photos at once: one renders on the GPU while the other is encoded
            let lock = NSLock()
            var next = 0, done = 0
            DispatchQueue.concurrentPerform(iterations: folderReady ? min(2, job.items.count) : 0) { _ in
                while true {
                    let index: Int? = lock.withLock {
                        guard next < job.items.count, !cancellation.isCancelled else { return nil }
                        next += 1
                        return next - 1
                    }
                    guard let index else { return }
                    let outcome = RenderedExportService.export(job.items[index], sequence: job.settings.sequenceStart + index,
                                                               settings: job.settings, to: job.folder, names: names)
                    let snapshot = lock.withLock {
                        switch outcome {
                        case .written(let url): written.append(url)
                        case .skipped: skipped += 1
                        case .failed(let reason):
                            failedCount += 1
                            if failures.count == BackgroundTaskHistory.failureDetailLimit { failures.removeFirst() }
                            let item = job.items[index]
                            failures.append(.init(item: item.baseName, message: reason,
                                                  assetID: item.assetId, path: item.sourcePath))
                        }
                        done += 1
                        return (done: done, written: written.count, skipped: skipped,
                                failed: failedCount, failures: failures)
                    }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self, self.renderedExportJobs.first?.id == job.id,
                                  let progress = self.renderedExportProgress, progress.done <= snapshot.done else { return }
                            self.renderedExportProgress?.done = snapshot.done
                            self.recordRenderedExportTask(job, state: .running, done: snapshot.done,
                                written: snapshot.written, skipped: snapshot.skipped,
                                failedCount: snapshot.failed, failures: snapshot.failures)
                        }
                    }
                }
            }
            let cancelled = cancellation.isCancelled
            let spared = names.sparedOriginals
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.finishRenderedExport(job, done: done, written: written, skipped: skipped, spared: spared,
                                               failedCount: failedCount, failures: failures, cancelled: cancelled)
                }
            }
        }
    }

    private func finishRenderedExport(_ job: RenderedExportJob, done: Int, written: [URL], skipped: Int, spared: Int,
                                      failedCount: Int, failures: [BackgroundTask.Failure], cancelled: Bool) {
        let state: BackgroundTask.State = cancelled ? .cancelled : (failedCount > 0 ? .failed : .completed)
        recordRenderedExportTask(job, state: state, done: done, written: written.count,
                                 skipped: skipped, failedCount: failedCount, failures: failures)
        guard renderedExportJobs.first?.id == job.id else { return }
        renderedExportJobs.removeFirst()
        var message = cancelled ? L("导出已取消 · 已写入 \(written.count) 张") : L("已导出 \(written.count) 张照片")
        if skipped > 0 { message += L(" · \(skipped) 张已存在而跳过") }
        if spared > 0 { message += L(" · \(spared) 张与目录中的原件同名，已加编号而未覆盖原件") }
        if let first = failures.first { message += L(" · \(failedCount) 项失败（\(first.message)）") }
        push(verbatim: message, failures.isEmpty ? "export" : "warning")
        if job.settings.revealInFinder, !written.isEmpty, !cancelled {
            // selecting thousands of files is slow in Finder; open the folder instead
            if written.count <= 50 {
                NSWorkspace.shared.activateFileViewerSelecting(written)
            } else {
                NSWorkspace.shared.open(job.folder)
            }
        }
        runNextRenderedExport()
    }

    private func recordRenderedExportTask(_ job: RenderedExportJob, state: BackgroundTask.State,
                                          done: Int = 0, written: Int = 0, skipped: Int = 0,
                                          failedCount: Int = 0, failures: [BackgroundTask.Failure] = []) {
        guard let history = job.history else { return }
        var task = BackgroundTask(id: job.id, kind: .exportPhotos, title: L("导出照片"), state: state,
                                  createdAt: job.createdAt, totalCount: job.items.count, destination: job.folder)
        task.completedCount = done
        task.succeededCount = written
        task.skippedCount = skipped
        task.failedCount = failedCount
        task.failures = failures
        task.errorMessage = failures.first?.message
        let jobID = job.id
        let actions = BackgroundTask.Actions(cancel: { [weak self] in
            guard let self, self.renderedExportJobs.contains(where: { $0.id == jobID }) else { return }
            self.cancelRenderedExport()
        }, cancelTitle: L("取消整个导出队列"))
        recordBackgroundTask(task, originHistory: history, actions: actions)
    }

    func saveRenderedExportPreset(name: String, settings: ExportSettings) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let index = renderedExportPresets.firstIndex(where: { $0.name == name }) {
            renderedExportPresets[index].settings = settings
        } else {
            renderedExportPresets.append(RenderedExportPreset(id: UUID().uuidString, name: name, settings: settings))
        }
        push("已存储导出预设“\(name)”", "square.and.arrow.down")
    }

    func deleteRenderedExportPreset(_ id: String) {
        renderedExportPresets.removeAll { $0.id == id }
    }

    static func loadJSON<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        UserDefaults.app.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}
