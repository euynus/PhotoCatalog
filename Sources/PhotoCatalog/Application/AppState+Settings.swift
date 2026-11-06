import AppKit
import Foundation

@MainActor
extension AppState {
    // ----- settings (PRD §17) -----
    /// The import preset, while it still exists.
    var importDevelopPreset: DevelopPreset? {
        importDevelopPresetId.isEmpty ? nil : allDevelopPresets.first { $0.id == importDevelopPresetId }
    }

    var recentCutoff: Date { Date().addingTimeInterval(-86400 * Double(max(1, recentImportDays))) }
    /// The limit that applies, as Settings shows it: the chosen one, or the automatic one for the
    /// cache's last measured size.
    var effectiveCacheLimitMB: Int { cacheLimit.megabytes(cacheBytes: statusMetrics.cacheBytes ?? 0) }
    /// What the limit is worked out from; a backfill or a prune does that once, as it starts.
    var cacheLimit: CacheLimit {
        var photos = assets.reduce(0) { $1.isDemo || $1.deleted ? $0 : $0 + 1 }
        // while a catalog is still loading, `assets` holds only part of it
        if isLoadingCatalog, let total = loadingCatalogTotalCount { photos = max(photos, total) }
        return CacheLimit(chosenMB: cacheLimitMB, photos: photos, previewMaxPixel: previewMaxPixel,
                          volume: store?.packageURL)
    }
    var automaticBackupFrequency: String {
        get { automaticBackupFrequencyStorage }
        set {
            automaticBackupFrequencyStorage = Self.normalizedAutomaticBackupFrequency(newValue)
            UserDefaults.app.set(automaticBackupFrequencyStorage, forKey: "pc_autoBackupFrequency")
        }
    }

    // ----- catalog (real persistence / scanning) -----
    static let catalogURLKey = "pc_catalogURL"
    static let recentCatalogsKey = "pc_recentCatalogs"
    static let lastAutoBackupKey = "pc_lastAutoBackupAt"
    static let pinnedSidebarItemsKey = "pc_pinnedSidebarItems"
    static let sourcePrioritiesKey = "pc_sourcePriorities"
    static let previewMaxPixelKey = "pc_previewMaxPixel"
    static let catalogPreviewPageSize = 240

    static func normalizedAutomaticBackupFrequency(_ value: String) -> String {
        ["off", "daily", "weekly"].contains(value) ? value : "weekly"
    }

