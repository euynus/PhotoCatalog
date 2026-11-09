import Foundation

@MainActor
extension AppState {
    // ---------- develop defaults: RAW defaults and the import preset ----------
    /// Newly imported photos start from their camera's RAW defaults, then the import preset:
    /// saved with a history step for each, not something to undo (the import itself isn't).
    func applyImportDevelopSettings(to fresh: [Asset]) {
        applyImportDevelopSettings(to: fresh, preset: importDevelopPreset)
    }

    /// RAW defaults, then `preset` (the import's, or a tethered session's), on new photos.
    func applyImportDevelopSettings(to fresh: [Asset], preset: DevelopPreset?) {
        var defaults: [String: (name: String, settings: DevelopSettings)] = [:]
        var imported: [String: DevelopSettings] = [:]
        let rawDefaults = rawDefaults
        for asset in fresh where !asset.isDemo && canDevelop(asset) {
            let camera = asset.isRaw ? rawDefaults.preset(forCamera: asset.camera) : nil
            let steps = DevelopPreset.importSteps(from: developSettings[asset.id] ?? .neutral, isRaw: asset.isRaw,
                                                  cameraDefault: camera, preset: preset)
            if let step = steps.camera { defaults[asset.id] = step }
            if let step = steps.preset { imported[asset.id] = step.settings }
        }
        var final = defaults.mapValues(\.settings)
        final.merge(imported) { $1 }
        guard !final.isEmpty else { return }
        do {
            try store?.saveDevelopSettings(final)
        } catch {
            push("导入预设未能保存到目录库", "warning")
            return
        }
        for (id, value) in final { developSettings[id] = value.isNeutral ? nil : value }
        for name in Set(defaults.values.map(\.name)) {
            recordDevelopHistory(defaults.filter { $0.value.name == name }.mapValues(\.settings), name: name, change: .append)
        }
        if let preset { recordDevelopHistory(imported, name: L("导入预设“\(preset.name)”"), change: .append) }
    }

    /// The RAW defaults as chosen in Settings, with the presets they name. Kept until the choices
    /// or the presets change.
    var rawDefaults: RawDefaults {
        // read on a hit too, so a view drawn from the kept value redraws when they change
        let chosen = rawDefaultPresetIds
        _ = developPresets
        if let rawDefaultsCache { return rawDefaultsCache }
        let presets = allDevelopPresets
        let made = RawDefaults(chosen: chosen) { id in presets.first { $0.id == id } }
        rawDefaultsCache = made
        rawDefaultsBuilds += 1
        return made
    }

    /// The preset a RAW photo starts from: its camera's, or every camera's (nil: as shot).
    func rawDefaultPreset(for asset: Asset, in rawDefaults: RawDefaults? = nil) -> DevelopPreset? {
        asset.isRaw ? (rawDefaults ?? self.rawDefaults).preset(forCamera: asset.camera) : nil
    }

    /// Where 复位 returns a photo: its RAW defaults, or as shot. A batch passes `rawDefaults` once.
    func defaultDevelopSettings(for asset: Asset, in rawDefaults: RawDefaults? = nil) -> DevelopSettings {
        rawDefaultPreset(for: asset, in: rawDefaults)
            .map { $0.transfer.applied(to: .neutral, targetIsRaw: asset.isRaw) } ?? .neutral
    }

    /// Sets (or with "", clears) the RAW default of `camera` ("" for every camera).
    func setRawDefaultPreset(_ presetId: String, forCamera camera: String) {
        if presetId.isEmpty { rawDefaultPresetIds[camera] = nil } else { rawDefaultPresetIds[camera] = presetId }
    }

    /// The cameras the catalog's RAW photos came from, for the RAW defaults list.
    var rawCameras: [String] {
        Set(assets.lazy.filter { $0.isRaw && !$0.deleted && !$0.isDemo && !$0.camera.isEmpty }.map(\.camera)).sorted()
    }

    /// 复位: the photo back to its defaults.
    func resetDevelop(_ asset: Asset) {
        commitDevelop([asset.id: defaultDevelopSettings(for: asset)], undoName: L("复位调整"))
    }
}
