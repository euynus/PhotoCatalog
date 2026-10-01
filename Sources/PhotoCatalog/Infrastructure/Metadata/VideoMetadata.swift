// ============================================================
//  VideoMetadata — what the import reads from a movie, and the frame its thumbnails show
// ============================================================
import AVFoundation
import CoreGraphics
import Foundation

enum VideoMetadata {
    static func isVideo(_ url: URL) -> Bool { Asset.videoTypes.contains(url.pathExtension.uppercased()) }

    /// What AVFoundation reports about a movie.
    private struct Info: Sendable {
        var size = CGSize.zero
        var duration: Double?
        var created: Date?
        var make = ""
        var model = ""
        var location: String?
    }

    /// Fills `m` from the movie at `url`: its size as it plays (turned by its track's
    /// transform), its length, when it was shot, the camera and the place. The movie's creation
    /// time is an instant; like a photo's, the capture time is kept as the wall clock it showed,
    /// here this Mac's time zone at that moment (a movie doesn't record the camera's own). False
    /// when AVFoundation can't read it.
    static func read(_ url: URL, into m: inout ScannedMetadata) -> Bool {
        let asset = AVURLAsset(url: url)
        guard let info = wait({ () async -> Info? in
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
            var info = Info()
            let turned = CGRect(origin: .zero, size: natural).applying(transform)
            info.size = CGSize(width: abs(turned.width), height: abs(turned.height))
            info.duration = (try? await asset.load(.duration)).map(\.seconds).flatMap { $0.isFinite ? $0 : nil }
            if let item = try? await asset.load(.creationDate) { info.created = try? await item.load(.dateValue) }
            for format in (try? await asset.load(.availableMetadataFormats)) ?? [] {
                for item in (try? await asset.loadMetadata(for: format)) ?? [] {
                    let key = item.identifier?.rawValue ?? ""
                    switch item.identifier {
                    case .quickTimeMetadataMake?, .commonIdentifierMake?:
                        info.make = (try? await item.load(.stringValue)) ?? info.make
                    case .quickTimeMetadataModel?, .commonIdentifierModel?:
                        info.model = (try? await item.load(.stringValue)) ?? info.model
                    case .quickTimeMetadataLocationISO6709?, .commonIdentifierLocation?:
                        info.location = (try? await item.load(.stringValue)) ?? info.location
                    default:
                        // MP4 user data (Canon): binary, see `userDataString`
                        if key.hasSuffix("/manu"), info.make.isEmpty {
                            info.make = userDataString((try? await item.load(.dataValue)) ?? nil)
                        } else if key.hasSuffix("/modl"), info.model.isEmpty {
                            info.model = userDataString((try? await item.load(.dataValue)) ?? nil)
                        }
                    }
                }
            }
            return info
        }), info.size.width > 0, info.size.height > 0 else { return false }

        m.width = Int(info.size.width.rounded())
        m.height = Int(info.size.height.rounded())
        m.orientation = 1   // the size is already turned as the movie plays
        m.duration = info.duration
        m.colorSpace = ""
        m.camera = MetadataReader.cameraName(make: info.make, model: info.model)
        if let created = info.created {
            m.captureDate = created.addingTimeInterval(Double(TimeZone.current.secondsFromGMT(for: created)))
            m.captureDateSource = "视频创建时间"
        } else if let created = m.fileCreatedAt {
            m.captureDate = created
            m.captureDateSource = "文件创建时间"
        } else {
            m.captureDate = m.fileModifiedAt ?? .now
            m.captureDateSource = "文件修改时间"
        }
        if let place = info.location.flatMap(iso6709) {
            m.gps = (place.latitude, place.longitude)
            m.gpsAltitude = place.altitude
            m.hasGPS = true
        }
        return true
    }

    /// A frame from early in the movie (a second in, or a tenth of a short one), turned as it
    /// plays and at most `maxPixel` on its long edge.
    static func frame(_ url: URL, maxPixel: Int) -> CGImage? {
        let asset = AVURLAsset(url: url)
        let duration = wait { () async -> Double? in (try? await asset.load(.duration)).map(\.seconds) } ?? 0
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        let seconds = duration.isFinite && duration > 0 ? min(1, duration / 10) : 0
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box<CGImage>()
        // completion-based, so nothing waits on the Swift concurrency pool
        generator.generateCGImageAsynchronously(for: CMTime(seconds: seconds, preferredTimescale: 600)) { image, _, _ in
            box.value = image
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 20) == .success else {
            generator.cancelAllCGImageGeneration()
            return nil
        }
        return box.value
    }

    /// AVFoundation's async loading, waited for from synchronous import code; nil after
    /// `timeout`, so a movie it can't read never holds an import up for good.
    private static func wait<T: Sendable>(timeout: TimeInterval = 20, _ work: @escaping @Sendable () async -> T?) -> T? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box<T>()
        Task.detached(priority: .userInitiated) {
            box.value = await work()
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.value
    }

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T?
        var value: T? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    /// An MP4 user-data string ('manu', 'modl'): a 4-byte header, a 2-byte language code, then
    /// UTF-8 up to a NUL. Empty when it's anything else.
    static func userDataString(_ data: Data?) -> String {
        guard let data, data.count > 6 else { return "" }
        let text = data.dropFirst(6).prefix { $0 != 0 }
        return String(decoding: text, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An ISO 6709 point, "+31.2304+121.4737+004.000/": latitude, longitude, maybe altitude.
    static func iso6709(_ text: String) -> (latitude: Double, longitude: Double, altitude: Double?)? {
        var numbers: [Double] = []
        var current = ""
        for character in text {
            if character == "+" || character == "-" || character == "/" {
                if let value = Double(current) { numbers.append(value) }
                current = character == "/" ? "" : String(character)
            } else {
                current.append(character)
            }
        }
        if let value = Double(current) { numbers.append(value) }
        guard numbers.count >= 2, abs(numbers[0]) <= 90, abs(numbers[1]) <= 180 else { return nil }
        return (numbers[0], numbers[1], numbers.count > 2 ? numbers[2] : nil)
    }
}
