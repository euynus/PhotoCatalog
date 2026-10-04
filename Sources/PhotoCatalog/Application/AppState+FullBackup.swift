import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class FullBackupState {
    enum Operation: String, CaseIterable, Identifiable, Sendable {
        case backup, verify, restore
        var id: String { rawValue }
        var title: String {
            switch self {
            case .backup: return L("创建完整备份")
            case .verify: return L("校验完整备份")
            case .restore: return L("恢复到新库")
            }
        }
    }

    enum Status: Equatable { case idle, running, completed, failed, cancelled }

    var operation: Operation = .backup
    var backupURL: URL?
    var destinationDirectory: URL?
    var backupName = "PhotoCatalog-" + Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash))
    var restoredLibraryName = "PhotoCatalog-Restored"
    fileprivate(set) var runID: UUID?
    fileprivate(set) var activeOperation: Operation?
    fileprivate(set) var status: Status = .idle
    fileprivate(set) var progress: FullBackupService.Progress?
    fileprivate(set) var report: FullBackupService.Report?
    fileprivate(set) var errorMessage: String?
    fileprivate(set) var sourceURL: URL?
    fileprivate(set) var destinationURL: URL?
    fileprivate(set) var startedAt: Date?
    fileprivate(set) var finishedAt: Date?
    fileprivate(set) var isCancelRequested = false

    /// Optional task-center integration. Inputs and outcomes stay owned by this engine.
    @ObservationIgnored var onChange: ((FullBackupState) -> Void)?
    @ObservationIgnored fileprivate var cancellation: CancellationFlag?
    @ObservationIgnored fileprivate var worker: Task<Void, Never>?
    @ObservationIgnored fileprivate var backupAccess: FullBackupAccess?
    @ObservationIgnored fileprivate var destinationAccess: FullBackupAccess?

    var isRunning: Bool { status == .running }
    var targetURL: URL? {
        guard operation != .verify, let destinationDirectory else { return nil }
        let name = (operation == .backup ? backupName : restoredLibraryName).trimmingCharacters(in: .whitespaces)
        guard FullBackupFiles.validComponent(name) else { return nil }
        let suffix = operation == .backup ? "photobackup" : "photolibrary"
        let filename = name.lowercased().hasSuffix("." + suffix) ? name : name + "." + suffix
        return destinationDirectory.appendingPathComponent(filename, isDirectory: true)
    }

    var progressTitle: String {
        switch progress?.phase {
        case .snapshot: return L("正在快照目录库")
        case .copying: return L("正在复制原片与编辑资源")
        case .verifying: return L("正在校验文件与 SHA-256")
        case .restoring: return L("正在恢复到新目录库")
        case .complete: return L("已完成")
        case nil: return L("正在准备")
        }
    }

    func clearResult() {
        guard !isRunning else { return }
        status = .idle
        report = nil
        errorMessage = nil
        progress = nil
    }

    fileprivate func begin(source: URL, destination: URL?) -> (UUID, CancellationFlag) {
        let id = UUID(), flag = CancellationFlag()
        runID = id
        activeOperation = operation
        sourceURL = source
        destinationURL = destination
        status = .running
        report = nil
        errorMessage = nil
        progress = nil
        startedAt = .now
        finishedAt = nil
        isCancelRequested = false
        cancellation = flag
        onChange?(self)
        return (id, flag)
    }

    fileprivate func finish(_ outcome: FullBackupOutcome, runID: UUID) {
        guard self.runID == runID, isRunning else { return }
        switch outcome {
        case .success(let report):
            self.report = report
            let total = report.originalCount + report.sidecarCount + report.configurationCount + report.lutCount + report.fillCount + 2
            progress = FullBackupService.Progress(phase: .complete, completedFiles: total, totalFiles: total, bytes: report.bytes)
            status = .completed
        case .cancelled: status = .cancelled
        case .failure(let message): errorMessage = message; status = .failed
        }
        finishedAt = .now
        cancellation = nil
        worker = nil
        onChange?(self)
    }
}

extension AppState {
    func openFullBackup(_ operation: FullBackupState.Operation = .backup) {
        if !fullBackup.isRunning, fullBackup.operation != operation {
            fullBackup.operation = operation
            fullBackup.clearResult()
        }
        sheet = "fullBackup"
    }

    var fullBackupUnavailableReason: String? {
        if fullBackup.isRunning { return L("完整备份任务仍在运行") }
        if importing { return L("导入期间无法运行完整备份任务") }
        if isLoadingCatalog { return L("目录库加载期间无法运行完整备份任务") }
        if fullBackup.operation == .backup && store == nil { return L("未打开目录库") }
        if fullBackup.operation != .backup && fullBackup.backupURL == nil { return L("未选择完整备份") }
        if fullBackup.operation != .verify {
            if fullBackup.destinationDirectory == nil { return L("未选择目标文件夹") }
            if fullBackup.targetURL == nil { return L("名称不能为空，也不能包含路径分隔符") }
        }
        return nil
    }

