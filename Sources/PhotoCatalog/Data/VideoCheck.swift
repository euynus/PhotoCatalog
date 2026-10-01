import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Videos: metadata, poster frames, import into a catalog, filters, the photo-only actions
/// they stay out of, export, and their sidecars.
enum VideoCheck {
    static func run() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pc-video-\(UUID().uuidString)")
        let source = folder.appendingPathComponent("source")
        try? FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let created = Date(timeIntervalSince1970: 1_743_651_920)   // 2025-04-03 03:45:20 UTC
        let clip = source.appendingPathComponent("CLIP.MOV"), turned = source.appendingPathComponent("TURNED.mov")
        guard makeVideo(at: clip, created: created, quarterTurn: false),
              makeVideo(at: turned, created: created, quarterTurn: true) else {
            assertionFailure("test movies are written")
            return
        }
        checkMetadata(clip, turned, created: created)
        MainActor.assumeIsolated { checkCatalog(source, in: folder) }
        checkHelpers(in: folder)
        print("--- video assertions passed ---")
    }

    /// A 2-second 160 × 90 H.264 movie at 10 fps: red for its first second, blue after, made by
    /// "Canon EOS R6m2" at `created` (optionally turned a quarter to play upright as 90 × 160).
    static func makeVideo(at url: URL, created: Date, quarterTurn: Bool) -> Bool {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
        func item(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            return item
        }
        writer.metadata = [item(.quickTimeMetadataCreationDate, ISO8601DateFormatter().string(from: created)),
                           item(.quickTimeMetadataMake, "Canon"), item(.quickTimeMetadataModel, "Canon EOS R6m2"),
                           item(.quickTimeMetadataLocationISO6709, "+31.2304+121.4737+004.000/")]
        let width = 160, height = 90
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        if quarterTurn { input.transform = CGAffineTransform(rotationAngle: .pi / 2) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<20 {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            guard let pool = adaptor.pixelBufferPool else { return false }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { return false }
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            let (r, g, b): (UInt8, UInt8, UInt8) = frame < 10 ? (220, 30, 30) : (30, 30, 220)
            for y in 0..<height {
                for x in 0..<width {
                    let i = y * rowBytes + x * 4
                    base[i] = b; base[i + 1] = g; base[i + 2] = r; base[i + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        return writer.status == .completed
    }

    private static func checkMetadata(_ clip: URL, _ turned: URL, created: Date) {
        let meta = MetadataReader.read(clip)
        let wallClock = created.addingTimeInterval(Double(TimeZone.current.secondsFromGMT(for: created)))
        assert(meta.width == 160 && meta.height == 90 && meta.orientation == 1 && abs((meta.duration ?? 0) - 2) < 0.05,
               "a movie's size and length are read (\(meta.width)×\(meta.height), \(String(describing: meta.duration)))")
        assert(meta.camera == "Canon EOS R6m2" && meta.captureDate == wallClock && meta.captureDateSource == "视频创建时间",
               "and its camera, and its creation time as this Mac's wall clock (\(meta.camera), \(meta.captureDate))")
        assert(meta.hasGPS && abs(meta.gps.0 - 31.2304) < 1e-6 && abs(meta.gps.1 - 121.4737) < 1e-6 && meta.gpsAltitude == 4,
               "and where it was shot")
        let upright = MetadataReader.read(turned)
        assert(upright.width == 90 && upright.height == 160, "a movie turned to play upright is as tall as it plays")

        let frame = VideoMetadata.frame(clip, maxPixel: 64)
        var red = 0, blue = 255
        if let frame, let pixels = SoftProofing.rgba(frame) {
            let i = ((frame.height / 2) * frame.width + frame.width / 2) * 4
            red = Int(pixels[i])
            blue = Int(pixels[i + 2])
        }
        let small = frame.map { max($0.width, $0.height) <= 64 } == true
        assert(small && red > 150 && blue < 100,
               "the poster frame comes from early in the movie, at most the size asked (\(red), \(blue))")
        assert(VideoMetadata.frame(turned, maxPixel: 64).map { $0.height > $0.width } == true, "and is turned as it plays")
    }

    @MainActor
    private static func checkCatalog(_ source: URL, in folder: URL) {
        // a photo beside the movies
        let photo = source.appendingPathComponent("PHOTO.jpg")
        let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let destination = CGImageDestinationCreateWithURL(photo as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)

        guard let store = try? CatalogStore(packageURL: folder.appendingPathComponent("Videos.photolibrary")) else {
            assertionFailure("a catalog opens")
            return
        }
        let imported = ImportCoordinator(store: store).importFolder(source)
        let video = imported.first { $0.filename == "CLIP.MOV" }
        assert(imported.count == 3 && video?.isVideo == true && video?.isRaw == false && video?.type == "MOV"
               && abs((video?.duration ?? 0) - 2) < 0.05 && imported.first { $0.filename == "PHOTO.jpg" }?.isVideo == false,
               "movies import beside photos, as videos with their length")
        assert(video.map { FileManager.default.fileExists(atPath: $0.thumb) && FileManager.default.fileExists(atPath: $0.preview) } == true
               && video?.perceptualHash != nil, "with a thumbnail, a preview and a perceptual hash from the poster frame")
        try? store.upsert(imported)
        let reloaded = (try? store.loadAssetPage())?.assets.first { $0.filename == "CLIP.MOV" }
        assert(reloaded?.duration == video?.duration && reloaded?.isVideo == true, "a video's length survives the catalog")
        var query = AssetQuery()
        query.filters.type = "VIDEO"
        let sqlVideos = (try? store.loadAssetPage(matching: query))?.assets.map(\.filename).sorted()
        assert(sqlVideos == ["CLIP.MOV", "TURNED.mov"], "the catalog's video filter finds the movies (\(String(describing: sqlVideos)))")
        let rule = SmartRule(match: "all", conditions: [SmartCondition(field: "type", op: "=", value: "VIDEO")])
        assert(imported.filter { SmartMatcher.matches($0, rule) }.count == 2, "and so does a smart album")

        let app = AppState.selfCheckFixture()
        app.assets = imported
        app.filters.type = "VIDEO"
        assert(Set(app.list.map(\.filename)) == ["CLIP.MOV", "TURNED.mov"], "the filter bar's video type shows the movies")
        app.filters = Filters()
        guard let clip = video, let still = imported.first(where: { !$0.isVideo }) else { return }
        assert(!app.canDevelop(clip) && app.canDevelop(still), "videos can't be developed")
        app.selectedIds = Set(imported.map(\.id))
        app.primaryId = clip.id
        let exportItems = app.renderedExportItems()
        assert(app.photoMergeCandidates().map(\.id) == [still.id] && app.printItems().map(\.filename) == ["PHOTO.jpg"]
               && exportItems.filter(\.isVideo).count == 2 && app.externalEditJobs(imported).count == 1,
               "merging, printing and outside editors take the photo only; export takes everything")

        // in the loupe, Space plays or pauses a video and zoom leaves it alone; a photo still goes back to the grid
        app.view = .loupe
        app.setPrimary(clip.id)
        let before = app.videoPlaybackToggle
        _ = app.handleKey(" ", hasCommand: false)
        _ = app.toggleZoom()
        assert(app.view == .loupe && app.videoPlaybackToggle == before + 1 && app.loupeZoom == nil,
               "Space plays a video in the loupe, and zoom doesn't apply")
        app.setPrimary(still.id)
        _ = app.handleKey(" ", hasCommand: false)
        assert(app.view == .grid && app.videoPlaybackToggle == before + 1, "on a photo Space still returns to the grid")
        app.selectedIds = Set(imported.map(\.id))
        app.primaryId = clip.id

        // export copies a video's original under the template's name
        let out = folder.appendingPathComponent("export")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var settings = ExportSettings()
        settings.fileNameTemplate = "{original}-{seq}"
        var reserved = Set<String>()
        guard let item = exportItems.first(where: { $0.assetId == clip.id }),
              case .written(let written) = RenderedExportService.export(item, sequence: 3, settings: settings, to: out,
                                                                        reserved: &reserved) else {
            assertionFailure("a video exports")
            return
        }
        assert(written.lastPathComponent == "CLIP-0003.MOV"
               && FileManager.default.contentsEqual(atPath: written.path, andPath: source.appendingPathComponent("CLIP.MOV").path),
               "a video exports as its original, renamed (\(written.lastPathComponent))")
    }

    private static func checkHelpers(in folder: URL) {
        let side = folder.appendingPathComponent("sidecars")
        try? FileManager.default.createDirectory(at: side, withIntermediateDirectories: true)
        for name in ["ALONE.MOV", "LIVE.MOV", "LIVE.HEIC"] {
            FileManager.default.createFile(atPath: side.appendingPathComponent(name).path, contents: Data())
        }
        assert(XMPSidecar.sidecarURL(for: side.appendingPathComponent("ALONE.MOV")).lastPathComponent == "ALONE.xmp"
               && XMPSidecar.sidecarURL(for: side.appendingPathComponent("LIVE.MOV")).lastPathComponent == "LIVE.MOV.xmp"
               && XMPSidecar.sidecarURL(for: side.appendingPathComponent("LIVE.HEIC")).lastPathComponent == "LIVE.xmp",
               "a video's sidecar is <name>.xmp, unless a photo of the same name owns that one")
        let canon = Data([0, 0, 0, 0, 0x15, 0xC7]) + Data("Canon EOS R6m2".utf8) + Data([0])
        assert(VideoMetadata.userDataString(canon) == "Canon EOS R6m2" && VideoMetadata.userDataString(Data([1, 2])) == "",
               "MP4 user-data strings are read past their header, and short ones are ignored")
        let place = VideoMetadata.iso6709("-33.8688+151.2093/")
        assert(place?.latitude == -33.8688 && place?.longitude == 151.2093 && place?.altitude == nil
               && VideoMetadata.iso6709("+95.0+10.0/") == nil, "ISO 6709 locations parse, and impossible ones don't")
        assert(Asset.clock(23.4) == "0:23" && Asset.clock(725) == "12:05" && Asset.clock(3729) == "1:02:09",
               "lengths read as a clock")
    }
}
