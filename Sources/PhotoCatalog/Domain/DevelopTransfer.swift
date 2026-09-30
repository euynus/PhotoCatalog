// ============================================================
//  Develop transfer — copy / paste / sync settings and presets
// ============================================================
import Foundation

/// One setting that copy, sync and presets can carry, as in Lightroom's Copy Settings dialog.
/// Orientation comes before crop so a copied crop lands in the copied frame.
enum DevelopField: String, CaseIterable, Codable, Identifiable, Sendable {
    case whiteBalance, exposure, contrast, highlights, shadows, whites, blacks, texture, clarity, dehaze
    case vibrance, saturation, toneCurve, colorMixer, colorGrading, lut
    case sharpening, noiseReduction, lensCorrections, vignette, grain, masks, spots
    case orientation, perspective, crop

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
        case .texture: L("纹理")
        case .clarity: L("清晰度")
        case .dehaze: L("去朦胧")
        case .toneCurve: L("色调曲线")
        case .colorMixer: L("混色器")
        case .colorGrading: L("颜色分级")
        case .lut: L("LUT")
        case .vibrance: L("鲜艳度")
        case .saturation: L("饱和度")
        case .sharpening: L("锐化")
        case .noiseReduction: L("减少杂色")
        case .lensCorrections: L("镜头校正")
        case .vignette: L("裁剪后暗角")
        case .grain: L("颗粒")
        case .masks: L("蒙版")
        case .spots: L("污点去除")
        case .orientation: L("旋转与翻转")
        case .perspective: L("透视")
        case .crop: L("裁剪与拉直")
        }
    }

    /// Sections of the copy dialog.
    static let groups: [(title: String, fields: [DevelopField])] = [
        (L("白平衡"), [.whiteBalance]),
        (L("色调"), [.exposure, .contrast, .highlights, .shadows, .whites, .blacks]),
        (L("偏好"), [.texture, .clarity, .dehaze, .vibrance, .saturation]),
        (L("色调曲线"), [.toneCurve]),
        (L("混色器"), [.colorMixer]),
        (L("颜色分级"), [.colorGrading]),
        (L("LUT"), [.lut]),
        (L("细节"), [.sharpening, .noiseReduction]),
        (L("镜头校正"), [.lensCorrections]),
        (L("效果"), [.vignette, .grain]),
        (L("蒙版"), [.masks]),
        (L("污点去除"), [.spots]),
        (L("裁剪与旋转"), [.orientation, .perspective, .crop]),
    ]

    /// Copy leaves framing, masks and spots alone unless asked: they belong to one photo's
    /// content (sensor dust in a burst is the exception worth ticking spots for).
    static let defaultCopy = Set(allCases).subtracting([.orientation, .perspective, .crop, .masks, .spots])

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
            case .texture: next.texture = source.texture
            case .clarity: next.clarity = source.clarity
            case .dehaze: next.dehaze = source.dehaze
            case .toneCurve: next.curve = source.curve
            case .colorMixer: next.mixer = source.mixer
            case .colorGrading: next.grading = source.grading
            case .lut:
                next.lutId = source.lutId
                next.lutAmount = source.lutAmount
            case .vibrance: next.vibrance = source.vibrance
            case .saturation: next.saturation = source.saturation
            case .sharpening:
                next.sharpening = source.sharpening
                next.sharpenRadius = source.sharpenRadius
                next.sharpenMasking = source.sharpenMasking
            case .noiseReduction:
                next.luminanceNoise = source.luminanceNoise
                next.colorNoise = source.colorNoise
            case .lensCorrections:
                next.distortion = source.distortion
                next.lensVignette = source.lensVignette
                next.lensVignetteMidpoint = source.lensVignetteMidpoint
                next.removeChromaticAberration = source.removeChromaticAberration
                next.defringePurple = source.defringePurple
                next.defringeGreen = source.defringeGreen
            case .vignette:
                next.vignette = source.vignette
                next.vignetteMidpoint = source.vignetteMidpoint
                next.vignetteFeather = source.vignetteFeather
            case .grain:
                next.grain = source.grain
                next.grainSize = source.grainSize
                next.grainRoughness = source.grainRoughness
            case .masks: next.masks = source.masks
            case .spots: next.spots = source.spots
            case .orientation:
                if next.flipped != source.flipped { next = DevelopGeometry.mirrored(next) }
                for _ in 0..<4 where next.rotation != source.rotation {
                    next = DevelopGeometry.rotated(next, clockwise: true)
                }
            case .perspective:
                next.perspectiveVertical = source.perspectiveVertical
                next.perspectiveHorizontal = source.perspectiveHorizontal
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
    /// The group it's listed under; nil is 我的预设.
    var group: String?

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
