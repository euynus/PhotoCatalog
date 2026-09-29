// ============================================================
//  DevelopPresetFile — presets as XMP files, Lightroom's preset format
// ============================================================
import Foundation

/// Reads and writes develop presets as `.xmp` files. A preset written here carries its
/// settings twice: as Camera Raw (`crs:`) properties, so Lightroom and Camera Raw can import
/// what they share, and whole in the app's own property, so nothing is lost coming back here
/// (masks and spots included). A Lightroom preset is read from its `crs:` properties.
enum DevelopPresetFile {
    static let crsNamespace = "http://ns.adobe.com/camera-raw-settings/1.0/"
    static let ownNamespace = "http://ns.photocatalog.app/preset/1.0/"

    /// A preset read from a file, and what in it had nothing to map to.
    struct Reading {
        var preset: DevelopPreset
        var skipped: Set<Skipped>
    }

    enum Skipped: String, CaseIterable, Comparable, Sendable {
        case profile, masks, lensProfile, perspective, chromaticAberration, parametricCurve

        var title: String {
            switch self {
            case .profile: L("配置文件")
            case .masks: L("蒙版")
            case .lensProfile: L("镜头配置文件校正")
            case .perspective: L("透视校正")
            case .chromaticAberration: L("色差校正")
            case .parametricCurve: L("参数曲线")
            }
        }

        static func < (lhs: Skipped, rhs: Skipped) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }

    // ---- the settings both apps have ----
    private struct Scalar {
        let key: String
        let path: WritableKeyPath<DevelopSettings, Double>
        let field: DevelopField
        let format: String
        /// Lightroom's value minus this is ours (see `detailOffsets`).
        var offset: Double = 0
    }

    /// Detail here sits on top of the RAW engine's own sharpening and color noise reduction,
    /// which Lightroom counts in its absolute values (40 and 25 by default for RAW files).
    private static let scalars: [Scalar] = {
        var list: [Scalar] = [
            Scalar(key: "Exposure2012", path: \.exposure, field: .exposure, format: "%+.2f"),
            Scalar(key: "Contrast2012", path: \.contrast, field: .contrast, format: "%+.0f"),
            Scalar(key: "Highlights2012", path: \.highlights, field: .highlights, format: "%+.0f"),
            Scalar(key: "Shadows2012", path: \.shadows, field: .shadows, format: "%+.0f"),
            Scalar(key: "Whites2012", path: \.whites, field: .whites, format: "%+.0f"),
            Scalar(key: "Blacks2012", path: \.blacks, field: .blacks, format: "%+.0f"),
            Scalar(key: "Texture", path: \.texture, field: .texture, format: "%+.0f"),
            Scalar(key: "Clarity2012", path: \.clarity, field: .clarity, format: "%+.0f"),
            Scalar(key: "Dehaze", path: \.dehaze, field: .dehaze, format: "%+.0f"),
            Scalar(key: "Vibrance", path: \.vibrance, field: .vibrance, format: "%+.0f"),
            Scalar(key: "Saturation", path: \.saturation, field: .saturation, format: "%+.0f"),
            Scalar(key: "Sharpness", path: \.sharpening, field: .sharpening, format: "%.0f", offset: 40),
            Scalar(key: "SharpenRadius", path: \.sharpenRadius, field: .sharpening, format: "%+.1f"),
            Scalar(key: "SharpenEdgeMasking", path: \.sharpenMasking, field: .sharpening, format: "%.0f"),
            Scalar(key: "LuminanceSmoothing", path: \.luminanceNoise, field: .noiseReduction, format: "%.0f"),
            Scalar(key: "ColorNoiseReduction", path: \.colorNoise, field: .noiseReduction, format: "%.0f", offset: 25),
            Scalar(key: "LensManualDistortionAmount", path: \.distortion, field: .lensCorrections, format: "%+.0f"),
            Scalar(key: "VignetteAmount", path: \.lensVignette, field: .lensCorrections, format: "%+.0f"),
            Scalar(key: "VignetteMidpoint", path: \.lensVignetteMidpoint, field: .lensCorrections, format: "%.0f"),
            Scalar(key: "PostCropVignetteAmount", path: \.vignette, field: .vignette, format: "%+.0f"),
            Scalar(key: "PostCropVignetteMidpoint", path: \.vignetteMidpoint, field: .vignette, format: "%.0f"),
            Scalar(key: "PostCropVignetteFeather", path: \.vignetteFeather, field: .vignette, format: "%.0f"),
            Scalar(key: "GrainAmount", path: \.grain, field: .grain, format: "%.0f"),
            Scalar(key: "GrainSize", path: \.grainSize, field: .grain, format: "%.0f"),
            Scalar(key: "GrainFrequency", path: \.grainRoughness, field: .grain, format: "%.0f"),
            Scalar(key: "ColorGradeBlending", path: \.grading.blending, field: .colorGrading, format: "%.0f"),
            Scalar(key: "ColorGradeBalance", path: \.grading.balance, field: .colorGrading, format: "%+.0f"),
        ]
        let regions: [(String, WritableKeyPath<DevelopSettings, ColorGrading.Grade>)] = [
            ("Shadow", \.grading.shadows), ("Midtone", \.grading.midtones),
            ("Highlight", \.grading.highlights), ("Global", \.grading.global),
        ]
        for (name, grade) in regions {
            list.append(Scalar(key: "ColorGrade\(name)Hue", path: grade.appending(path: \.hue), field: .colorGrading,
                               format: "%.0f"))
            list.append(Scalar(key: "ColorGrade\(name)Sat", path: grade.appending(path: \.saturation),
                               field: .colorGrading, format: "%.0f"))
            list.append(Scalar(key: "ColorGrade\(name)Lum", path: grade.appending(path: \.luminance),
                               field: .colorGrading, format: "%+.0f"))
        }
        let bands = ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"]
        for (index, band) in bands.enumerated() {
            list.append(Scalar(key: "HueAdjustment\(band)", path: \.mixer.hue[index], field: .colorMixer, format: "%+.0f"))
            list.append(Scalar(key: "SaturationAdjustment\(band)", path: \.mixer.saturation[index], field: .colorMixer,
                               format: "%+.0f"))
            list.append(Scalar(key: "LuminanceAdjustment\(band)", path: \.mixer.luminance[index], field: .colorMixer,
                               format: "%+.0f"))
        }
        return list
    }()

