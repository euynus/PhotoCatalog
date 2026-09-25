// ============================================================
//  Export settings — rendered export (Lightroom's Export dialog)
// ============================================================
import Foundation
import CoreGraphics

/// How finished photos are written: format, size, color, naming, metadata and watermark.
struct ExportSettings: Codable, Equatable, Sendable {
    enum Format: String, Codable, CaseIterable, Identifiable, Sendable {
        case jpeg, heic, tiff

        var id: Self { self }
        var title: String {
            switch self {
            case .jpeg: "JPEG"
            case .heic: "HEIC"
            case .tiff: "TIFF"
            }
        }
        var fileExtension: String {
            switch self {
            case .jpeg: "jpg"
            case .heic: "heic"
            case .tiff: "tif"
            }
        }
        var typeIdentifier: String {
            switch self {
            case .jpeg: "public.jpeg"
            case .heic: "public.heic"
            case .tiff: "public.tiff"
            }
        }
        var isLossy: Bool { self != .tiff }
    }

    enum ColorSpace: String, Codable, CaseIterable, Identifiable, Sendable {
        case sRGB, displayP3, adobeRGB

        var id: Self { self }
        var title: String {
            switch self {
            case .sRGB: "sRGB"
            case .displayP3: "Display P3"
            case .adobeRGB: "Adobe RGB (1998)"
            }
        }
        var cgColorSpace: CGColorSpace {
            switch self {
            case .sRGB: CGColorSpace(name: CGColorSpace.sRGB)!
            case .displayP3: CGColorSpace(name: CGColorSpace.displayP3)!
            case .adobeRGB: CGColorSpace(name: CGColorSpace.adobeRGB1998)!
            }
        }
    }

    enum Resize: String, Codable, CaseIterable, Identifiable, Sendable {
        case none, longEdge, shortEdge, fitWithin

        var id: Self { self }
        var title: String {
            switch self {
            case .none: L("原始尺寸")
            case .longEdge: L("长边")
            case .shortEdge: L("短边")
            case .fitWithin: L("宽 × 高以内")
            }
        }
    }

    enum Metadata: String, Codable, CaseIterable, Identifiable, Sendable {
        case all, copyrightOnly, none

        var id: Self { self }
        var title: String {
            switch self {
            case .all: L("全部元数据")
            case .copyrightOnly: L("仅版权信息")
            case .none: L("不包含")
            }
        }
    }

    enum Collision: String, Codable, CaseIterable, Identifiable, Sendable {
        case uniqueName, overwrite, skip

        var id: Self { self }
        var title: String {
            switch self {
            case .uniqueName: L("自动编号")
            case .overwrite: L("覆盖")
            case .skip: L("跳过")
            }
        }
    }

    var format = Format.jpeg
    /// 0…1 for JPEG and HEIC.
    var quality = 0.9
    /// TIFF only: 16 bits per channel keeps a RAW's tonal range for further editing.
    var sixteenBit = false
    var colorSpace = ColorSpace.sRGB
    var resize = Resize.none
    /// Pixels for the long or short edge.
    var edge = 2048
    var maxWidth = 1920
    var maxHeight = 1080
    var allowEnlarge = false
    /// Tokens: {original} {seq} {date} {time} {camera} {title} {rating}.
    var fileNameTemplate = "{original}"
    var sequenceStart = 1
    var subfolder = ""
    var metadata = Metadata.all
    var removeLocation = false
    /// Text drawn in the bottom-right corner when enabled.
    var watermarkEnabled = false
    var watermark = ""
    var collision = Collision.uniqueName
    var revealInFinder = true

    static let fileNameTokens: [(token: String, title: String)] = [
        ("{original}", L("原文件名")), ("{seq}", L("序号")), ("{date}", L("拍摄日期")), ("{time}", L("拍摄时间")),
        ("{camera}", L("相机")), ("{title}", L("标题")), ("{rating}", L("星级")),
    ]
}

