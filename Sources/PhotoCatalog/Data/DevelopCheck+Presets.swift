import Foundation
import CoreImage

extension DevelopCheck {
    static func checkTransferRules() {
        var source = DevelopSettings()
        source.exposure = 0.8
        source.contrast = 20
        source.temperature = 4200
        source.rotation = 1
        var target = DevelopSettings()
        target.shadows = 30
        target.crop = DevelopCrop(x: 0.1, y: 0.2, width: 0.5, height: 0.3)

        let toned = target.applying(source, fields: [.exposure])
        assert(toned.exposure == 0.8 && toned.contrast == 0 && toned.shadows == 30,
               "only the chosen settings travel; the rest of the photo's edit stays")
        let turned = target.applying(source, fields: [.orientation])
        assert(turned.rotation == 1 && abs(turned.crop!.x - 0.5) < 1e-9 && abs(turned.crop!.y - 0.1) < 1e-9,
               "taking a rotation turns the photo's own crop with it")

        let transfer = DevelopTransfer(settings: source, fields: [.whiteBalance, .exposure], sourceIsRaw: true)
        assert(transfer.applied(to: target, targetIsRaw: true).temperature == 4200,
               "white balance carries between RAW files")
        let onJPEG = transfer.applied(to: target, targetIsRaw: false)
        assert(onJPEG.temperature == nil && onJPEG.exposure == 0.8, "RAW Kelvin never lands on a JPEG")

        assert(DevelopField.exposure.isAdjusted(in: source) && !DevelopField.shadows.isAdjusted(in: source)
               && DevelopField.orientation.isAdjusted(in: source), "adjusted fields are detected")
        for preset in DevelopPreset.builtIns {
            let untouched = Set(DevelopField.allCases).subtracting(preset.transfer.fields)
            assert(untouched.allSatisfy { !$0.isAdjusted(in: preset.transfer.settings) },
                   "built-in preset \(preset.name) only sets the fields it carries")
        }
    }

