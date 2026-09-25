// ============================================================
//  Camera / iPhone import — devices on a cable, read over PTP
// ============================================================
import Foundation
import ImageCaptureCore
import ImageIO
import UniformTypeIdentifiers

/// A camera or phone connected by cable. It speaks PTP instead of mounting as a volume, so its
/// photos are listed and downloaded through ImageCaptureCore.
struct CameraDevice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// An iPhone or iPad rather than a camera (for its icon).
    let isPhone: Bool
}

/// Fetches one device photo to a local file.
protocol CameraFileSource: Sendable {
    func download(to destination: URL) throws
}

/// Device photos are named by paths under `root` — `/<root>/<device id>/<camera folders>/<file>`.
/// Nothing lives there: an import stages each photo at the same relative path in a folder on
/// the destination volume, so a RAW and its JPEG still share a folder and base name.
enum CameraDevicePaths {
    static let root = URL(fileURLWithPath: "/PhotoCatalog Devices", isDirectory: true)

    static func url(device: String, folders: [String], name: String) -> URL {
        folders.reduce(root.appendingPathComponent(device, isDirectory: true)) {
            $0.appendingPathComponent($1, isDirectory: true)
        }.appendingPathComponent(name)
    }

    /// Where a listed photo is staged under `staging`.
    static func staged(_ url: URL, in staging: URL) -> URL {
        let relative = String(url.path.dropFirst(root.path.count + 1))
        return staging.appendingPathComponent(relative)
    }
}

/// What opening a device produced.
enum CameraListing: Sendable {
    case files([CardFile])
    /// A locked iPhone, or one that hasn't trusted this Mac yet.
    case locked
    case unavailable
}

/// Downloads each device photo as the import reaches it, then copies it into place exactly as
/// a card photo (dated folders, renaming, backup). The staged download is removed afterwards.
final class DeviceFileFetcher: ImportFilePreparer, @unchecked Sendable {
    private let sources: [String: any CameraFileSource]
    private let copier: CardCopier

    /// `sources` are keyed by staged path.
    init(sources: [String: any CameraFileSource], copier: CardCopier) {
        self.sources = sources
        self.copier = copier
    }

    func isAvailable(_ source: URL) -> Bool { sources[source.path] != nil }

    func prepare(_ staged: URL) throws -> URL {
        guard let source = sources[staged.path] else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try source.download(to: staged)
        defer { try? FileManager.default.removeItem(at: staged) }
        return try copier.copy(staged)
    }
}

/// Watches for cameras and phones, and lists, previews and downloads their photos. Device
/// callbacks arrive on arbitrary queues and are handed to the main actor.
@MainActor
final class CameraDeviceBrowser: NSObject {
    static let shared = CameraDeviceBrowser()