    private static let curveKeys: [(String, ToneCurve.Channel)] = [
        ("ToneCurvePV2012", .rgb), ("ToneCurvePV2012Red", .red), ("ToneCurvePV2012Green", .green),
        ("ToneCurvePV2012Blue", .blue),
    ]

    // ---- writing ----
    /// The preset as an XMP file Lightroom can import (what it shares) and this app reads whole.
    static func xmp(for preset: DevelopPreset) -> String {
        let settings = preset.transfer.settings, fields = preset.transfer.fields
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var attributes: [(String, String)] = [
            ("crs:PresetType", "Normal"), ("crs:Cluster", ""), ("crs:UUID", uuid),
            ("crs:SupportsAmount", "True"), ("crs:SupportsColor", "True"), ("crs:SupportsMonochrome", "True"),
            ("crs:SupportsHighDynamicRange", "True"), ("crs:SupportsNormalDynamicRange", "True"),
            ("crs:SupportsSceneReferred", "True"), ("crs:SupportsOutputReferred", "True"),
            ("crs:CameraModelRestriction", ""), ("crs:Copyright", ""), ("crs:ContactInfo", ""),
            ("crs:Version", "15.0"), ("crs:ProcessVersion", "11.0"),
        ]
        if fields.contains(.whiteBalance) {
            if preset.transfer.sourceIsRaw {
                if let temperature = settings.temperature {
                    attributes += [("crs:WhiteBalance", "Custom"), ("crs:Temperature", String(format: "%.0f", temperature)),
                                   ("crs:Tint", String(format: "%+.0f", settings.tint ?? 0))]
                } else {
                    attributes.append(("crs:WhiteBalance", "As Shot"))
                }
            } else {
                attributes += [("crs:IncrementalTemperature", String(format: "%+.0f", settings.temperature ?? 0)),
                               ("crs:IncrementalTint", String(format: "%+.0f", settings.tint ?? 0))]
            }
        }
        for scalar in scalars where fields.contains(scalar.field) {
            let value = settings[keyPath: scalar.path] + scalar.offset
            attributes.append(("crs:" + scalar.key, String(format: scalar.format, value)))
        }
        if fields.contains(.toneCurve) {
            attributes.append(("crs:ToneCurveName2012", settings.curve.isLinear ? "Linear" : "Custom"))
        }
        attributes.append(("crs:HasSettings", "True"))
        let payload = Payload(name: preset.name, group: preset.group, transfer: preset.transfer)
        if let json = try? JSONEncoder().encode(payload) {
            attributes.append(("pc:Preset", String(decoding: json, as: UTF8.self)))
        }

        var elements = [
            alt("crs:Name", preset.name), alt("crs:ShortName", ""), alt("crs:SortName", ""),
            alt("crs:Group", preset.group ?? ""), alt("crs:Description", ""),
        ]
        if fields.contains(.toneCurve) {
            for (key, channel) in curveKeys {
                let points = settings.curve.editablePoints(for: channel).map {
                    "     <rdf:li>\(Int(($0.x * 255).rounded())), \(Int(($0.y * 255).rounded()))</rdf:li>"
                }
                elements.append("   <crs:\(key)>\n    <rdf:Seq>\n\(points.joined(separator: "\n"))\n    </rdf:Seq>\n   </crs:\(key)>")
            }
        }
        let attributeText = attributes.map { "\n    \($0.0)=\"\(escape($0.1))\"" }.joined()
        return """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="PhotoCatalog">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:crs="\(crsNamespace)"
            xmlns:pc="\(ownNamespace)"\(attributeText)>
        \(elements.joined(separator: "\n"))
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>

        """
    }