extension ExportSettings {
    /// Settings saved before a field existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ExportSettings()
        format = try c.decodeIfPresent(Format.self, forKey: .format) ?? d.format
        quality = try c.decodeIfPresent(Double.self, forKey: .quality) ?? d.quality
        sixteenBit = try c.decodeIfPresent(Bool.self, forKey: .sixteenBit) ?? d.sixteenBit
        colorSpace = try c.decodeIfPresent(ColorSpace.self, forKey: .colorSpace) ?? d.colorSpace
        resize = try c.decodeIfPresent(Resize.self, forKey: .resize) ?? d.resize
        edge = try c.decodeIfPresent(Int.self, forKey: .edge) ?? d.edge
        maxWidth = try c.decodeIfPresent(Int.self, forKey: .maxWidth) ?? d.maxWidth
        maxHeight = try c.decodeIfPresent(Int.self, forKey: .maxHeight) ?? d.maxHeight
        allowEnlarge = try c.decodeIfPresent(Bool.self, forKey: .allowEnlarge) ?? d.allowEnlarge
        fileNameTemplate = try c.decodeIfPresent(String.self, forKey: .fileNameTemplate) ?? d.fileNameTemplate
        sequenceStart = try c.decodeIfPresent(Int.self, forKey: .sequenceStart) ?? d.sequenceStart
        subfolder = try c.decodeIfPresent(String.self, forKey: .subfolder) ?? d.subfolder
        metadata = try c.decodeIfPresent(Metadata.self, forKey: .metadata) ?? d.metadata
        removeLocation = try c.decodeIfPresent(Bool.self, forKey: .removeLocation) ?? d.removeLocation
        watermarkEnabled = try c.decodeIfPresent(Bool.self, forKey: .watermarkEnabled) ?? d.watermarkEnabled
        watermark = try c.decodeIfPresent(String.self, forKey: .watermark) ?? d.watermark
        collision = try c.decodeIfPresent(Collision.self, forKey: .collision) ?? d.collision
        revealInFinder = try c.decodeIfPresent(Bool.self, forKey: .revealInFinder) ?? d.revealInFinder
    }

    /// Final pixel size for a finished photo of `size`, per the resize rule.
    func outputSize(for size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return size }
        let long = max(size.width, size.height), short = min(size.width, size.height)
        var scale: CGFloat
        switch resize {
        case .none: return size
        case .longEdge: scale = CGFloat(max(edge, 1)) / long
        case .shortEdge: scale = CGFloat(max(edge, 1)) / short
        case .fitWithin:
            scale = min(CGFloat(max(maxWidth, 1)) / size.width, CGFloat(max(maxHeight, 1)) / size.height)
        }
        if !allowEnlarge { scale = min(scale, 1) }
        return CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
    }

    /// The long edge to decode the uncropped photo at — enough for the output whatever the crop
    /// (nil = full resolution). `cropShare` is the smaller of the crop's width and height fractions.
    func decodeLongEdge(original size: CGSize, cropShare: Double) -> Int? {
        let long = Double(max(size.width, size.height)), short = Double(min(size.width, size.height))
        guard long > 0, short > 0, !allowEnlarge else { return nil }
        let share = max(cropShare, 0.01)
        let needed: Double
        switch resize {
        case .none: return nil
        case .longEdge: needed = Double(edge) / share
        case .shortEdge: needed = Double(edge) * long / short / share
        case .fitWithin: needed = Double(max(maxWidth, maxHeight)) / share
        }
        let pixels = Int(needed.rounded(.up)) + 2
        return pixels >= Int(long) ? nil : pixels
    }

    /// The file name (without extension) for one photo.
    func fileName(original: String, sequence: Int, date: Date, camera: String, title: String,
                  rating: Int) -> String {
        FileNameTemplate.render(fileNameTemplate, original: original, sequence: sequence, date: date,
                                camera: camera, title: title, rating: rating)
    }
}

/// A named export setup. Presets live outside the catalog, so every library shares them.
struct RenderedExportPreset: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var settings: ExportSettings

    var isBuiltIn: Bool { id.hasPrefix("builtin.") }

    static let builtIns: [RenderedExportPreset] = [
        builtIn("full-jpeg", L("全尺寸 JPEG")) { $0.quality = 0.92 },
        builtIn("web", L("网络分享 · 2048 px")) {
            $0.resize = .longEdge
            $0.edge = 2048
            $0.quality = 0.82
            $0.removeLocation = true
        },
        builtIn("social", L("社交媒体 · 1080 px")) {
            $0.resize = .shortEdge
            $0.edge = 1080
            $0.quality = 0.85
            $0.removeLocation = true
            $0.metadata = .copyrightOnly
        },
        builtIn("print-tiff", L("打印 · 16 位 TIFF")) {
            $0.format = .tiff
            $0.sixteenBit = true
            $0.colorSpace = .adobeRGB
        },
        builtIn("heic", L("HEIC · 高效存档")) {
            $0.format = .heic
            $0.quality = 0.85
            $0.colorSpace = .displayP3
        },
    ]

    private static func builtIn(_ id: String, _ name: String, _ edit: (inout ExportSettings) -> Void) -> RenderedExportPreset {
        var settings = ExportSettings()
        edit(&settings)
        return RenderedExportPreset(id: "builtin.\(id)", name: name, settings: settings)
    }
}
