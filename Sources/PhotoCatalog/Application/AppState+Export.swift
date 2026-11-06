import AppKit
import Foundation

@MainActor
extension AppState {
    // ---------- export presets (§4.2) ----------
    func saveExportPreset(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let preset = ExportPreset(name: trimmed,
                                  directoryStructure: exportDirectoryStructure.rawValue,
                                  writesXMP: exportWritesXMP)
        exportPresets.removeAll { $0.name == trimmed }
        exportPresets.append(preset)
        push("已保存导出预设「\(trimmed)」", "check")
    }
    func applyExportPreset(_ preset: ExportPreset) {
        exportDirectoryStructure = ExportDirectoryStructure(rawValue: preset.directoryStructure) ?? .flat
        exportWritesXMP = preset.writesXMP
        push("已应用导出预设「\(preset.name)」")
    }
    func deleteExportPreset(_ preset: ExportPreset) {
        exportPresets.removeAll { $0.name == preset.name }
    }

    // ---------- rendered export (Lightroom's Export dialog) ----------
    var allRenderedExportPresets: [RenderedExportPreset] { RenderedExportPreset.builtIns + renderedExportPresets }

    struct RenderedExportJob: Sendable {
        let id = UUID()
        let createdAt = Date.now
        let items: [RenderedExportItem]
        let settings: ExportSettings
        let folder: URL
        let history: BackgroundTaskHistory?
        /// The names (lower-cased) of the catalog's originals in `folder`, which it never writes over.
        var originals: Set<String> = []
    }
    struct RenderedExportProgress: Equatable {
        var done: Int
        let total: Int
        var queued: Int
    }
    /// A serial queue of its own: RAW decodes must stay off the Swift cooperative pool, and
    /// one photo at a time bounds memory for 16-bit full-resolution renders.
    static let renderedExportQueue = DispatchQueue(label: "PhotoCatalog.rendered-export", qos: .utility)

    /// Photos the export dialog would write: selected photos with a local original, in view order.
    func renderedExportItems() -> [RenderedExportItem] {
        let ids = selectionTargetIds
        guard !ids.isEmpty else { return [] }
        var ordered = list.filter { ids.contains($0.id) }
        let listed = Set(ordered.map(\.id))
        ordered += ids.subtracting(listed).sorted().compactMap { id in assetIndex[id].map { assets[$0] } }
        return ordered.compactMap { asset in
            guard asset.status == .ready, !asset.isDemo, !asset.deleted, let path = asset.localPath else { return nil }
            return RenderedExportItem(assetId: asset.id, sourcePath: path, isRaw: asset.isRaw,
                                      develop: developSettings[asset.id] ?? .neutral,
                                      originalSize: CGSize(width: asset.width, height: asset.height),
                                      // a virtual copy renders its own look: name it apart from its master's
                                      baseName: (asset.filename as NSString).deletingPathExtension
                                          + (asset.copyName.map { "-" + $0.replacingOccurrences(of: " ", with: "") } ?? ""),
                                      date: asset.date, camera: asset.camera, title: asset.title,
                                      caption: asset.caption, keywords: asset.keywords, rating: asset.rating,
                                      author: asset.author, copyright: asset.copyright, isVideo: asset.isVideo,
                                      gps: RenderedExportItem.location(of: asset), gpsAltitude: asset.gpsAltitude)
        }
    }

    /// The names (lower-cased) of the originals the catalog has in `folder` — a photo's own file,
    /// a RAW's paired JPEG, a photo removed from the catalog but still on disk — which an export
    /// into it never writes over. Compares bytes: it runs over every photo, and catalog paths are
    /// absolute and standardized.
    func originalNames(in folder: URL) -> Set<String> {
        let directory = PathString.standardized(folder.path)
        let spelled = directory.hasSuffix("/") ? directory : directory + "/"
        var prefixes = [Array(spelled.utf8)]
        // /var, /tmp and /etc are firmlinks into /private: a catalog path may be spelled either way
        for firmlink in ["/var/", "/tmp/", "/etc/"] where spelled.hasPrefix(firmlink) {
            prefixes.append(Array(("/private" + spelled).utf8))
        }
        var names = Set<String>()
        for asset in assets {
            guard let path = asset.localPath else { continue }
            for prefix in prefixes where path.utf8.starts(with: prefix) {
                let name = path.utf8.dropFirst(prefix.count)
                guard !name.isEmpty, !name.contains(UInt8(ascii: "/")) else { continue }
                names.insert(String(decoding: name, as: UTF8.self).lowercased())
            }
        }
        return names
    }