    @MainActor
    static func checkCopyPasteAndPresets() {
        let base = DemoData.assets.filter(\.isRaw)
        func local(_ asset: Asset, _ name: String) -> Asset {
            var copy = asset
            copy.localPath = "/tmp/pc-develop-transfer/\(name)"
            copy.status = .ready
            copy.isDemo = false
            return copy
        }
        let a = local(base[0], "A.CR3"), b = local(base[1], "B.CR3"), c = local(base[2], "C.CR3")
        let app = AppState.selfCheckFixture()
        app.assets = [a, b, c]
        app.duplicateGroupsCache = []
        app.select(Selection(type: .lib, id: "all", name: "Transfer check"))
        let savedPresets = app.developPresets
        let savedFields = app.developTransferFields
        let savedImportPreset = app.importDevelopPresetId
        let savedRawDefaults = app.rawDefaultPresetIds
        defer {
            app.developPresets = savedPresets
            app.developTransferFields = savedFields
            app.importDevelopPresetId = savedImportPreset
            app.rawDefaultPresetIds = savedRawDefaults
        }

        var edit = DevelopSettings()
        edit.exposure = 0.6
        edit.vibrance = 25
        edit.crop = DevelopCrop(x: 0, y: 0, width: 0.5, height: 0.5)
        app.commitDevelop([a.id: edit], undoName: "调整")
        app.setPrimary(a.id)
        app.copyDevelopSettings(fields: DevelopField.defaultCopy)
        app.selectedIds = [b.id, c.id]
        app.primaryId = b.id
        let undo = UndoManager()
        undo.groupsByEvent = false
        app.undoManager = undo
        undo.beginUndoGrouping()
        app.pasteDevelopSettings()
        undo.endUndoGrouping()
        let pasted = app.developSettings[b.id]
        assert(pasted?.exposure == 0.6 && pasted?.vibrance == 25 && pasted?.crop == nil
               && app.developSettings[c.id] == pasted, "paste reaches every selected photo, crop left out")
        undo.undo()
        assert(app.developSettings[b.id] == nil && app.developSettings[c.id] == nil, "one undo takes the paste back")
        app.undoManager = nil

        app.selectedIds = [a.id, b.id, c.id]
        app.primaryId = a.id
        app.syncDevelopSettings(fields: [.exposure])
        assert(app.developSettings[b.id]?.exposure == 0.6 && app.developSettings[b.id]?.vibrance == 0
               && app.developSettings[a.id] == edit, "sync copies the chosen settings from the selected photo")

        // resting on a preset shows it without saving; leaving takes it away; a drag in
        // progress is never replaced
        let vivid = DevelopPreset.builtIns.first { $0.id == "builtin.vivid" }!
        app.previewDevelopPreset(vivid, on: c)
        assert(app.developSettings(for: c.id).vibrance == 35 && app.developSettings[c.id]?.vibrance != 35,
               "a preset previews without saving")
        app.endDevelopPresetPreview(vivid.id)
        assert(app.developDraft == nil && app.developSettings(for: c.id).vibrance != 35, "leaving it ends the preview")
        var dragging = app.developSettings(for: c.id)
        dragging.contrast = 12
        app.updateDevelopDraft(dragging, for: c.id)
        app.previewDevelopPreset(vivid, on: c)
        assert(app.developDraft?.settings == dragging, "a preview never replaces a drag")
        app.endDevelopPresetPreview()
        assert(app.developDraft?.settings == dragging, "and ending one leaves the drag alone")
        app.developDraft = nil

        app.setPrimary(c.id)
        app.applyDevelopPreset(DevelopPreset.builtIns.first { $0.name == "黑白" }!)
        assert(app.developSettings[c.id]?.profile == "monochrome" && app.developSettings[c.id]?.exposure == 0.6,
               "a preset changes only its own settings")
        assert(app.developPresetAmount(for: c.id) == nil, "the grid applies presets at full strength, without an amount")

        // in Develop, the preset's amount turns it up or down, until another edit
        app.view = .develop
        app.applyDevelopPreset(vivid)
        assert(app.developPresetAmount(for: c.id)?.amount == 1, "applying a preset in Develop offers its amount")
        app.setDevelopPresetAmount(0.5)
        assert(app.developSettings(for: c.id).vibrance == 18 && app.developSettings[c.id]?.vibrance == 35,
               "dragging the amount previews it")
        app.commitDevelopPresetAmount()
        let halfVivid = app.developSettings[c.id]
        assert(halfVivid.map { $0.vibrance == 18 && $0.saturation == 4 && $0.profile == "monochrome" } == true
               && app.developPresetAmount(for: c.id)?.amount == 0.5 && app.developPresetAmountDraft == nil,
               "releasing saves it")
        var other = app.developSettings(for: c.id)
        other.clarity = 10
        app.commitDevelop([c.id: other], undoName: "清晰度")
        assert(app.developPresetAmount(for: c.id) == nil, "another edit ends the amount")
        app.view = .grid

        app.setPrimary(a.id)
        app.saveDevelopPreset(name: "  测试预设 ", fields: app.developPresetDefaultFields)
        let preset = app.developPresets.last
        assert(preset?.name == "测试预设" && preset?.transfer.fields == [.exposure, .vibrance],
               "a new preset holds what the photo adjusted, framing aside")
        app.saveDevelopPreset(name: "测试预设", fields: [.exposure])
        assert(app.developPresets.filter { $0.name == "测试预设" }.count == 1, "saving a name again replaces it")

        // managing: rename (not onto another's name), update from the photo, groups
        app.saveDevelopPreset(name: "另一个", fields: [.contrast], group: "  人像 ")
        let second = app.developPresets.last!
        assert(second.group == "人像" && app.developPresetGroups == ["人像"], "a preset can be saved into a group")
        assert(!app.renameDevelopPreset(second.id, to: "测试预设") && app.renameDevelopPreset(second.id, to: "对比"),
               "renaming refuses another preset's name")
        var brighter = app.developSettings[a.id] ?? .neutral
        brighter.exposure = 1.1
        app.commitDevelop([a.id: brighter], undoName: "曝光")
        app.updateDevelopPreset(preset!.id)
        let updated = app.developPresets.first { $0.id == preset!.id }
        assert(updated?.transfer.settings.exposure == 1.1 && updated?.transfer.fields == [.exposure],
               "updating takes the photo's values for the settings the preset holds")
        app.moveDevelopPreset(second.id, toGroup: "我的预设")
        assert(app.developPresets.first { $0.id == second.id }?.group == nil && app.developPresetGroups.isEmpty,
               "moving to 我的预设 takes it out of its group")
        app.deleteDevelopPreset(second.id)
        app.deleteDevelopPreset(preset!.id)
        assert(!app.developPresets.contains { $0.name == "测试预设" }, "presets can be deleted")

        app.selectedIds = [a.id, b.id, c.id]
        app.resetDevelopSelection()
        assert(app.developSettings.isEmpty, "reset returns the selection to as shot")

        // import: new photos start from the import preset, recorded in their history
        app.importDevelopPresetId = "builtin.bw"
        _ = app.developHistory(for: b.id)   // shown, so its history is kept in memory without a catalog
        app.applyImportDevelopSettings(to: [a, b])
        assert(app.developSettings[a.id]?.profile == "monochrome" && app.developSettings[b.id]?.profile == "monochrome"
               && app.developSettings[c.id] == nil, "imported photos get the import preset")
        assert(app.developHistory(for: b.id).last?.name == L("导入预设“\(L("黑白"))”"),
               "the import preset is recorded as a history step")
        app.importDevelopPresetId = "gone"
        app.applyImportDevelopSettings(to: [c])
        assert(app.developSettings[c.id] == nil && app.importDevelopPreset == nil, "a deleted import preset does nothing")

        // RAW defaults: a camera's own, or every camera's; applied before the import preset,
        // and where 复位 goes
        // another camera than A's (the demo set has several)
        guard let other = base.first(where: { $0.camera != a.camera && ![a.id, b.id, c.id].contains($0.id) }) else {
            preconditionFailure("the demo set has RAW photos from more than one camera")
        }
        let d = local(other, "D.CR3")
        app.rawDefaultPresetIds = [:]
        app.setRawDefaultPreset("builtin.punch", forCamera: "")
        app.setRawDefaultPreset("builtin.soft", forCamera: d.camera)
        app.importDevelopPresetId = "builtin.bw"
        app.developSettings[a.id] = nil
        app.applyImportDevelopSettings(to: [a, d])
        assert(app.developSettings[d.id]?.contrast == -15 && app.developSettings[d.id]?.profile == "monochrome"
               && app.developSettings[a.id]?.contrast == 35 && app.developSettings[a.id]?.profile == "monochrome",
               "RAW photos start from their camera's default, or every camera's, then the import preset")
        app.setRawDefaultPreset("none", forCamera: d.camera)
        assert(app.defaultDevelopSettings(for: d) == .neutral && app.defaultDevelopSettings(for: a).contrast == 35,
               "a camera can be kept as shot")
        app.setRawDefaultPreset("", forCamera: d.camera)
        assert(app.rawDefaultPresetIds[d.camera] == nil, "clearing a camera's default follows every camera's")
        app.view = .develop
        app.setPrimary(a.id)
        app.resetDevelop(a)
        assert(app.developSettings[a.id] == app.defaultDevelopSettings(for: a) && app.developSettings[a.id]?.contrast == 35,
               "复位 returns a RAW photo to its defaults")
        app.view = .grid
        app.importDevelopPresetId = ""
        app.rawDefaultPresetIds = [:]
    }

