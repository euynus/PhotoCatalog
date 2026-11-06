import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
extension AppState {
    // ----- develop: copy / paste / sync and presets -----
    var allDevelopPresets: [DevelopPreset] { DevelopPreset.builtIns + developPresets }
    /// A new preset offers what the photo has adjusted, leaving out what Copy Settings does by
    /// default: what belongs to that one photo (framing, masks, spots, lens blur). They can be ticked.
    var developPresetDefaultFields: Set<DevelopField> {
        let settings = primaryId.flatMap { developSettings[$0] } ?? .neutral
        let adjusted = Set(DevelopField.allCases.filter { $0.isAdjusted(in: settings) })
            .intersection(DevelopField.defaultCopy)
        return adjusted.isEmpty ? developTransferFields : adjusted
    }
    enum DevelopTransferMode { case copy, sync, preset }

    static let developPresetsKey = "pc_developPresets"
    static let developTransferFieldsKey = "pc_developTransferFields"

    static func store<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.app.set(data, forKey: key) }
    }

    private var primaryCanDevelop: Bool { primary.map(canDevelop) ?? false }
    var canCopyDevelopSettings: Bool { onboarded && sheet == nil && view != .analysis && primaryCanDevelop }
    var canPasteDevelopSettings: Bool { developClipboard != nil && canTransformSelection }
    var canSyncDevelopSettings: Bool { canCopyDevelopSettings && view != .develop && selectionTargetIds.count > 1 }

    /// ⇧⌘C / ⇧⌘S / 存储为预设: the dialog that picks which settings travel.
    func showDevelopTransfer(_ mode: DevelopTransferMode) {
        guard canCopyDevelopSettings, mode != .sync || canSyncDevelopSettings else { return }
        developTransferMode = mode
        sheet = "developTransfer"
    }

    func copyDevelopSettings(fields: Set<DevelopField>) {
        guard let asset = primary, canDevelop(asset) else { return }
        developClipboard = DevelopTransfer(settings: developSettings[asset.id] ?? .neutral, fields: fields,
                                           sourceIsRaw: asset.isRaw)
        push("已拷贝修图设置", "doc.on.doc")
    }

    /// ⇧⌘V: onto the photo in Develop, or every selected photo elsewhere.
    func pasteDevelopSettings() {
        guard let clipboard = developClipboard else { return }
        let count = applyDevelopTransfer(clipboard, to: developTargetIds, undoName: L("粘贴修图设置"))
        if count > 1 { push("已粘贴到 \(count) 张照片", "doc.on.clipboard") }
    }

    /// The right-click menu can't disable itself without rebuilding every cell's menu, so it says why.
    func pasteDevelopSettingsIfCopied() {
        guard developClipboard != nil else {
            push("还没有拷贝修图设置（⇧⌘C）", "info")
            return
        }
        pasteDevelopSettings()
    }

    /// The selected photo's settings onto the rest of the selection.
    func syncDevelopSettings(fields: Set<DevelopField>) {
        guard let source = primary, canDevelop(source) else { return }
        let transfer = DevelopTransfer(settings: developSettings[source.id] ?? .neutral, fields: fields,
                                       sourceIsRaw: source.isRaw)
        let targets = developTargetIds.filter { $0 != source.id }
        let count = applyDevelopTransfer(transfer, to: targets, undoName: L("同步修图设置"))
        push("已同步到 \(count) 张照片", "arrow.triangle.2.circlepath")
    }

    func applyDevelopPreset(_ preset: DevelopPreset) {
        developPresetPreview = nil   // the preview becomes the real thing
        let targets = developTargetIds
        // on the photo in Develop, the preset's Amount can then be turned up or down
        if view == .develop, targets.count == 1, let index = assetIndex[targets[0]] {
            let asset = assets[index]
            let base = developSettings[asset.id] ?? .neutral
            let full = preset.transfer.applied(to: base, targetIsRaw: asset.isRaw)
            developPresetAmountState = DevelopPresetAmount(presetName: preset.name, assetId: asset.id, base: base,
                                                           full: full, amount: 1, result: full)
        }
        applyDevelopTransfer(preset.transfer, to: targets, undoName: L("应用预设“\(preset.name)”"))
    }

    // ----- preset amount: how strongly the last preset applied in Develop takes effect -----
    struct DevelopPresetAmount: Equatable {
        let presetName: String
        let assetId: String
        /// The photo before the preset, and with it at full strength.
        let base: DevelopSettings
        let full: DevelopSettings
        var amount: Double
        /// The settings `amount` gave: the slider shows while the photo is still at them.
        var result: DevelopSettings
    }

    /// The Amount slider's state for the photo `id`, while its settings are still what the
    /// preset (at the last amount) left; any other edit ends it.
    func developPresetAmount(for id: String) -> DevelopPresetAmount? {
        guard let state = developPresetAmountState, state.assetId == id,
              (developSettings[id] ?? .neutral) == state.result else { return nil }
        return state
    }

    /// The preset at `amount` (1 = as saved, up to 2), previewed while the slider drags.
    func setDevelopPresetAmount(_ amount: Double) {
        guard let state = developPresetAmount(for: developPresetAmountState?.assetId ?? "") else { return }
        developPresetAmountDraft = amount
        updateDevelopDraft(presetAmountSettings(state, amount), for: state.assetId)
    }

    /// Saves the dragged amount (or `amount`) as one undoable step.
    func commitDevelopPresetAmount(_ amount: Double? = nil) {
        defer { developPresetAmountDraft = nil }
        guard var state = developPresetAmount(for: developPresetAmountState?.assetId ?? ""),
              let value = amount ?? developPresetAmountDraft else { return }
        let settings = presetAmountSettings(state, value)
        state.amount = value
        state.result = settings
        developPresetAmountState = state
        commitDevelop([state.assetId: settings], undoName: L("预设强度"))
    }

    private func presetAmountSettings(_ state: DevelopPresetAmount, _ amount: Double) -> DevelopSettings {
        let asset = assetIndex[state.assetId].map { assets[$0] }
        let isRaw = asset?.isRaw ?? false
        let origin = isRaw ? developAsShot[state.assetId].map { ($0.temperature, $0.tint) } : (0, 0)
        return DevelopSettings.blend(state.base, state.full, amount: amount, isRaw: isRaw, whiteBalanceOrigin: origin)
    }

    // ----- preset preview: the photo shows a preset's look while the pointer rests on it -----
    struct DevelopPresetPreview {
        let presetId: String
        let assetId: String
        let settings: DevelopSettings
    }

    /// Shows `preset` on the photo in Develop without saving anything. Never over a drag in progress.
    func previewDevelopPreset(_ preset: DevelopPreset, on asset: Asset) {
        if developDraft != nil, developPresetPreview == nil { return }
        let settings = preset.transfer.applied(to: developSettings[asset.id] ?? .neutral, targetIsRaw: asset.isRaw)
        developPresetPreview = DevelopPresetPreview(presetId: preset.id, assetId: asset.id, settings: settings)
        updateDevelopDraft(settings, for: asset.id)
    }

    /// Takes the preview of `presetId` (or any) away, leaving whatever else is being dragged.
    func endDevelopPresetPreview(_ presetId: String? = nil) {
        guard let preview = developPresetPreview, presetId == nil || presetId == preview.presetId else { return }
        developPresetPreview = nil
        if developDraft == DevelopDraft(assetId: preview.assetId, settings: preview.settings) { developDraft = nil }
    }

    /// Saves the selected photo's `fields` as a preset in `group` (nil: 我的预设); a preset of
    /// the same name is replaced.
    func saveDevelopPreset(name: String, fields: Set<DevelopField>, group: String? = nil) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let asset = primary, canDevelop(asset), !name.isEmpty, !fields.isEmpty else { return }
        let transfer = DevelopTransfer(settings: developSettings[asset.id] ?? .neutral, fields: fields,
                                       sourceIsRaw: asset.isRaw)
        let group = Self.presetGroup(group)
        if let index = developPresets.firstIndex(where: { $0.name == name }) {
            developPresets[index].transfer = transfer
            developPresets[index].group = group
        } else {
            developPresets.append(DevelopPreset(id: UUID().uuidString, name: name, transfer: transfer, group: group))
        }
        push("已存储预设“\(name)”", "square.and.arrow.down")
    }

    func deleteDevelopPreset(_ id: String) {
        developPresets.removeAll { $0.id == id }
    }

    /// Asks first: presets aren't part of undo.
    func confirmDeleteDevelopPreset(_ id: String) {
        guard let preset = developPresets.first(where: { $0.id == id }),
              confirmDestructiveAction(L("删除预设“\(preset.name)”？"), L("预设删除后无法恢复，已用它修过的照片不受影响。"),
                                       L("删除")) else { return }
        deleteDevelopPreset(id)
    }

    /// Renames a preset of the user's; a name another preset has is refused.
    @discardableResult
    func renameDevelopPreset(_ id: String, to name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = developPresets.firstIndex(where: { $0.id == id }) else { return false }
        guard !developPresets.contains(where: { $0.name == name && $0.id != id }) else {
            push("已有名为“\(name)”的预设", "warning")
            return false
        }
        developPresets[index].name = name
        return true
    }

    /// The preset's settings replaced by the selected photo's, the same ones it held.
    func updateDevelopPreset(_ id: String) {
        guard let index = developPresets.firstIndex(where: { $0.id == id }), let asset = primary, canDevelop(asset)
        else { return }
        let fields = developPresets[index].transfer.fields
        developPresets[index].transfer = DevelopTransfer(settings: developSettings[asset.id] ?? .neutral, fields: fields,
                                                         sourceIsRaw: asset.isRaw)
        push("已用当前设置更新预设“\(developPresets[index].name)”", "arrow.triangle.2.circlepath")
    }

    /// Lists a preset under `group` (nil or empty: 我的预设).
    func moveDevelopPreset(_ id: String, toGroup group: String?) {
        guard let index = developPresets.firstIndex(where: { $0.id == id }) else { return }
        developPresets[index].group = Self.presetGroup(group)
    }

    /// The user's preset groups, in the order they first appear.
    var developPresetGroups: [String] {
        var seen = Set<String>()
        return developPresets.compactMap(\.group).filter { seen.insert($0).inserted }
    }

    // ----- LUTs: creative looks from .cube files, kept in the app's own folder -----
    /// Adds the 3D LUTs in `urls` to the library, named by their title or file name.
    @discardableResult
    func importLUTs(from urls: [URL]) -> (added: Int, failed: Int) {
        var added = 0, failed = 0
        for url in urls {
            let id = UUID().uuidString
            guard LUTLibrary.add(url, id: id) else { failed += 1; continue }
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let name = LUTLibrary.title(of: text) ?? url.deletingPathExtension().lastPathComponent
            developLUTs.append(DevelopLUT(id: id, name: name))
            added += 1
        }
        return (added, failed)
    }

    /// 导入 LUT…: picks `.cube` files.
    func chooseAndImportLUTs() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.prompt = L("导入")
        panel.message = L("选择 3D LUT 文件（.cube）")
        guard panel.runModal() == .OK else { return }
        let result = importLUTs(from: panel.urls)
        guard result.added > 0 else {
            push("所选文件不是可用的 3D LUT", "warning")
            return
        }
        push(verbatim: L("已导入 \(result.added) 个 LUT") + (result.failed > 0 ? L(" · \(result.failed) 个无法读取") : ""),
             result.failed > 0 ? "warning" : "square.and.arrow.down")
    }

    /// Asks first; photos using it render without it until it's imported again.
    func confirmDeleteLUT(_ id: String) {
        guard let lut = developLUTs.first(where: { $0.id == id }),
              confirmDestructiveAction(L("删除 LUT“\(lut.name)”？"), L("用了这个 LUT 的照片将不再显示它的效果。"), L("删除"))
        else { return }
        developLUTs.removeAll { $0.id == id }
        LUTLibrary.remove(id: id)
    }

    /// The photo's LUT (nil: none), as one undoable step.
    func setDevelopLUT(_ id: String?, for asset: Asset) {
        var next = developSettings[asset.id] ?? .neutral
        guard next.lutId != id else { return }
        next.lutId = id
        if id != nil, next.lutAmount == 0 { next.lutAmount = 100 }
        commitDevelop([asset.id: next], undoName: L("LUT"))
    }

    /// The photo's profile, as one undoable step; a newly chosen profile starts at 100%.
    func setDevelopProfile(_ profile: DevelopProfile, for asset: Asset) {
        endDevelopProfilePreview(profile)
        var next = developSettings[asset.id] ?? .neutral
        guard next.profile != profile.stored else { return }
        next.profile = profile.stored
        next.profileAmount = 100
        commitDevelop([asset.id: next], undoName: L("配置文件“\(profile.title)”"))
    }

    /// Shows `profile` on the photo while the pointer rests on it, the way presets preview.
    func previewDevelopProfile(_ profile: DevelopProfile, on asset: Asset) {
        var settings = DevelopSettings()
        settings.profile = profile.stored
        let preset = DevelopPreset(id: "profile." + profile.rawValue, name: profile.title,
                                   transfer: DevelopTransfer(settings: settings, fields: [.profile], sourceIsRaw: asset.isRaw))
        previewDevelopPreset(preset, on: asset)
    }

    func endDevelopProfilePreview(_ profile: DevelopProfile) {
        endDevelopPresetPreview("profile." + profile.rawValue)
    }

    // ----- preset files -----
    /// Adds the presets in `urls` — XMP files from this app, Lightroom or Camera Raw; a name
    /// already taken gets a number. How many were added, how many couldn't be read, and what
    /// in them had nothing to map to.
    @discardableResult
    func importDevelopPresets(from urls: [URL]) -> (added: Int, failed: Int, skipped: Set<DevelopPresetFile.Skipped>) {
        var added = 0, failed = 0
        var skipped = Set<DevelopPresetFile.Skipped>()
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  var reading = DevelopPresetFile.read(data, fileName: url.lastPathComponent) else {
                failed += 1
                continue
            }
            reading.preset.name = uniquePresetName(reading.preset.name)
            reading.preset.group = Self.presetGroup(reading.preset.group)
            developPresets.append(reading.preset)
            skipped.formUnion(reading.skipped)
            added += 1
        }
        return (added, failed, skipped)
    }

    /// 导入预设…: picks preset files, starting in Camera Raw's presets folder when there is one.
    func chooseAndImportDevelopPresets() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "xmp") ?? .xml]
        panel.prompt = L("导入")
        panel.message = L("选择修图预设：本应用、Lightroom 或 Camera Raw 导出的 .xmp 文件")
        let adobe = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Adobe/CameraRaw/Settings")
        if FileManager.default.fileExists(atPath: adobe.path) { panel.directoryURL = adobe }
        guard panel.runModal() == .OK else { return }
        let result = importDevelopPresets(from: panel.urls)
        guard result.added > 0 else {
            push("所选文件不是可用的修图预设", "warning")
            return
        }
        var message = L("已导入 \(result.added) 个预设")
        if result.failed > 0 { message += L(" · \(result.failed) 个无法读取") }
        if !result.skipped.isEmpty {
            message += L(" · 未导入：") + result.skipped.sorted().map(\.title).joined(separator: L("、"))
        }
        push(verbatim: message, result.failed > 0 || !result.skipped.isEmpty ? "warning" : "square.and.arrow.down")
    }

    /// Writes each preset to `folder` as `<name>.xmp`, never over an existing file. How many were written.
    nonisolated static func writeDevelopPresets(_ presets: [DevelopPreset], to folder: URL) -> Int {
        var taken = Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).map { $0.lowercased() })
        var written = 0
        for preset in presets {
            let base = presetFileName(preset.name)
            var name = base + ".xmp", number = 2
            while taken.contains(name.lowercased()) { name = "\(base) \(number).xmp"; number += 1 }
            taken.insert(name.lowercased())
            let url = folder.appendingPathComponent(name)
            if (try? DevelopPresetFile.xmp(for: preset).write(to: url, atomically: true, encoding: .utf8)) != nil {
                written += 1
            }
        }
        return written
    }

    /// 导出…: one preset to a file, or several to a folder.
    func exportDevelopPresets(_ ids: [String]) {
        let presets = ids.compactMap { id in allDevelopPresets.first { $0.id == id } }
        guard !presets.isEmpty else { return }
        if presets.count == 1 {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = Self.presetFileName(presets[0].name) + ".xmp"
            panel.allowedContentTypes = [UTType(filenameExtension: "xmp") ?? .xml]
            panel.message = L("导出的预设可再导入本应用，也可导入 Lightroom 或 Camera Raw（两者共有的设置）")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            guard (try? DevelopPresetFile.xmp(for: presets[0]).write(to: url, atomically: true, encoding: .utf8)) != nil
            else {
                push("预设导出失败", "warning")
                return
            }
            push("已导出预设“\(presets[0].name)”", "square.and.arrow.up")
        } else {
            guard let folder = NSOpenPanel.chooseFolder(prompt: L("导出到此处")) else { return }
            let written = Self.writeDevelopPresets(presets, to: folder)
            push(verbatim: L("已导出 \(written) 个预设") + (written < presets.count ? L(" · \(presets.count - written) 失败") : ""),
                 written < presets.count ? "warning" : "square.and.arrow.up")
        }
    }

    /// A file name for a preset: the characters a file name can't hold replaced.
    nonisolated static func presetFileName(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines))
            .joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? L("预设") : cleaned
    }

    /// `name`, or `name 2`, `name 3`… when a preset has it.
    private func uniquePresetName(_ name: String) -> String {
        let names = Set(allDevelopPresets.map(\.name))
        guard names.contains(name) else { return name }
        var number = 2
        while names.contains("\(name) \(number)") { number += 1 }
        return "\(name) \(number)"
    }

    private static func presetGroup(_ name: String?) -> String? {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty || trimmed == L("我的预设") ? nil : trimmed
    }
}
