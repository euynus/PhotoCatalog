import Foundation

enum CaptureAnalysisCheck {
    static func run() {
        let day = CaptureDates.interval(for: "2024-02-29")!
        let assets = checkAssets()
        let fixtures = Array(assets.prefix(5))
        let filter = Filters(date: "custom", dateStart: day.start, dateEnd: day.start)
        let matching = Set(fixtures.filter { filter.matchesCaptureDate($0.date) }.map(\.id))
        assert(matching == ["start", "end"], "date filter includes the entire final day, not next midnight")
        assert(CaptureDates.interval(for: "2023-02-29") == nil
               && CaptureDates.interval(for: "2024-13") == nil
               && CaptureDates.interval(for: "2024-02-30") == nil,
               "date keys reject invalid calendar dates")
        assert(CaptureDates.key(day.start) == "2024-02-29", "date keys use capture wall-clock")
        assert(CaptureDates.presetInterval("today", now: day.end)?.start == day.end
               && CaptureDates.presetInterval("yesterday", now: day.end)?.start == day.start
               && CaptureDates.presetInterval("last7Days", now: day.end)?.start == CaptureDates.interval(for: "2024-02-24")?.start
               && CaptureDates.presetInterval("last30Days", now: day.end)?.start == CaptureDates.interval(for: "2024-02-01")?.start,
               "relative date windows include today and cross leap-month boundaries")
        let invalid = Filters(date: "custom", dateStart: day.end, dateEnd: day.start)
        assert(!invalid.matchesCaptureDate(day.start), "reversed custom ranges match no photos")
        assert(!Filters(date: "custom").matchesCaptureDate(day.start), "incomplete custom ranges fail closed")
        let rule = SmartRule(conditions: filter.smartConditions(search: ""))
        assert(Set(SmartMatcher.match(fixtures, rule).map(\.id)) == matching,
               "saved date ranges match the live filter")

        let groups = CaptureDates.groups(assets)
        assert(groups.map(\.id) == ["2024", "2023"] && groups[0].count == 4,
               "date hierarchy counts years newest first and excludes deleted photos")
        assert(groups[0].children.map(\.id) == ["2024-03", "2024-02"]
               && groups[0].children[1].children.first?.count == 2,
               "date hierarchy groups by month and day")
        let stats = try! CaptureStatistics(assets: assets)
        assert(stats.totalCount == 5 && stats.dayCount == 4 && stats.completeCount == 4 && stats.fileDateCount == 1,
               "analysis separates missing metadata and file-date fallback")
        assert(stats.distributions.allSatisfy { $0.knownCount == 4 && $0.missingCount == 1 },
               "missing parameters do not appear as zero-valued samples")
        assert(stats.distributions.first { $0.parameter == .shutter }?.values.first?.count == 2,
               "equivalent fractional and decimal shutter values share a bucket")
        for invalidShutter in ["", "0", "-1", "1/0", "-1/-2", "1/2/3", "nan", "inf"] {
            assert(CaptureParameter.shutterSeconds(invalidShutter) == nil, "invalid exposure must be missing")
        }
        let empty = try! CaptureStatistics(assets: [])
        assert(empty.distributions.allSatisfy { $0.values.isEmpty && $0.missingCount == 0 },
               "empty analysis has no invented samples")

        checkDatabase(assets: assets, filter: filter, invalid: invalid, rule: rule, matching: matching)
        print("--- capture-date and parameter-analysis assertions passed ---")
    }

    @MainActor
    static func runAsync() async {
        let day = CaptureDates.interval(for: "2024-02-29")!.start
        await checkAppState(assets: checkAssets(), filter: Filters(date: "custom", dateStart: day, dateEnd: day))
        await checkCancellation()
        print("--- background-analysis assertions passed ---")
        if CommandLine.arguments.contains("--benchmark") {
            await benchmark()
        }
    }

    private static func checkAssets() -> [Asset] {
        let day = CaptureDates.interval(for: "2024-02-29")!
        var deleted = asset("deleted", at: day.start)
        deleted.deleted = true
        return [
            asset("before", at: day.start.addingTimeInterval(-1), shutter: "1/125"),
            asset("start", at: day.start, shutter: "0.008"),
            asset("end", at: day.end.addingTimeInterval(-0.001)),
            asset("after", at: day.end, shutter: "2.0"),
            asset("unknown", at: CaptureDates.interval(for: "2023-12-31")!.start, missing: true),
            deleted,
        ]
    }