    /// LUTs: .cube files parsed (resampled when their size isn't a power of two), applied in
    /// sRGB at their amount, and kept in the library.
    @MainActor
    static func checkLUTs() {
        func cube(size: Int, title: String = "Test", _ f: (Double, Double, Double) -> (Double, Double, Double)) -> String {
            var lines = ["TITLE \"\(title)\"", "# a comment", "LUT_3D_SIZE \(size)"]
            for b in 0..<size { for g in 0..<size { for r in 0..<size {
                let v = f(Double(r) / Double(size - 1), Double(g) / Double(size - 1), Double(b) / Double(size - 1))
                lines.append(String(format: "%.6f %.6f %.6f", v.0, v.1, v.2))
            } } }
            return lines.joined(separator: "\n")
        }
        let identity = cube(size: 17) { ($0, $1, $2) }
        assert(LUTLibrary.parse(identity)?.size == 32 && LUTLibrary.title(of: identity) == "Test",
               "a 17-point LUT is resampled to 32 points and keeps its title")
        assert(LUTLibrary.parse("LUT_1D_SIZE 2\n0 0 0\n1 1 1") == nil && LUTLibrary.parse("LUT_3D_SIZE 2\n0 0 0") == nil,
               "1D LUTs and files missing values are refused")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pc-luts-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let identityURL = folder.appendingPathComponent("identity.cube"), invertURL = folder.appendingPathComponent("Invert.cube")
        try? identity.write(to: identityURL, atomically: true, encoding: .utf8)
        try? cube(size: 2, title: "") { (1 - $0, 1 - $1, 1 - $2) }.write(to: invertURL, atomically: true, encoding: .utf8)
        try? "not a lut".write(to: folder.appendingPathComponent("bad.cube"), atomically: true, encoding: .utf8)

        let app = AppState.selfCheckFixture()
        let savedLUTs = app.developLUTs
        let result = app.importLUTs(from: ["identity.cube", "Invert.cube", "bad.cube"].map { folder.appendingPathComponent($0) })
        let added = Array(app.developLUTs.dropFirst(savedLUTs.count))
        defer {
            for lut in added { LUTLibrary.remove(id: lut.id) }
            app.developLUTs = savedLUTs
        }
        assert(result.added == 2 && result.failed == 1 && added.map(\.name) == ["Test", "Invert"],
               "LUTs are imported under their title or file name, and bad files counted")

        let color = image { _, _ in (0.7, 0.4, 0.2) }
        let plain = develop(color, .neutral)
        var s = DevelopSettings()
        s.lutId = added[0].id
        let same = pixel(develop(color, s), 32, 32), before = pixel(plain, 32, 32)
        assert(abs(Int(same.r) - Int(before.r)) < 4 && abs(Int(same.b) - Int(before.b)) < 4, "an identity LUT changes nothing")
        s.lutId = added[1].id
        let inverted = pixel(develop(color, s), 32, 32)
        assert(Int(inverted.b) > Int(inverted.r) + 60, "a LUT's look is applied")
        s.lutAmount = 50
        let half = pixel(develop(color, s), 32, 32)
        assert(half.b > before.b + 20 && half.b < inverted.b - 20, "half the amount goes halfway")
        var other = s
        other.lutAmount = 80
        assert(other.fingerprint != s.fingerprint && DevelopSettings().applying(s, fields: [.lut]).lutId == s.lutId,
               "the LUT changes the fingerprint and travels as one setting")
        s.lutId = "gone"
        let missing = pixel(develop(color, s), 32, 32)
        assert(abs(Int(missing.r) - Int(before.r)) < 3, "a LUT no longer in the library leaves the photo as it is")
    }

