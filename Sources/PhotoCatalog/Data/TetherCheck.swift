import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Tethered capture: shots are named for the session (a RAW and its JPEG alike, numbering
/// picked up where the folder left off), imported one at a time in order with the session's
/// preset and keywords, filed under the session's folder and shown; a watched folder hands on a
/// file only once it's whole. The camera itself is stood in for by a source that delivers
/// local files, as the ImageCaptureCore one delivers downloads.
@MainActor
enum TetherCheck {
    static func run(_ check: (Bool, String) -> Void) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("pc-tether-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let fixture = tmp.appendingPathComponent("fixture.jpg")
        writeImage(fixture, seed: 1)

        checkNaming(check)
        checkSession(check, tmp: tmp, fixture: fixture)
        checkFolderSource(check, tmp: tmp, fixture: fixture)
    }

    private static func checkNaming(_ check: (Bool, String) -> Void) {
        var namer = TetherNamer(session: "Studio", naming: .sessionSequence, existing: ["Studio-0003.CR3", "notes.txt"])
        let names = ["IMG_0101.CR3", "IMG_0101.JPG", "IMG_0102.CR3", "IMG_0101.CR3"].map { namer.name(for: $0) }
        check(names == ["Studio-0004.CR3", "Studio-0004.JPG", "Studio-0005.CR3", "Studio-0006.CR3"],
              "tethered shots: numbered after the folder's, a RAW and its JPEG alike, a repeated camera name anew")
        var original = TetherNamer(session: "Studio", naming: .original, existing: ["IMG_0001.JPG"])
        check(original.name(for: "IMG_0001.JPG") == "IMG_0001_1.JPG" && original.name(for: "IMG_0002.JPG") == "IMG_0002.JPG",
              "tethered shots keep the camera's names, a taken one with _1")
        var settings = TetherSettings()
        settings.sessionName = " a/b:c "
        let defaults = try? JSONDecoder().decode(TetherSettings.self, from: Data("{}".utf8))
        check(settings.folderName() == "a-b-c" && TetherSettings().folderName().contains("20")
              && defaults == TetherSettings(), "a session's folder is its name, or the day's date")
    }

    /// Stands in for a camera: each shot "downloads" by copying a local file.
    private final class SimulatedCamera: TetherSource {
        let fixture: URL
        var name: String { "Simulated EOS" }
        var canCapture: Bool { true }
        var onShot: (@MainActor (TetherShot) -> Void)?
        var onEnd: (@MainActor (String) -> Void)?
        var counter = 900
        var stopped = false

        init(fixture: URL) { self.fixture = fixture }

        func start(onShot: @escaping @MainActor (TetherShot) -> Void, onEnd: @escaping @MainActor (String) -> Void) -> Bool {
            self.onShot = onShot
            self.onEnd = onEnd
            return true
        }

        func stop() { stopped = true }

        func capture() { shoot() }

        func shoot() {
            counter += 1
            let fixture = fixture
            onShot?(TetherShot(originalName: "IMG_\(counter).JPG") { try FileManager.default.copyItem(at: fixture, to: $0) })
        }

        func unplug() { onEnd?(L("相机已断开")) }
    }

    private static func spin(_ timeout: Double = 20, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    private static func checkSession(_ check: (Bool, String) -> Void, tmp: URL, fixture: URL) {
        let fm = FileManager.default
        guard let store = try? CatalogStore(packageURL: tmp.appendingPathComponent("Tether.photolibrary")) else {
            return check(false, "tethered capture: scratch catalog")
        }
        let app = AppState.selfCheckFixture(importingInto: store)
        app.runsBackgroundMaintenance = false
        let previousSettings = app.tetherSettings
        defer { app.tetherSettings = previousSettings }
        let preset = DevelopPreset.builtIns.first!
        var settings = TetherSettings()
        settings.sessionName = "Studio"
        settings.destinationPath = tmp.appendingPathComponent("Sessions").path
        settings.naming = .sessionSequence
        settings.presetId = preset.id
        settings.keywords = "studio, tether"
        let camera = SimulatedCamera(fixture: fixture)
        let folder = tmp.appendingPathComponent("Sessions/Studio").standardizedFileURL
        check(app.startTether(settings, source: camera) && app.tether?.folder.path == folder.path && app.tether?.canCapture == true
              && fm.fileExists(atPath: folder.path), "a tethered session starts with its folder")
        check(!app.startTether(settings, source: SimulatedCamera(fixture: fixture)), "one session at a time")

        // a burst: two shots at once arrive in order
        camera.shoot()
        camera.shoot()
        func inSession() -> [Asset] {
            app.assets.filter { $0.localPath?.hasPrefix(folder.path) == true }.sorted { $0.filename < $1.filename }
        }
        spin { inSession().count == 2 && app.tether?.working == false }
        let shots = inSession()
        check(shots.map(\.filename) == ["Studio-0001.JPG", "Studio-0002.JPG"]
              && shots.allSatisfy { fm.fileExists(atPath: $0.localPath ?? "") }, "tethered shots land in the session's folder under its name, in order")
        check(shots.allSatisfy { $0.keywords.contains("studio") && $0.keywords.contains("tether") }
              && shots.allSatisfy { app.developSettings[$0.id].map { !$0.isNeutral } == true },
              "each shot gets the session's keywords and preset")
        let roots = (try? store.loadSourceRoots()) ?? []
        let reloaded = Set(((try? store.loadAssets()) ?? []).map(\.id))
        check(roots.contains { URL(fileURLWithPath: $0.pathHint).standardizedFileURL.path == folder.path }
              && app.folders.contains { $0.id == shots[0].folderId } && reloaded.isSuperset(of: shots.map(\.id)),
              "the session's folder becomes a source folder and its shots are saved")
        check(app.primaryId == shots[1].id && app.selection.type == .folder && app.selection.id == shots[0].folderId
              && app.view == .loupe && app.tether?.shots == 2 && app.tether?.lastName == "Studio-0002.JPG",
              "the newest shot is shown, in the loupe")

        // the shutter, then a shot after the preset is taken off
        camera.capture()
        spin { inSession().count == 3 && app.tether?.working == false }
        app.setTetherPreset("")
        camera.shoot()
        spin { inSession().count == 4 && app.tether?.working == false }
        let later = inSession()
        check(later.count == 4 && later[2].filename == "Studio-0003.JPG" && app.developSettings[later[3].id] == nil,
              "capturing takes a shot, and a preset changed mid-session applies to the next shots")

        // the camera unplugged ends the session; the folder is watched from then on
        camera.unplug()
        check(app.tether == nil && camera.stopped && app.watchedFolderPaths.contains(folder.path),
              "a camera unplugged ends the session, and its folder is watched like an imported one")

        // the same session picked up again numbers on
        let again = SimulatedCamera(fixture: fixture)
        check(app.startTether(settings, source: again), "a session can be picked up again")
        again.shoot()
        spin { inSession().count == 5 && app.tether?.working == false }
        check(inSession().last?.filename == "Studio-0005.JPG", "a session picked up again goes on from its last number")
        app.endTether()

        // a session's folder inside a source folder is filed under that folder
        let coordinator = ImportCoordinator(store: store)
        let inside = tmp.appendingPathComponent("Sessions/Inside")
        try? fm.createDirectory(at: inside, withIntermediateDirectories: true)
        let file = inside.appendingPathComponent("Inside-0001.JPG")
        try? fm.copyItem(at: fixture, to: file)
        let filed = coordinator.importFiles([file], from: inside, readSidecar: false, sourceRootId: "src-parent", folderName: "Sessions")
        check(filed.first?.folderId == "src-parent" && filed.first?.folderName == "Sessions",
              "shots in a folder inside a source folder belong to that source folder")
    }

    private static func checkFolderSource(_ check: (Bool, String) -> Void, tmp: URL, fixture: URL) {
        let fm = FileManager.default
        let watched = tmp.appendingPathComponent("Watched")
        try? fm.createDirectory(at: watched, withIntermediateDirectories: true)
        try? fm.copyItem(at: fixture, to: watched.appendingPathComponent("OLD.JPG"))
        let source = FolderTetherSource(folder: watched)
        var arrived: [TetherShot] = []
        var ended: String?
        check(source.start(onShot: { arrived.append($0) }, onEnd: { ended = $0 }) && !source.canCapture,
              "a watched folder starts as a source")
        // a file still being written, a hidden one and one of another kind
        let data = (try? Data(contentsOf: fixture)) ?? Data()
        let growing = watched.appendingPathComponent("IMG_0001.JPG")
        try? data.prefix(data.count / 2).write(to: growing)
        try? data.write(to: watched.appendingPathComponent(".IMG_0002.JPG"))
        try? Data("x".utf8).write(to: watched.appendingPathComponent("notes.txt"))
        source.scan()
        check(arrived.isEmpty, "a file is taken only once its size holds still")
        try? data.write(to: growing)
        source.scan()
        source.scan()
        check(arrived.map(\.originalName) == ["IMG_0001.JPG"], "files there before, hidden files and other kinds are left alone")
        let moved = tmp.appendingPathComponent("moved.jpg")
        try? arrived.first?.deliver(moved)
        check(fm.fileExists(atPath: moved.path) && !fm.fileExists(atPath: growing.path), "a watched folder's shot is moved out of it")

        // the folder's events (or the slow look) find a new file without being asked
        try? fm.copyItem(at: fixture, to: watched.appendingPathComponent("IMG_0003.JPG"))
        spin(10) { arrived.count == 2 }
        check(arrived.last?.originalName == "IMG_0003.JPG", "a new file in the watched folder is noticed")
        try? fm.removeItem(at: watched)
        source.scan()
        check(ended != nil, "a watched folder that goes away ends the session")
        source.stop()
    }

    private static func writeImage(_ url: URL, seed: Int) {
        guard let context = CGContext(data: nil, width: 320, height: 240, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return }
        context.setFillColor(CGColor(red: 0.2 + Double(seed % 5) / 10, green: 0.5, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
        context.setFillColor(CGColor(red: 0.9, green: 0.8, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 40, y: 40, width: 120, height: 80))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