    // ---------- updates ----------
    /// The version in the app bundle ("1.0" outside one).
    static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }

    /// Looks for a newer release on request and offers to install it.
    func checkForUpdates() {
        guard !Distribution.isAppStore else { return }
        Task { [weak self] in
            let outcome = await UpdateChecker.check(currentVersion: Self.appVersion)
            guard let self else { return }
            switch outcome {
            case .newer(let release):
                self.offerUpdate(release, automatic: false)
            case .upToDate:
                let alert = NSAlert()
                alert.messageText = L("PhotoCatalog 已是最新版本")
                alert.informativeText = L("当前版本 \(Self.appVersion)。")
                alert.runModal()
            case .unavailable:
                let alert = NSAlert()
                alert.messageText = L("暂时无法检查更新")
                alert.informativeText = L("请检查网络连接后再试。")
                alert.runModal()
            }
        }
    }

    /// The daily check: quiet unless there's a newer release the user hasn't chosen to skip.
    func checkForUpdatesAutomatically() {
        guard autoCheckForUpdates, !Distribution.isAppStore else { return }
        let defaults = UserDefaults.app
        let last = defaults.object(forKey: "pc_lastUpdateCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 20 * 3600 else { return }
        Task { [weak self] in
            // let the window settle first
            try? await Task.sleep(for: .seconds(5))
            let outcome = await UpdateChecker.check(currentVersion: Self.appVersion)
            guard let self else { return }
            if outcome != .unavailable { defaults.set(Date(), forKey: "pc_lastUpdateCheck") }
            guard case .newer(let release) = outcome, release.version != defaults.string(forKey: "pc_skippedVersion"),
                  self.sheet == nil, self.installingUpdate == nil else { return }
            self.offerUpdate(release, automatic: true)
        }
    }

    /// Whether this copy can install `release` itself: it's published as an archive, this app is
    /// signed so a genuine update can be told apart, and its folder is writable.
    func canInstallUpdate(_ release: UpdateChecker.Release) -> Bool {
        release.archive != nil && UpdateInstaller.runningRequirement() != nil && UpdateInstaller.canReplace(Bundle.main.bundleURL)
    }

    private func offerUpdate(_ release: UpdateChecker.Release, automatic: Bool) {
        let installable = canInstallUpdate(release)
        let alert = NSAlert()
        alert.messageText = L("PhotoCatalog \(release.version) 已发布")
        if installable {
            alert.informativeText = L("当前版本 \(Self.appVersion)。现在下载并安装，完成后 PhotoCatalog 会重新启动。")
            alert.addButton(withTitle: L("安装并重新启动"))
        } else {
            alert.informativeText = L("当前版本 \(Self.appVersion)。下载新版本后替换应用程序文件夹中的旧版本即可。")
            alert.addButton(withTitle: L("前往下载"))
        }
        alert.addButton(withTitle: L("稍后"))
        if automatic { alert.addButton(withTitle: L("跳过此版本")) }
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if installable { installUpdate(release) } else { NSWorkspace.shared.open(release.htmlURL) }
        case .alertThirdButtonReturn:
            UserDefaults.app.set(release.version, forKey: "pc_skippedVersion")
        default:
            break
        }
    }

    /// Downloads `release`, checks that it carries this app's signature, puts it in this app's
    /// place and relaunches; on any failure the running copy is left as it was.
    func installUpdate(_ release: UpdateChecker.Release) {
        guard installingUpdate == nil, let archive = release.archive?.downloadURL,
              let requirement = UpdateInstaller.runningRequirement(),
              let identifier = Bundle.main.bundleIdentifier else { return }
        guard !importing else {
            push("导入完成后再安装更新", "info")
            return
        }
        installingUpdate = release.version
        push("正在下载 PhotoCatalog \(release.version)…", "arrow.down.circle")
        let current = Bundle.main.bundleURL
        let staging = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoCatalog/Update", isDirectory: true)
        Task { [weak self] in
            do {
                let app = try await UpdateInstaller.prepare(archive: archive, version: release.version, identifier: identifier,
                                                            requirement: requirement, staging: staging)
                try UpdateInstaller.install(app, replacing: current)
                try? FileManager.default.removeItem(at: staging)
                UpdateInstaller.relaunch(current)
                NSApp.terminate(nil)
            } catch {
                guard let self else { return }
                self.installingUpdate = nil
                let alert = NSAlert()
                alert.messageText = L("未能安装更新")
                alert.informativeText = Self.updateFailureMessage(error as? UpdateInstaller.Failure)
                alert.addButton(withTitle: L("前往下载"))
                alert.addButton(withTitle: L("好"))
                if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.htmlURL) }
            }
        }
    }

    nonisolated static func updateFailureMessage(_ failure: UpdateInstaller.Failure?) -> String {
        switch failure {
        case .download: L("下载没有完成，请检查网络连接后再试。")
        case .unpack, .notTheApp: L("下载的文件不是这个版本的 PhotoCatalog。")
        case .untrusted: L("下载的应用没有与当前应用相同的签名，为安全起见没有安装。")
        case .replace, nil: L("无法替换应用程序文件夹中的 PhotoCatalog。当前版本没有改动。")
        }
    }

    // ---------- crash reports ----------
    /// After an unexpected quit, points to the report macOS saved. Only the app calls this.
    func checkForCrashReport() {
        // a sandboxed copy can't read the reports; the App Store collects them instead
        guard !Distribution.isAppStore, let bundleID = Bundle.main.bundleIdentifier else { return }
        // macOS writes the report some seconds after the crash; a quick reopen would miss it
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            self?.presentNewCrashReport(bundleID: bundleID)
        }
    }

    private func presentNewCrashReport(bundleID: String) {
        let key = "pc_crashReportsCheckedAt"
        let checked = UserDefaults.app.object(forKey: key) as? Date
        UserDefaults.app.set(Date(), forKey: key)
        // the first launch with this check only sets the mark; older reports aren't news
        guard let checked, let report = CrashReports.find(bundleID: bundleID, since: checked).first else { return }
        let alert = NSAlert()
        alert.messageText = L("PhotoCatalog 上次意外退出")
        alert.informativeText = L("macOS 保存了一份崩溃报告，只在这台 Mac 上。把它发给开发者有助于修复问题。")
        alert.addButton(withTitle: L("在访达中显示"))
        alert.addButton(withTitle: L("好"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([report])
        }
    }

    // ---------- language ----------
    /// Stores the language and offers to relaunch, since the interface switches at launch.
    func changeLanguage(_ language: AppLanguage) {
        guard language != self.language else { return }
        self.language = language
        let alert = NSAlert()
        alert.messageText = L("重新启动 PhotoCatalog 以切换语言？")
        alert.informativeText = L("界面语言会在下次启动时生效。")
        let canRelaunch = Bundle.main.bundlePath.hasSuffix(".app")
        if canRelaunch { alert.addButton(withTitle: L("立即重新启动")) }
        alert.addButton(withTitle: canRelaunch ? L("稍后") : L("好"))
        guard alert.runModal() == .alertFirstButtonReturn, canRelaunch else { return }
        // reopen once this process has exited, so two copies never hold the catalog at once
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
        reopen.arguments = ["-c", "while kill -0 \"$0\" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open \"$1\"",
                            String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        guard (try? reopen.run()) != nil else { return }
        NSApp.terminate(nil)
    }
}