    private static func checkDatabase(assets: [Asset], filter: Filters, invalid: Filters,
                                      rule: SmartRule, matching: Set<String>) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pc-analysis-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let store = try CatalogStore(packageURL: directory.appendingPathComponent("Check.photolibrary"))
            try store.upsert(assets)
            let filtered = try store.loadAssetPage(matching: AssetQuery(filters: filter), offset: 0, limit: 20)
            let smart = try store.loadAssetPage(matching: AssetQuery(scope: .smart(rule: rule)), offset: 0, limit: 20)
            assert(Set(filtered.assets.map(\.id)) == matching && Set(smart.assets.map(\.id)) == matching,
                   "SQLite date ranges and saved rules agree with in-memory filtering")
            let invalidPage = try store.loadAssetPage(matching: AssetQuery(filters: invalid), offset: 0, limit: 20)
            assert(invalidPage.totalCount == 0, "SQLite rejects reversed date ranges")
            for (key, expected) in [("2024", 4), ("2024-02", 3), ("2024-02-29", 2), ("invalid", 0)] {
                let page = try store.loadAssetPage(matching: AssetQuery(scope: .captureDate(key)), offset: 0, limit: 20)
                assert(page.totalCount == expected, "SQLite date classification uses the same boundaries")
            }
            let now = CaptureDates.interval(for: "2024-03-01")!.start
            for (preset, _) in CaptureDates.presets {
                let expected = Set(assets.filter { !$0.deleted && SmartMatcher.matchesDatePreset($0.date, preset, now: now) }.map(\.id))
                let page = try store.loadAssetPage(matching: AssetQuery(filters: Filters(date: preset), referenceDate: now),
                                                  offset: 0, limit: 20)
                assert(Set(page.assets.map(\.id)) == expected, "relative date presets agree across memory and SQLite")
            }
        } catch {
            preconditionFailure("capture-date database check failed: \(error)")
        }
    }

    @MainActor
    private static func checkAppState(assets: [Asset], filter: Filters) async {
        let app = AppState.selfCheckFixture()
        func load(selectedOnly: Bool = false) async -> CaptureStatistics {
            let request = app.captureStatisticsRequest(selectedOnly: selectedOnly)
            await app.loadCaptureStatistics(for: request)
            guard let result = app.captureStatistics(for: request) else {
                preconditionFailure("current analysis request must publish a result")
            }
            return result
        }
        app.assets = assets
        app.duplicateGroupsCache = [DuplicateGroup(id: "check-stack", method: "contentHash", score: 1,
                                                   items: Array(assets[1...2]))]
        app.select(Selection(type: .captureDate, id: "2024-02", name: "2024-02"))
        let originalRequest = app.captureStatisticsRequest(selectedOnly: false)
        assert(app.captureStatistics(for: originalRequest) == nil, "reading analysis never computes in the view body")
        var statistics = await load()
        assert(app.list.count == 3 && statistics.totalCount == 3,
               "date navigation scopes both photos and statistics")
        app.setFilters(filter)
        assert(app.captureStatistics(for: originalRequest) == nil, "old filter results are hidden immediately")
        statistics = await load()
        assert(app.list.count == 2 && statistics.totalCount == 2,
               "statistics refresh when date filters change")
        app.toggleStack(containing: "start")
        statistics = await load()
        assert(app.list.count == 1 && statistics.totalCount == 2,
               "collapsed stacks do not hide samples from analysis")
        app.selectedIds = [app.list[0].id]
        statistics = await load(selectedOnly: true)
        assert(statistics.totalCount == 1, "selected-only analysis respects selection")
        app.setSearch("no matching filename")
        statistics = await load()
        assert(statistics.totalCount == 0, "search filters analysis")
        app.setSearch("")
        let oldCount = app.captureDateGroups[0].count
        var changed = assets
        changed[2].deleted = true
        app.assets = changed
        statistics = await load()
        assert(app.captureDateGroups[0].count == oldCount - 1
               && statistics.totalCount == 1,
               "date hierarchy and analysis caches refresh after metadata changes")
        app.switchView(.analysis)
        assert(app.handleKey("delete", hasCommand: true),
               "analysis consumes the destructive shortcut instead of forwarding it to the native menu")
    }

    @MainActor
    private static func checkCancellation() async {
        let app = AppState.selfCheckFixture()
        let sample = asset("background", at: Date(timeIntervalSince1970: 0))
        app.assets = (0..<100_000).map { asset("background-\($0)", at: sample.date) }
        app.duplicateGroupsCache = []
        _ = app.list
        let oldRequest = app.captureStatisticsRequest(selectedOnly: false)
        var started = false
        var finished = false
        let oldTask = Task { @MainActor in
            started = true
            await app.loadCaptureStatistics(for: oldRequest)
            finished = true
        }
        while !started { await Task.yield() }
        assert(!finished, "main actor must resume while aggregation is still running")

        app.assets = [sample]
        let newRequest = app.captureStatisticsRequest(selectedOnly: false)
        await app.loadCaptureStatistics(for: newRequest)
        await oldTask.value
        assert(app.captureStatistics(for: newRequest)?.totalCount == 1
               && app.captureStatistics(for: oldRequest) == nil,
               "late old work cannot replace a newer asset snapshot")
        await app.loadCaptureStatistics(for: oldRequest)
        assert(app.captureStatistics(for: newRequest)?.totalCount == 1,
               "an already stale request must not cancel or overwrite the current result")

        app.selectedIds = [sample.id]
        let selectedRequest = app.captureStatisticsRequest(selectedOnly: true)
        let cancelled = Task { @MainActor in await app.loadCaptureStatistics(for: selectedRequest) }
        cancelled.cancel()
        await cancelled.value
        assert(app.captureStatistics(for: selectedRequest) == nil,
               "view-task cancellation must not publish a result")
        await app.loadCaptureStatistics(for: selectedRequest)
        assert(app.captureStatistics(for: selectedRequest)?.totalCount == 1,
               "a new request can run after cancellation")
        let loading = AppState(arguments: [], deferCatalogLoading: true)
        let loadingRequest = loading.captureStatisticsRequest(selectedOnly: false)
        await loading.loadCaptureStatistics(for: loadingRequest)
        assert(loading.isLoadingCatalog && loading.captureStatistics(for: loadingRequest) == nil,
               "catalog loading must not publish partial analysis")

        let (gate, continuation) = AsyncStream<Void>.makeStream()
        let aggregate = Task.detached {
            for await _ in gate {}
            return try CaptureStatistics(assets: [sample])
        }
        aggregate.cancel()
        continuation.finish()
        do {
            _ = try await aggregate.value
            assertionFailure("cancelled aggregation must throw, not return partial counts")
        } catch is CancellationError {} catch {
            assertionFailure("unexpected aggregation error: \(error)")
        }
    }

    private static func asset(_ id: String, at date: Date, shutter: String = "1/250", missing: Bool = false) -> Asset {
        Asset(id: id, pid: 0, ori: "l", thumb: "", preview: "", filename: "\(id).jpg", type: "JPG", isRaw: false,
              folderId: "check", folderName: "Check", date: date, width: 600, height: 400, orientation: 1,
              camera: missing ? " " : "Camera", lens: missing ? "" : "Lens", focal: missing ? 0 : 35,
              aperture: missing ? .nan : 2.8, shutter: missing ? "1/0" : shutter, iso: missing ? 0 : 400,
              colorSpace: "sRGB", fileMB: 1, rating: 0, flag: .none, keywords: [], title: "", caption: "",
              location: "", gps: (0, 0), status: .ready, importedAt: date,
              captureDateSource: missing ? "文件修改时间" : "EXIF · DateTimeOriginal")
    }

    @MainActor
    private static func benchmark() async {
        let start = CaptureDates.interval(for: "2020-01-01")!.start
        let samples = (0..<100_000).map { index in
            asset("benchmark-\(index)", at: start.addingTimeInterval(Double(index % 3_650) * 86_400))
        }
        let app = AppState.selfCheckFixture()
        app.albums = []
        app.smartAlbums = []
        app.duplicateGroupsCache = []
        let filter = Filters(date: "custom", dateStart: start,
                             dateEnd: CaptureDates.interval(for: "2029-12-31")!.start)
        var results: [String: [Double]] = [:]
        func measure(_ name: String, _ work: () async -> Void) async {
            let begin = ProcessInfo.processInfo.systemUptime
            await work()
            results[name, default: []].append((ProcessInfo.processInfo.systemUptime - begin) * 1_000)
        }
        for _ in 0..<3 {
            app.assets = samples
            await measure("date tree") {
                precondition(app.captureDateGroups.reduce(0) { $0 + $1.count } == samples.count)
            }
            await measure("date filter") {
                app.setFilters(filter)
                precondition(app.list.count == samples.count)
            }
            await measure("analysis") {
                let request = app.captureStatisticsRequest(selectedOnly: false)
                await app.loadCaptureStatistics(for: request)
                precondition(app.captureStatistics(for: request)?.totalCount == samples.count)
            }
            app.selectedIds = Set(samples.prefix(10).map(\.id))
            await measure("selected analysis") {
                let request = app.captureStatisticsRequest(selectedOnly: true)
                await app.loadCaptureStatistics(for: request)
                precondition(app.captureStatistics(for: request)?.totalCount == 10)
            }
        }
        for name in ["date tree", "date filter", "analysis", "selected analysis"] {
            let median = results[name]!.sorted()[1]
            print("100k \(name): \(median.formatted(.number.precision(.fractionLength(1)))) ms median (3 runs)")
        }
    }
}