    /// What the app's own property holds.
    private struct Payload: Codable {
        let name: String
        let group: String?
        let transfer: DevelopTransfer
    }

    private static func alt(_ name: String, _ value: String) -> String {
        "   <\(name)>\n    <rdf:Alt>\n     <rdf:li xml:lang=\"x-default\">\(escape(value))</rdf:li>\n    </rdf:Alt>\n   </\(name)>"
    }

    private static func escape(_ text: String) -> String {
        let allowed = text.unicodeScalars.filter { scalar in
            let v = scalar.value
            return v == 0x9 || v == 0xA || v == 0xD || (v >= 0x20 && v != 0xFFFE && v != 0xFFFF)
        }
        return String(String.UnicodeScalarView(allowed))
            .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    // ---- reading ----
    /// The preset in `data` (named `fileName` when it doesn't say), or nil when it isn't a
    /// develop preset: not XMP, a profile ("Look") only, or no settings at all.
    static func read(_ data: Data, fileName: String) -> Reading? {
        guard let document = try? XMLDocument(data: data, options: []),
              let description = (try? document.nodes(forXPath: "//*[local-name()='Description']"))?
                  .compactMap({ $0 as? XMLElement }).first(where: { element in
                      (element.attributes ?? []).contains { isCRS($0) || isOwn($0) }
                          || (element.children ?? []).contains { isCRS($0) || isOwn($0) }
                  })
        else { return nil }

        // every property, whether written as an attribute or as an element
        var values: [String: String] = [:]
        var elements: [String: XMLElement] = [:]
        var own: String?
        for attribute in description.attributes ?? [] {
            if isCRS(attribute), let key = attribute.localName { values[key] = attribute.stringValue ?? "" }
            if isOwn(attribute) { own = attribute.stringValue }
        }
        for case let child as XMLElement in description.children ?? [] {
            if isCRS(child), let key = child.localName {
                elements[key] = child
                if child.childCount == 0 { values[key] = child.stringValue ?? "" }
            }
            if isOwn(child) { own = child.stringValue }
        }
        let name = firstItem(elements["Name"]).flatMap { $0.isEmpty ? nil : $0 }
            ?? (fileName as NSString).deletingPathExtension
        let group = firstItem(elements["Group"]).flatMap { $0.isEmpty ? nil : $0 }

        // this app's own file: whole
        if let own, let payload = try? JSONDecoder().decode(Payload.self, from: Data(own.utf8)) {
            return Reading(preset: DevelopPreset(id: UUID().uuidString, name: payload.name, transfer: payload.transfer,
                                                 group: payload.group),
                           skipped: [])
        }

        var settings = DevelopSettings()
        var fields = Set<DevelopField>()
        var sourceIsRaw = true
        func number(_ key: String) -> Double? {
            values[key].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        }
        // white balance: Kelvin for RAW files, a relative shift for the rest
        if let balance = values["WhiteBalance"] {
            fields.insert(.whiteBalance)
            if balance != "As Shot", let kelvin = number("Temperature") {
                settings.temperature = min(12000, max(2000, kelvin))
                settings.tint = number("Tint").map { min(150, max(-150, $0)) } ?? 0
            }
        }
        if number("IncrementalTemperature") != nil || number("IncrementalTint") != nil {
            fields.insert(.whiteBalance)
            if number("Temperature") == nil {
                sourceIsRaw = false
                settings.temperature = number("IncrementalTemperature").map { min(100, max(-100, $0)) } ?? 0
                settings.tint = number("IncrementalTint").map { min(100, max(-100, $0)) } ?? 0
            }
        }
        for scalar in scalars {
            guard let value = number(scalar.key) else { continue }
            settings[keyPath: scalar.path] = scalar.offset > 0 ? max(0, value - scalar.offset) : value
            fields.insert(scalar.field)
        }
        // Lightroom's older split toning, where color grading isn't there
        if number("ColorGradeShadowHue") == nil, number("SplitToningShadowHue") != nil
            || number("SplitToningHighlightHue") != nil {
            settings.grading.shadows.hue = number("SplitToningShadowHue") ?? 0
            settings.grading.shadows.saturation = number("SplitToningShadowSaturation") ?? 0
            settings.grading.highlights.hue = number("SplitToningHighlightHue") ?? 0
            settings.grading.highlights.saturation = number("SplitToningHighlightSaturation") ?? 0
            settings.grading.balance = number("SplitToningBalance") ?? 0
            fields.insert(.colorGrading)
        }
        if values["ConvertToGrayscale"] == "True" {
            settings.saturation = -100
            fields.insert(.saturation)
        }
        for (key, channel) in curveKeys {
            guard let element = elements[key] else { continue }
            let points = items(element).compactMap { item -> CurvePoint? in
                let parts = item.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                return parts.count == 2 ? CurvePoint(x: parts[0] / 255, y: parts[1] / 255) : nil
            }
            settings.curve.setPoints(points, for: channel)
            fields.insert(.toneCurve)
        }
        guard !fields.isEmpty else { return nil }

        var skipped = Set<Skipped>()
        if values["CameraProfile"] != nil || elements["Look"] != nil { skipped.insert(.profile) }
        if ["MaskGroupBasedCorrections", "GradientBasedCorrections", "CircularGradientBasedCorrections",
            "PaintBasedCorrections"].contains(where: { elements[$0] != nil }) { skipped.insert(.masks) }
        if values["LensProfileEnable"] == "1" { skipped.insert(.lensProfile) }
        if ["PerspectiveUpright", "PerspectiveVertical", "PerspectiveHorizontal", "PerspectiveRotate"]
            .contains(where: { (number($0) ?? 0) != 0 }) { skipped.insert(.perspective) }
        if values["AutoLateralCA"] == "1" || (number("DefringePurpleAmount") ?? 0) != 0
            || (number("DefringeGreenAmount") ?? 0) != 0 { skipped.insert(.chromaticAberration) }
        if ["ParametricShadows", "ParametricDarks", "ParametricLights", "ParametricHighlights"]
            .contains(where: { (number($0) ?? 0) != 0 }) { skipped.insert(.parametricCurve) }
        let transfer = DevelopTransfer(settings: settings, fields: fields, sourceIsRaw: sourceIsRaw)
        return Reading(preset: DevelopPreset(id: UUID().uuidString, name: name, transfer: transfer, group: group),
                       skipped: skipped)
    }

    private static func isCRS(_ node: XMLNode) -> Bool {
        node.uri == crsNamespace || node.name?.hasPrefix("crs:") == true
    }

    private static func isOwn(_ node: XMLNode) -> Bool {
        (node.uri == ownNamespace || node.name?.hasPrefix("pc:") == true) && node.localName == "Preset"
    }

    /// The list items of an rdf:Alt / Seq / Bag inside `element`.
    private static func items(_ element: XMLElement) -> [String] {
        ((try? element.nodes(forXPath: ".//*[local-name()='li']")) ?? []).compactMap(\.stringValue)
    }

    private static func firstItem(_ element: XMLElement?) -> String? {
        element.flatMap { items($0).first ?? $0.stringValue }?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