    func chooseFullBackupSource() {
        guard !fullBackup.isRunning else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.treatsFilePackagesAsDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("选择完整备份")
        panel.message = L("完整备份文件夹（.photobackup）")
        panel.directoryURL = fullBackup.backupURL?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url, !fullBackup.isRunning else { return }
        fullBackup.backupAccess = FullBackupAccess(urls: [url])
        fullBackup.backupURL = url
        fullBackup.clearResult()
    }

    func chooseFullBackupDestination() {
        guard !fullBackup.isRunning else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.treatsFilePackagesAsDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("选择目标文件夹")
        panel.directoryURL = fullBackup.destinationDirectory
        guard panel.runModal() == .OK, let url = panel.url, !fullBackup.isRunning else { return }
        fullBackup.destinationAccess = FullBackupAccess(urls: [url])
        fullBackup.destinationDirectory = url
        fullBackup.clearResult()
    }

    func startFullBackup() {
        guard fullBackupUnavailableReason == nil else { return }
        let state = fullBackup, operation = state.operation
        let sourceStore = operation == .backup ? store : nil
        guard let source = sourceStore?.packageURL ?? state.backupURL else { return }
        let destination = state.targetURL
        let (runID, cancellation) = state.begin(source: source, destination: destination)
        var accessURLs = [source]
        do {
            if let sourceStore {
                for root in try sourceStore.loadSourceRoots() {
                    let resolved = root.bookmarkData.flatMap { FileAccessService.resolveBookmark($0)?.url }
                    accessURLs.append(resolved ?? URL(fileURLWithPath: root.pathHint, isDirectory: true))
                }
            }
        } catch {
            state.finish(.failure(fullBackupFailureMessage(error)), runID: runID)
            return
        }
        let retainedAccess = [FullBackupAccess(urls: accessURLs), state.backupAccess, state.destinationAccess].compactMap { $0 }
        state.worker = Task { [weak state] in
            let outcome = await Task.detached(priority: .utility) { [weak state] () -> FullBackupOutcome in
                defer { withExtendedLifetime(retainedAccess) {} }
                var lastPhase: FullBackupService.Phase?, lastUpdate: TimeInterval = 0
                let update: (FullBackupService.Progress) -> Void = { progress in
                    let now = ProcessInfo.processInfo.systemUptime
                    guard progress.phase != lastPhase || now - lastUpdate >= 0.1
                            || progress.completedFiles == progress.totalFiles else { return }
                    lastPhase = progress.phase
                    lastUpdate = now
                    Task { @MainActor [weak state] in
                        guard let state, state.runID == runID, state.isRunning else { return }
                        state.progress = progress
                        state.onChange?(state)
                    }
                }
                do {
                    let report: FullBackupService.Report
                    switch operation {
                    case .backup:
                        guard let sourceStore, let destination else { return .failure(L("未打开目录库")) }
                        report = try FullBackupService.backup(sourceStore, to: destination,
                                                              cancellation: cancellation, progress: update)
                    case .verify:
                        report = try FullBackupService.verify(source, cancellation: cancellation, progress: update)
                    case .restore:
                        guard let destination else { return .failure(L("未选择目标文件夹")) }
                        report = try FullBackupService.restore(source, to: destination,
                                                               cancellation: cancellation, progress: update)
                    }
                    return .success(report)
                } catch is CancellationError { return .cancelled }
                catch { return .failure(fullBackupFailureMessage(error)) }
            }.value
            state?.finish(outcome, runID: runID)
        }
    }

    func cancelFullBackup(runID: UUID? = nil) {
        guard fullBackup.isRunning, runID == nil || runID == fullBackup.runID else { return }
        fullBackup.isCancelRequested = true
        fullBackup.cancellation?.set()
        fullBackup.onChange?(fullBackup)
    }

    func revealFullBackupResult() {
        guard fullBackup.status == .completed, let url = fullBackup.report?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

fileprivate enum FullBackupOutcome: Sendable {
    case success(FullBackupService.Report), cancelled, failure(String)
}

/// Each successful start has a matching stop, independent of AppState closing its catalog.
fileprivate final class FullBackupAccess: @unchecked Sendable {
    private let urls: [URL]
    init(urls: [URL]) { self.urls = urls.filter { $0.startAccessingSecurityScopedResource() } }
    deinit { for url in urls { url.stopAccessingSecurityScopedResource() } }
}

private func fullBackupFailureMessage(_ error: Error) -> String {
    guard let error = error as? FullBackupError else { return error.localizedDescription }
    switch error {
    case .targetExists(let path): return L("目标已存在，未覆盖：\(path)")
    case .unsafePath(let path): return L("不安全的路径或符号链接：\(path)")
    case .missingFile(let path): return L("缺少必要的备份文件：\(path)")
    case .sourceChanged(let path): return L("文件在操作期间发生变化：\(path)")
    case .integrityMismatch(let path): return L("文件大小或 SHA-256 校验失败：\(path)")
    case .invalidManifest(let reason): return L("完整备份清单无效：\(reason)")
    case .invalidCatalog(let reason): return L("完整备份目录库无效：\(reason)")
    }
}