    /// Called whenever devices come or go.
    var onChange: (([CameraDevice]) -> Void)?
    private(set) var devices: [CameraDevice] = []
    private let browser = ICDeviceBrowser()
    private var cameras: [String: ICCameraDevice] = [:]
    private var catalogWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    /// Files of the listings handed out so far, by listed path.
    private var listed: [String: ICCameraFile] = [:]
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(
            rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue) ?? .camera
        browser.start()
    }

    /// Opens a session, waits until the device has catalogued its contents, and lists its
    /// photos oldest first (videos and sidecars are left out).
    func listing(for device: CameraDevice, catalog: CardImportService.CatalogIndex) async -> CameraListing {
        guard let camera = cameras[device.id] else { return .unavailable }
        if !camera.hasOpenSession {
            do { try await camera.requestOpenSession() } catch { return .unavailable }
        }
        if camera.contentCatalogPercentCompleted < 100 {
            // a phone lists thousands of photos slowly; don't wait forever on one that stalls
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(90))
                self?.catalogReady(device.id)
            }
            await withCheckedContinuation { continuation in
                catalogWaiters[device.id, default: []].append(continuation)
            }
        }
        guard cameras[device.id] != nil else { return .unavailable }
        if camera.isAccessRestrictedAppleDevice { return .locked }
        let files = (camera.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }.compactMap { file -> CardFile? in
            let type = file.uti.flatMap(UTType.init)
            guard let type, type.conforms(to: .image) else { return nil }
            let url = CameraDevicePaths.url(device: device.id, folders: Self.folders(of: file), name: file.name ?? "")
            listed[url.path] = file
            let size = Int64(file.fileSize)
            let taken = file.exifCreationDate ?? file.creationDate ?? file.modificationDate ?? .distantPast
            var card = CardFile(url: url, size: size, modified: taken,
                                isRaw: file.isRaw || type.conforms(to: .rawImage), deviceID: device.id)
            card.alreadyImported = catalog.contains(name: card.name, size: size, captured: file.exifCreationDate)
            return card
        }
        return .files(files.sorted { ($0.modified, $0.name) < ($1.modified, $1.name) })
    }

    /// The device's embedded preview for a listed photo.
    func thumbnail(for url: URL) async -> CGImage? {
        guard let file = listed[url.path] else { return nil }
        let data: Data? = await withCheckedContinuation { continuation in
            file.requestThumbnailData(options: [.imageSourceThumbnailMaxPixelSize: 240]) { data, _ in
                continuation.resume(returning: data)
            }
        }
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Download sources for listed photos, keyed by `stagedPath(file)`.
    func sources(for files: [CardFile], stagedPath: (CardFile) -> String) -> [String: any CameraFileSource] {
        var sources: [String: any CameraFileSource] = [:]
        for file in files {
            if let item = listed[file.url.path] { sources[stagedPath(file)] = CameraFileDownload(file: item) }
        }
        return sources
    }

    /// Ends the session once an import is done (or the dialog closed without one).
    func close(_ device: CameraDevice) {
        guard let camera = cameras[device.id], camera.hasOpenSession else { return }
        camera.requestCloseSession()
        listed = listed.filter { !$0.key.hasPrefix(CameraDevicePaths.root.appendingPathComponent(device.id).path) }
    }

    func eject(_ device: CameraDevice) {
        guard let camera = cameras[device.id], camera.isEjectable else { return }
        camera.requestEject()
    }

    private static func folders(of item: ICCameraItem) -> [String] {
        var names: [String] = []
        var folder = item.parentFolder
        while let current = folder {
            if let name = current.name, !name.isEmpty { names.insert(name, at: 0) }
            folder = current.parentFolder
        }
        return names
    }

    private func added(_ device: ICDevice) {
        guard let camera = device as? ICCameraDevice, let id = camera.uuidString else { return }
        camera.delegate = self
        cameras[id] = camera
        publish()
    }

    private func removed(_ device: ICDevice) {
        guard let id = device.uuidString else { return }
        cameras[id] = nil
        catalogReady(id)
        publish()
    }

    private func catalogReady(_ id: String) {
        catalogWaiters.removeValue(forKey: id)?.forEach { $0.resume() }
    }

    private func publish() {
        devices = cameras.map { id, camera in
            let kind = (camera.productKind ?? "").lowercased()
            return CameraDevice(id: id, name: camera.name ?? L("相机"),
                                isPhone: kind.contains("iphone") || kind.contains("ipad") || kind.contains("phone"))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        onChange?(devices)
    }
}

extension CameraDeviceBrowser: ICDeviceBrowserDelegate, ICCameraDeviceDelegate {
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        let box = DeviceBox(device)
        Task { @MainActor in self.added(box.device) }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        let box = DeviceBox(device)
        Task { @MainActor in self.removed(box.device) }
    }

    nonisolated func didRemove(_ device: ICDevice) {
        let box = DeviceBox(device)
        Task { @MainActor in self.removed(box.device) }
    }

    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        guard error != nil, let id = device.uuidString else { return }
        Task { @MainActor in self.catalogReady(id) }   // nothing more is coming
    }

    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}

    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        guard let id = device.uuidString else { return }
        Task { @MainActor in self.catalogReady(id) }
    }

    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        guard let id = device.uuidString else { return }
        Task { @MainActor in self.catalogReady(id) }   // locked: the listing reports it
    }

    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?,
                                  for item: ICCameraItem, error: Error?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?,
                                  for item: ICCameraItem, error: Error?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
}

/// Carries a device object from ImageCaptureCore's queue to the main actor.
private struct DeviceBox: @unchecked Sendable {
    let device: ICDevice
    init(_ device: ICDevice) { self.device = device }
}

/// Downloads one camera file, blocking the import worker until the device delivers it.
private final class CameraFileDownload: CameraFileSource, @unchecked Sendable {
    let file: ICCameraFile

    init(file: ICCameraFile) { self.file = file }

    func download(to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        let done = DispatchSemaphore(value: 0)
        let result = DownloadResult()
        let options: [ICDownloadOption: Any] = [.downloadsDirectoryURL: directory,
                                                .saveAsFilename: destination.lastPathComponent,
                                                .overwrite: true]
        DispatchQueue.main.async {
            _ = self.file.requestDownload(options: options) { filename, error in
                result.set(filename: filename, error: error)
                done.signal()
            }
        }
        // a device that goes away mid-transfer may never call back
        guard done.wait(timeout: .now() + 600) == .success else { throw CocoaError(.fileReadUnknown) }
        let (filename, error) = result.value
        if let error { throw error }
        if let filename, filename != destination.lastPathComponent {
            try FileManager.default.moveItem(at: directory.appendingPathComponent(filename), to: destination)
        }
        guard FileManager.default.fileExists(atPath: destination.path) else { throw CocoaError(.fileNoSuchFile) }
    }
}

private final class DownloadResult: @unchecked Sendable {
    private let lock = NSLock()
    private var filename: String?
    private var error: Error?

    func set(filename: String?, error: Error?) {
        lock.withLock {
            self.filename = filename
            self.error = error
        }
    }

    var value: (String?, Error?) { lock.withLock { (filename, error) } }
}
