import Foundation

struct ImportSourceFile: Equatable, Sendable {
    let path: String
    let byteCount: Int?
    let modifiedAt: Double?

    init(url: URL) {
        path = url.path
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        byteCount = values?.fileSize
        modifiedAt = values?.contentModificationDate?.timeIntervalSince1970
    }

    init(path: String, byteCount: Int?, modifiedAt: Double?) {
        self.path = path
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
    }
}

struct ImportFileCheckpoint: Sendable {
    enum Outcome: String, Sendable { case saved, skipped, failed }
    let source: ImportSourceFile
    let assetId: String?
    let outcome: Outcome
    var reason: String?

    func matches(_ url: URL) -> Bool {
        guard source.byteCount != nil, source.modifiedAt != nil else { return false }
        return source == ImportSourceFile(url: url)
    }
}

/// Freeze import choices so a restart cannot silently apply different metadata or presets.
struct ImportOptionsSnapshot: Codable, Equatable, Sendable {
    var duplicateStrategy: String
    var keywords: [String]
    var colorLabel: String?
    var author: String
    var copyright: String
    var albumName: String
    var albumId: String?
    var preset: DevelopPreset?
    var rawDefaults: [String: DevelopPreset]
    var rawDefaultOptOuts: Set<String>
    var bookmark: Data?

    var postActions: ImportPostActions {
        ImportPostActions(keywords: keywords, colorLabel: colorLabel.flatMap(ColorLabel.init(rawValue:)),
                          author: author, copyright: copyright)
    }

    func developSteps(for asset: Asset) -> [(name: String, settings: DevelopSettings)] {
        guard !asset.isVideo else { return [] }
        var steps: [(name: String, settings: DevelopSettings)] = []
        var settings = DevelopSettings.neutral
        if asset.isRaw, !rawDefaultOptOuts.contains(asset.camera),
           let camera = rawDefaults[asset.camera] ?? rawDefaults[""] {
            settings = camera.transfer.applied(to: settings, targetIsRaw: true)
            if !settings.isNeutral { steps.append((L("RAW 默认设置“\(camera.name)”"), settings)) }
        }
        if let preset {
            let applied = preset.transfer.applied(to: settings, targetIsRaw: asset.isRaw)
            if applied != settings { steps.append((L("导入预设“\(preset.name)”"), applied)) }
        }
        return steps
    }
}