    // ---------- export originals (§6.11) ----------
    func exportSelection() {
        let ids = targetIds
        guard !ids.isEmpty else {
            push("请先选择照片", "warning")
            return
        }
        let selected = assets.filter { ids.contains($0.id) && !$0.deleted }
        let real = selectedRealAssetsWithOriginals()
        guard !real.isEmpty else {
            push(selected.allSatisfy(\.isDemo) ? "演示照片没有本地原件可导出" : "没有可导出的本地原件", "warning")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = L("导出到此处")
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let xmp = exportWritesXMP
        let directoryStructure = exportDirectoryStructure
        let albumNamesByAssetId = exportAlbumNamesByAssetId()
        let sourceRootPathsByFolderId = exportSourceRootPathsByFolderId()
        let exportCatalogURL = store?.packageURL
        Task { [weak self, real, dest, xmp, directoryStructure,
                 albumNamesByAssetId, sourceRootPathsByFolderId, exportCatalogURL] in
            let result = await Task.detached(priority: .userInitiated) {
                let report = ExportService.copyOriginals(real, to: dest, xmp: xmp,
                                                         directoryStructure: directoryStructure,
                                                         albumNamesByAssetId: albumNamesByAssetId,
                                                         sourceRootPathsByFolderId: sourceRootPathsByFolderId)
                let jsonOK = ExportService.exportMetadataJSON(real, to: dest.appendingPathComponent("metadata.json"))
                let csvOK = ExportService.exportMetadataCSV(real, to: dest.appendingPathComponent("metadata.csv"))
                return (report: report, metadataOK: jsonOK && csvOK)
            }.value
            self?.finishOriginalExport(result, xmp: xmp, expectedCatalogURL: exportCatalogURL)
        }
    }

    @discardableResult
    func finishOriginalExport(_ result: (report: ExportReport, metadataOK: Bool),
                              xmp: Bool,
                              expectedCatalogURL: URL? = nil) -> Bool {
        if let expectedCatalogURL, store?.packageURL != expectedCatalogURL { return false }
        let xmpNote = xmp
            ? (result.report.xmpFailed > 0 ? L(" · \(result.report.xmpFailed) 个 XMP 失败") : L(" · 含 XMP"))
            : ""
        push(verbatim: L("已导出 \(result.report.copied) 张原件")
             + (result.report.failed > 0 ? L(" · \(result.report.failed) 失败") : "")
             + xmpNote
             + (result.metadataOK ? L(" · 含元数据") : L(" · 元数据失败")), "export")
        return true
    }

    func exportSelectionPreviews() {
        let selected = selectedAssetsWithExportablePreviews()
        guard !selected.isEmpty else {
            push(selectionTargetIds.isEmpty ? "请先选择照片" : "没有可导出的预览图", "warning")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = L("导出预览到此处")
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        let thumbnails = coordinator?.thumbnails
        let previewSize = previewMaxPixel
        let exportCatalogURL = store?.packageURL
        Task { [weak self, selected, dest, thumbnails, previewSize, exportCatalogURL] in
            let report = await Task.detached(priority: .userInitiated) {
                ExportService.exportPreviews(selected, to: dest,
                                             thumbnails: thumbnails,
                                             previewMaxPixel: previewSize)
            }.value
            self?.finishPreviewExport(report, expectedCatalogURL: exportCatalogURL)
        }
    }

    @discardableResult
    func finishPreviewExport(_ report: ExportReport, expectedCatalogURL: URL? = nil) -> Bool {
        if let expectedCatalogURL, store?.packageURL != expectedCatalogURL { return false }
        push(verbatim: L("已导出 \(report.copied) 张预览图")
             + (report.failed > 0 ? L(" · \(report.failed) 失败") : "")
             + (report.skipped > 0 ? L(" · \(report.skipped) 跳过") : ""),
             report.failed > 0 ? "warning" : "export")
        return true
    }

    private func exportAlbumNamesByAssetId() -> [String: String] {
        var names: [String: String] = [:]
        for album in albums {
            for id in album.assetIds where names[id] == nil {
                names[id] = album.name
            }
        }
        return names
    }

    private func exportSourceRootPathsByFolderId() -> [String: String] {
        guard let store, let roots = try? store.loadSourceRoots() else { return [:] }
        return Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0.pathHint) })
    }
}
