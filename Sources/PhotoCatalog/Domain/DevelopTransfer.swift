// ============================================================
//  Develop transfer — copy / paste / sync settings and presets
// ============================================================
import Foundation

/// One setting that copy, sync and presets can carry, as in Lightroom's Copy Settings dialog.
/// Orientation comes before crop so a copied crop lands in the copied frame.
enum DevelopField: String, CaseIterable, Codable, Identifiable, Sendable {
    case whiteBalance, exposure, contrast, highlights, shadows, whites, blacks, vibrance, saturation
    case orientation, crop

    var id: Self { self }

    var title: String {
        switch self {
        case .whiteBalance: L("白平衡")
        case .exposure: L("曝光度")
        case .contrast: L("对比度")
        case .highlights: L("高光")
        case .shadows: L("阴影")
        case .whites: L("白色色阶")
        case .blacks: L("黑色色阶")
        case .vibrance: L("鲜艳度")
        case .saturation: L("饱和度")
        case .orientation: L("旋转与翻转")
        case .crop: L("裁剪与拉直")
        }
    }

    /// Sections of the copy dialog.
    static let groups: [(title: String, fields: [DevelopField])] = [
        (L("白平衡"), [.whiteBalance]),
        (L("色调"), [.exposure, .contrast, .highlights, .shadows, .whites, .blacks]),
        (L("偏好"), [.vibrance, .saturation]),
        (L("裁剪与旋转"), [.orientation, .crop]),
    ]

    /// Copy leaves framing alone unless asked: crops rarely fit another photo.
    static let defaultCopy = Set(allCases).subtracting([.orientation, .crop])

    /// Whether `settings` differ from as shot in this field.
    func isAdjusted(in settings: DevelopSettings) -> Bool {
        DevelopSettings.neutral.applying(settings, fields: [self]) != .neutral
    }
}

extension DevelopSettings {
    /// These settings with `fields` taken from `source`. Taking the orientation turns this
    /// photo's own crop along, so it stays on the same part of the picture.
    func applying(_ source: DevelopSettings, fields: Set<DevelopField>) -> DevelopSettings {
        var next = self
        for field in DevelopField.allCases where fields.contains(field) {
            switch field {
            case .whiteBalance:
                next.temperature = source.temperature
                next.tint = source.tint
            case .exposure: next.exposure = source.exposure
            case .contrast: next.contrast = source.contrast
            case .highlights: next.highlights = source.highlights
            case .shadows: next.shadows = source.shadows
            case .whites: next.whites = source.whites
            case .blacks: next.blacks = source.blacks
            case .vibrance: next.vibrance = source.vibrance
            case .saturation: next.saturation = source.saturation
            case .orientation:
                if next.flipped != source.flipped { next = DevelopGeometry.mirrored(next) }
                for _ in 0..<4 where next.rotation != source.rotation {
                    next = DevelopGeometry.rotated(next, clockwise: true)
                }
            case .crop:
                next.straighten = source.straighten
                next.crop = source.crop
            }
        }
        return next
    }
}

/// Settings on their way to other photos, by paste, sync or preset.
struct DevelopTransfer: Codable, Equatable, Sendable {
    var settings: DevelopSettings
    var fields: Set<DevelopField>
    /// White balance is absolute Kelvin on RAW files but a relative shift on others,
    /// so it only carries between photos of the same kind.
    var sourceIsRaw: Bool

    func applied(to target: DevelopSettings, targetIsRaw: Bool) -> DevelopSettings {
        var fields = self.fields
        if targetIsRaw != sourceIsRaw { fields.remove(.whiteBalance) }
        return target.applying(settings, fields: fields)
    }
}

/// A named transfer the user keeps. Presets live outside the catalog, so every library has them.
struct DevelopPreset: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var transfer: DevelopTransfer

    var isBuiltIn: Bool { id.hasPrefix("builtin.") }

    static let builtIns: [DevelopPreset] = [
        builtIn("bw", L("黑白"), [.vibrance, .saturation]) { $0.saturation = -100 },
        builtIn("bw-contrast", L("黑白 · 高对比"), [.vibrance, .saturation, .contrast, .whites, .blacks]) {
            $0.saturation = -100
            $0.contrast = 40
            $0.whites = 20
            $0.blacks = -20
        },
        builtIn("vivid", L("鲜艳"), [.vibrance, .saturation]) {
            $0.vibrance = 35
            $0.saturation = 8
        },
        builtIn("punch", L("高对比"), [.contrast, .whites, .blacks]) {
            $0.contrast = 35
            $0.whites = 15
            $0.blacks = -15
        },
        builtIn("soft", L("柔和"), [.contrast, .highlights, .shadows]) {
            $0.contrast = -15
            $0.highlights = -25
            $0.shadows = 25
        },
        builtIn("fade", L("褪色胶片"), [.contrast, .blacks, .saturation]) {
            $0.contrast = -10
            $0.blacks = 30
            $0.saturation = -25
        },
        builtIn("open-shadows", L("提亮阴影"), [.highlights, .shadows]) {
            $0.highlights = -20
            $0.shadows = 45
        },
    ]

    private static func builtIn(_ id: String, _ name: String, _ fields: Set<DevelopField>,
                                _ edit: (inout DevelopSettings) -> Void) -> DevelopPreset {
        var settings = DevelopSettings()
        edit(&settings)
        return DevelopPreset(id: "builtin.\(id)", name: name,
                             transfer: DevelopTransfer(settings: settings, fields: fields, sourceIsRaw: false))
    }
}