    /// A preset's Amount: sliders, white balance, curves and masks scale; the rest is all or nothing.
    static func checkPresetBlend() {
        var base = DevelopSettings()
        base.exposure = 0.5
        var mask = LocalAdjustment(kind: .radial)
        mask.exposure = 1
        var target = base
        target.exposure = 1.5
        target.contrast = 60
        target.mixer.saturation[ColorMixer.Band.blue.rawValue] = -40
        target.grading.shadows = ColorGrading.Grade(hue: 200, saturation: 40, luminance: 0)
        target.temperature = 20
        target.curve.setPoints(ToneCurve.strongContrast, for: .rgb)
        target.masks = [mask]
        target.crop = DevelopCrop(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        func blend(_ amount: Double) -> DevelopSettings {
            DevelopSettings.blend(base, target, amount: amount, isRaw: false, whiteBalanceOrigin: (0, 0))
        }
        assert(blend(0) == base && blend(1) == target, "no amount is the photo before, full amount the preset")
        let half = blend(0.5)
        assert(abs(half.exposure - 1) < 1e-9 && half.contrast == 30 && half.mixer.saturation[ColorMixer.Band.blue.rawValue] == -20
               && half.grading.shadows.saturation == 20 && half.grading.shadows.hue == 200 && half.temperature == 10,
               "half the amount goes halfway, hues aside")
        let halfCurve = ToneCurve.evaluate(half.curve.editablePoints(for: .rgb), at: 0.25)
        assert(abs(halfCurve - 0.205) < 0.01, "the curve moves halfway too")
        assert(half.masks.first?.exposure == 0.5 && half.masks.first?.id == mask.id && half.crop == target.crop,
               "masks keep their shape and scale their adjustments; the crop comes whole")
        let double = blend(2)
        assert(double.contrast == 100 && abs(double.exposure - 2.5) < 1e-9, "twice the amount goes further and stays in range")
        var rawBase = DevelopSettings(), rawTarget = DevelopSettings()
        rawTarget.temperature = 6500
        rawBase.temperature = nil
        let rawHalf = DevelopSettings.blend(rawBase, rawTarget, amount: 0.5, isRaw: true, whiteBalanceOrigin: (5500, 0))
        assert(rawHalf.temperature == 6000, "a RAW's white balance moves from as shot")
    }

    /// Presets as .xmp files: this app's come back whole; Lightroom's map what both apps have.
    @MainActor
    static func checkPresetFiles() {
        var settings = DevelopSettings()
        settings.temperature = 6200
        settings.tint = 8
        settings.exposure = 0.35
        settings.curve.setPoints(ToneCurve.mediumContrast, for: .rgb)
        settings.mixer.hue[ColorMixer.Band.blue.rawValue] = -12
        settings.grading.shadows = ColorGrading.Grade(hue: 210, saturation: 15, luminance: -5)
        settings.sharpening = 20
        settings.masks = [LocalAdjustment(kind: .sky)]
        let fields: Set<DevelopField> = [.whiteBalance, .exposure, .toneCurve, .colorMixer, .colorGrading, .sharpening, .masks]
        let preset = DevelopPreset(id: "p", name: "Moody <film>", transfer: DevelopTransfer(settings: settings, fields: fields,
                                                                                          sourceIsRaw: true), group: "Film")
        let text = DevelopPresetFile.xmp(for: preset)
        let back = DevelopPresetFile.read(Data(text.utf8), fileName: "x.xmp")
        assert(back?.preset.name == preset.name && back?.preset.group == "Film" && back?.preset.transfer == preset.transfer
               && back?.skipped.isEmpty == true, "this app's preset file comes back whole, masks included")
        // what Lightroom reads: the same file without the app's own property
        let crsOnly = text.replacingOccurrences(of: #"\s*pc:Preset="[^"]*""#, with: "", options: .regularExpression)
        let asLightroom = DevelopPresetFile.read(Data(crsOnly.utf8), fileName: "x.xmp")?.preset.transfer
        assert(text.contains("crs:Exposure2012=\"+0.35\"") && text.contains("crs:Sharpness=\"60\"")
               && asLightroom?.settings.exposure == 0.35 && asLightroom?.settings.temperature == 6200
               && asLightroom?.settings.sharpening == 20 && asLightroom?.settings.mixer.hue[ColorMixer.Band.blue.rawValue] == -12
               && asLightroom?.settings.grading.shadows == settings.grading.shadows
               && asLightroom.map { abs(ToneCurve.evaluate($0.settings.curve.editablePoints(for: .rgb), at: 0.25) - 0.21) < 0.01 } == true
               && asLightroom?.fields.contains(.masks) == false,
               "the Camera Raw properties carry what Lightroom has")

        let lightroom = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0-c000">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
           crs:PresetType="Normal" crs:Version="15.0" crs:ProcessVersion="11.0" crs:WhiteBalance="As Shot"
           crs:Contrast2012="+15" crs:SaturationAdjustmentOrange="-8" crs:Sharpness="40" crs:ColorNoiseReduction="25"
           crs:SplitToningShadowHue="220" crs:SplitToningShadowSaturation="18" crs:ConvertToGrayscale="False"
           crs:CameraProfile="Adobe Standard" crs:HasSettings="True">
           <crs:Name><rdf:Alt><rdf:li xml:lang="x-default">Matte</rdf:li></rdf:Alt></crs:Name>
           <crs:Group><rdf:Alt><rdf:li xml:lang="x-default">Film Looks</rdf:li></rdf:Alt></crs:Group>
           <crs:ToneCurvePV2012><rdf:Seq><rdf:li>0, 30</rdf:li><rdf:li>255, 240</rdf:li></rdf:Seq></crs:ToneCurvePV2012>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
        let matte = DevelopPresetFile.read(Data(lightroom.utf8), fileName: "matte.xmp")
        let m = matte?.preset.transfer
        assert(matte?.preset.name == "Matte" && matte?.preset.group == "Film Looks"
               && m?.fields == [.whiteBalance, .contrast, .colorMixer, .sharpening, .noiseReduction, .colorGrading, .toneCurve, .profile]
               && m?.settings.profile == nil
               && m?.settings.temperature == nil && m?.settings.contrast == 15
               && m?.settings.mixer.saturation[ColorMixer.Band.orange.rawValue] == -8
               && m?.settings.sharpening == 0 && m?.settings.colorNoise == 0
               && m?.settings.grading.shadows.hue == 220 && m?.settings.grading.shadows.saturation == 18
               && m.map { abs(ToneCurve.evaluate($0.settings.curve.editablePoints(for: .rgb), at: 0) - 30.0 / 255) < 0.001 } == true
               && matte?.skipped.isEmpty == true,
               "a Lightroom preset maps what both apps have, Adobe Standard as Standard")
        func profiled(_ look: String, amount: String) -> DevelopPresetFile.Reading? {
            DevelopPresetFile.read(Data("""
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
             <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
              <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
               crs:PresetType="Normal" crs:Version="15.0" crs:Contrast2012="+10" crs:CameraProfile="Adobe Standard"
               crs:HasSettings="True">
               <crs:Name><rdf:Alt><rdf:li xml:lang="x-default">Look</rdf:li></rdf:Alt></crs:Name>
               <crs:Look>
                <rdf:Description crs:Name="\(look)" crs:Amount="\(amount)" crs:UUID="EA1DE074F188405965EF399C72C221D9"
                 crs:SupportsAmount="false" crs:SupportsMonochrome="false" crs:SupportsOutputReferred="false">
                 <crs:Group><rdf:Alt><rdf:li xml:lang="x-default">Profiles</rdf:li></rdf:Alt></crs:Group>
                 <crs:Parameters><rdf:Description crs:Version="15.0" crs:ConvertToGrayscale="False"/></crs:Parameters>
                </rdf:Description>
               </crs:Look>
              </rdf:Description>
             </rdf:RDF>
            </x:xmpmeta>
            """.utf8), fileName: "look.xmp")
        }
        let vivid = profiled("Adobe Vivid", amount: "0.6"), creative = profiled("Modern 01", amount: "1")
        let monochrome = profiled("Adobe Monochrome", amount: "1")
        assert(monochrome?.preset.transfer.settings.profile == "monochrome" && monochrome?.skipped.isEmpty == true,
               "Adobe Monochrome is black and white")
        let grayscale = DevelopPresetFile.read(Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
         <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" crs:ConvertToGrayscale="True"
          crs:GrayMixerRed="+20" crs:GrayMixerBlue="-35" crs:HasSettings="True"/>
        </rdf:RDF></x:xmpmeta>
        """.utf8), fileName: "gray.xmp")?.preset.transfer
        assert(grayscale?.settings.profile == "monochrome" && grayscale?.settings.grayMixer[0] == 20
               && grayscale?.settings.grayMixer[ColorMixer.Band.blue.rawValue] == -35 && grayscale?.fields == [.profile, .grayMixer],
               "Camera Raw's black and white and its gray mix map to Monochrome and the mix")
        var bw = DevelopSettings()
        bw.profile = DevelopProfile.monochrome.stored
        bw.grayMixer[ColorMixer.Band.orange.rawValue] = 15
        let bwText = DevelopPresetFile.xmp(for: DevelopPreset(id: "bw", name: "BW", transfer: DevelopTransfer(
            settings: bw, fields: [.profile, .grayMixer], sourceIsRaw: true)))
        assert(bwText.contains(#"crs:ConvertToGrayscale="True""#) && bwText.contains(#"crs:GrayMixerOrange="+15""#),
               "a black-and-white preset tells Lightroom so")
        assert(vivid?.preset.transfer.settings.profile == "vivid" && vivid?.preset.transfer.settings.profileAmount == 60
               && vivid?.preset.transfer.fields == [.contrast, .profile] && vivid?.skipped.isEmpty == true,
               "a Lightroom profile with a near one here becomes it, at its amount")
        assert(creative?.preset.transfer.settings.profile == nil && creative?.preset.transfer.fields == [.contrast]
               && creative?.skipped == [.profile], "a creative profile with none near is left out and said so")
        assert(DevelopPresetFile.read(Data("not xml".utf8), fileName: "a.xmp") == nil
               && DevelopPresetFile.read(Data(#"<x:xmpmeta xmlns:x="adobe:ns:meta/"/>"#.utf8), fileName: "b.xmp") == nil,
               "files that aren't presets are refused")

        // importing and exporting through the app: taken names get a number
        let app = AppState.selfCheckFixture()
        let savedPresets = app.developPresets
        defer { app.developPresets = savedPresets }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pc-presets-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let written = AppState.writeDevelopPresets([preset, preset], to: folder)
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        assert(written == 2 && files == ["Moody -film-.xmp", "Moody -film- 2.xmp"].sorted(),
               "exported presets never overwrite a file")
        try? Data("garbage".utf8).write(to: folder.appendingPathComponent("garbage.xmp"))
        let before = app.developPresets.count
        let result = app.importDevelopPresets(from: (files + ["garbage.xmp"]).map { folder.appendingPathComponent($0) })
        let names = app.developPresets.dropFirst(before).map(\.name)
        assert(result.added == 2 && result.failed == 1 && names == ["Moody <film>", "Moody <film> 2"],
               "importing adds each preset once under a free name and counts what it couldn't read")
    }
}
