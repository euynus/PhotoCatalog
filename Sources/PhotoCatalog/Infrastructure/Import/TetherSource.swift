// ============================================================
//  Tether sources — where a tethered session's shots come from: a camera or a watched folder
// ============================================================
import Foundation

/// A shot that has arrived: what the camera named it, and how to put the file where the
/// session wants it (a move for a watched folder, a download for a camera).
struct TetherShot: Sendable {
    let originalName: String
    let deliver: @Sendable (URL) throws -> Void
}

/// Hands a tethered session each new shot. A source only reports and delivers; naming,
/// importing and showing the shot are the session's.
@MainActor
protocol TetherSource: AnyObject {
    /// What the session's bar calls it: the camera, or the folder.
    var name: String { get }
    /// Whether the app can release the shutter.
    var canCapture: Bool { get }
    /// Starts reporting shots; `onEnd` says why the source went away (a camera unplugged, a
    /// folder gone). False when it can't start.
    func start(onShot: @escaping @MainActor (TetherShot) -> Void, onEnd: @escaping @MainActor (String) -> Void) -> Bool
    func stop()
    func capture()
}

/// Auto import: shots another app (EOS Utility, a camera's own tether software) saves into a
/// folder. Files already there when the session starts are left alone; a new file is taken
/// once its size has held still for a moment, since tether software writes a file in pieces.
@MainActor
final class FolderTetherSource: TetherSource {
    let folder: URL
    var name: String { folder.lastPathComponent }
    var canCapture: Bool { false }

    private var watcher: FileWatcher?
    private var timer: Timer?
    private var onShot: (@MainActor (TetherShot) -> Void)?
    private var onEnd: (@MainActor (String) -> Void)?
    /// Files seen: present at the start, already handed on, or growing (their last size).
    private var handled: Set<String> = []
    private var sizes: [String: Int64] = [:]

    init(folder: URL) { self.folder = folder }

    func start(onShot: @escaping @MainActor (TetherShot) -> Void, onEnd: @escaping @MainActor (String) -> Void) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        self.onShot = onShot
        self.onEnd = onEnd
        handled = Set(files().map(\.path))
        let watcher = FileWatcher(paths: [folder.path], latency: 0.3) { [weak self] _ in
            MainActor.assumeIsolated { self?.scan() }
        }
        watcher.start()
        self.watcher = watcher
        // FSEvents can coalesce; a slow look every second catches a file still being written
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scan() }
        }
        return true
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        timer?.invalidate()
        timer = nil
        onShot = nil
        onEnd = nil
    }

    func capture() {}

    /// The supported photos directly in the folder, hidden and partial files left out.
    private func files() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey],
                                                                      options: [.skipsHiddenFiles])) ?? []
        return contents.filter { FileScanner.isSupported($0) && !$0.lastPathComponent.hasPrefix(".") }
    }

    /// Hands on each new file whose size is the same as at the last look.
    func scan() {
        guard let onShot else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            let end = onEnd
            stop()
            end?(L("监视的文件夹已不可用"))
            return
        }
        for file in files().sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where !handled.contains(file.path) {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            guard size > 0, sizes[file.path] == size else {
                sizes[file.path] = size
                continue
            }
            handled.insert(file.path)
            sizes[file.path] = nil
            onShot(TetherShot(originalName: file.lastPathComponent) { destination in
                try FileManager.default.moveItem(at: file, to: destination)
            })
        }
    }
}

/// A camera on a cable, through ImageCaptureCore's tethering: each shot it reports is
/// downloaded straight into the session's folder under the session's name for it.
@MainActor
final class CameraTetherSource: TetherSource {
    let device: CameraDevice
    var name: String { device.name }
    var canCapture: Bool { CameraDeviceBrowser.shared.canCapture(device) }

    init(device: CameraDevice) { self.device = device }

    func start(onShot: @escaping @MainActor (TetherShot) -> Void, onEnd: @escaping @MainActor (String) -> Void) -> Bool {
        CameraDeviceBrowser.shared.beginTethering(device, onShot: onShot) { onEnd(L("相机已断开")) }
    }

    func stop() { CameraDeviceBrowser.shared.endTethering(device) }

    func capture() { CameraDeviceBrowser.shared.capture(device) }
}
