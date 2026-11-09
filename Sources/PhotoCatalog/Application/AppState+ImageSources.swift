import Foundation

@MainActor
extension AppState {
    private func isVerified(_ source: String, for assetId: String) -> Bool {
        verifiedCacheSources[assetId]?.contains(source) == true
    }

    private func markVerified(_ source: String, for assetId: String) {
        verifiedCacheSources[assetId, default: []].insert(source)
    }

    func visibleImageSource(for asset: Asset, requestedSource: String,
                            kind: ThumbnailService.Kind) async -> String {
        if requestedSource.hasPrefix("http") || asset.isDemo {
            return requestedSource
        }

        guard let coordinator,
              let localPath = asset.localPath else {
            return requestedSource
        }

        let original = URL(fileURLWithPath: localPath)
        let fallbackPreview = asset.preview.isEmpty ? nil : URL(fileURLWithPath: asset.preview)

        let assetId = asset.id
        let thumbnails = coordinator.thumbnails
        let resolvedKind = kind.isPreview
            ? ThumbnailService.previewKind(forCachePath: requestedSource, fallbackMaxPixel: previewMaxPixel)
            : kind
        if let settings = developSettings[assetId], !settings.isNeutral {
            let edited = thumbnails.editedCachePath(assetId: assetId, kind: resolvedKind, settings: settings).path
            if isVerified(Self.cacheCheckKey(edited, asset), for: assetId) { return edited }
            // Rotation and crop alone start from the ordinary cached image, not a full RAW render.
            let base = settings.withoutGeometry.isNeutral
                ? await cachedImageSource(for: asset, requestedSource: requestedSource, kind: resolvedKind,
                                          original: original, fallbackPreview: fallbackPreview, thumbnails: thumbnails)
                : nil
            return await editedImageSource(for: asset, settings: settings, kind: resolvedKind,
                                           thumbnails: thumbnails, base: base) ?? requestedSource
        }
        return await cachedImageSource(for: asset, requestedSource: requestedSource, kind: resolvedKind,
                                       original: original, fallbackPreview: fallbackPreview,
                                       thumbnails: thumbnails) ?? requestedSource
    }

    /// What `visibleImageSource` returns, when that is already known without touching the disk
    /// (the cache file was verified earlier this session); nil when it would have to check or
    /// render. Lets the loupe show a prefetched neighbor in the same frame as the arrow key.
    func verifiedImageSource(for asset: Asset, requestedSource: String, kind: ThumbnailService.Kind) -> String? {
        if requestedSource.hasPrefix("http") || asset.isDemo { return requestedSource }
        guard let coordinator, asset.localPath != nil else { return requestedSource }
        let resolvedKind = kind.isPreview
            ? ThumbnailService.previewKind(forCachePath: requestedSource, fallbackMaxPixel: previewMaxPixel)
            : kind
        if let settings = developSettings[asset.id], !settings.isNeutral {
            let edited = coordinator.thumbnails.editedCachePath(assetId: asset.id, kind: resolvedKind, settings: settings).path
            return isVerified(Self.cacheCheckKey(edited, asset), for: asset.id) ? edited : nil
        }
        if isVerified(Self.cacheCheckKey(requestedSource, asset), for: asset.id) { return requestedSource }
        let own = coordinator.thumbnails.cachePath(assetId: asset.id, kind: resolvedKind).path
        return isVerified(Self.cacheCheckKey(own, asset), for: asset.id) ? own : nil
    }

    /// A checked cache file, as of the original's modification date: one the original has
    /// changed since is checked again.
    private static func cacheCheckKey(_ source: String, _ asset: Asset) -> String {
        "\(source)|\(asset.fileModifiedAt?.timeIntervalSince1970 ?? 0)"
    }

    /// The ordinary (unadjusted) cached image, repaired from the original when missing or damaged.
    private func cachedImageSource(for asset: Asset, requestedSource: String, kind resolvedKind: ThumbnailService.Kind,
                                   original: URL, fallbackPreview: URL?,
                                   thumbnails: ThumbnailService) async -> String? {
        let assetId = asset.id
        let localPath = original.path
        // A cache file already checked this session (exists, fresh, not a black RAW render)
        // skips the stat + decode hops every time its cell scrolls back into view.
        if isVerified(Self.cacheCheckKey(requestedSource, asset), for: assetId) { return requestedSource }
        // The photo's own cache file, where a repair writes. The stored path can be another: a
        // virtual copy's is its master's, and a catalog moved since keeps the old place. With that
        // gone, the photo's own file is the one to look for, or a remade one would show once
        // and then the placeholder.
        let own = thumbnails.cachePath(assetId: assetId, kind: resolvedKind).path
        if own != requestedSource, isVerified(Self.cacheCheckKey(own, asset), for: assetId) { return own }
        let candidates = own == requestedSource ? [own] : [requestedSource, own]
        let usable = await Task.detached(priority: .userInitiated) { () -> String? in
            candidates.first { source in
                guard !source.isEmpty, FileManager.default.fileExists(atPath: source) else { return false }
                let cached = URL(fileURLWithPath: source)
                return !ThumbnailService.cacheIsStale(cache: cached, originalModificationDate: asset.fileModifiedAt)
                    && !thumbnails.cachedRepresentationNeedsRegeneration(at: cached, original: original, kind: resolvedKind)
            }
        }.value
        if let usable {
            markVerified(Self.cacheCheckKey(usable, asset), for: assetId)
            return usable
        }
        // Only touch a referenced original after the local cache is missing, stale, or damaged.
        let (originalExists, previewExists) = await Task.detached(priority: .userInitiated) {
            [localPath, preview = asset.preview] in
            let fm = FileManager.default
            return (fm.fileExists(atPath: localPath),
                    !preview.isEmpty && fm.fileExists(atPath: preview))
        }.value
        guard originalExists || previewExists else {
            return nil
        }
        // A repair that failed isn't tried again this session: a RAW that decodes black again
        // must not cost another multi-second decode every time its cell reappears. One that
        // worked is remembered as a checked file instead, until a prune or a removal from the
        // catalog drops that (it may have deleted the file), and then the file is made again.
        let repairKey = "\(assetId)|\(resolvedKind)"
        if repairsInFlight[repairKey] != nil {
            await withCheckedContinuation { repairsInFlight[repairKey, default: []].append($0) }
            // that repair is done (or was cancelled before it started): look again
            return await cachedImageSource(for: asset, requestedSource: requestedSource, kind: resolvedKind,
                                           original: original, fallbackPreview: fallbackPreview, thumbnails: thumbnails)
        }
        guard !failedCacheRepairs.contains(repairKey) else { return nil }
        repairsInFlight[repairKey] = []
        defer { repairsInFlight.removeValue(forKey: repairKey)?.forEach { $0.resume() } }
        guard let restored = await ThumbnailRepairQueue.run(.visible, { () -> (url: URL?, usable: Bool) in
            let made = thumbnails.ensureCached(from: original,
                                               fallbackPreview: fallbackPreview,
                                               catalogModificationDate: asset.fileModifiedAt,
                                               assetId: assetId,
                                               kind: resolvedKind)
            return (made, made.map {
                !thumbnails.cachedRepresentationNeedsRegeneration(at: $0, original: original, kind: resolvedKind)
            } ?? false)
        }) else {
            return nil   // cancelled while queued; retry when shown again
        }
        // a remade file is as good as a checked one: the loupe can then show a prefetched
        // neighbor in the same frame as the arrow key instead of checking the disk first
        if restored.usable, let path = restored.url?.path {
            markVerified(Self.cacheCheckKey(path, asset), for: assetId)
        } else {
            failedCacheRepairs.insert(repairKey)
        }
        return restored.url?.path
    }

    /// Developed rendering for an adjusted photo, rendered off the cooperative pool when missing.
    /// `base` (an already-rendered image) replaces the original; an unavailable original falls
    /// back to adjusting the cached preview.
    private func editedImageSource(for asset: Asset, settings: DevelopSettings, kind: ThumbnailService.Kind,
                                   thumbnails: ThumbnailService, base: String? = nil) async -> String? {
        let edited = thumbnails.editedCachePath(assetId: asset.id, kind: kind, settings: settings)
        let key = edited.path
        if isVerified(Self.cacheCheckKey(key, asset), for: asset.id) { return key }
        let preview = asset.preview
        let source: (url: URL, isRaw: Bool)?
        if let base {
            source = (URL(fileURLWithPath: base), false)
        } else if asset.status == .ready, let path = asset.localPath {
            source = (URL(fileURLWithPath: path), asset.isRaw)
        } else if !preview.isEmpty, !preview.hasPrefix("http") {
            source = (URL(fileURLWithPath: preview), false)
        } else {
            source = nil
        }
        guard let source else { return nil }
        let assetId = asset.id
        guard let rendered = await ThumbnailRepairQueue.run(.visible, {
            thumbnails.ensureEdited(from: source.url, isRaw: source.isRaw, settings: settings,
                                    assetId: assetId, kind: kind, originalModificationDate: asset.fileModifiedAt)
        }), let rendered else { return nil }
        markVerified(Self.cacheCheckKey(rendered.path, asset), for: assetId)
        return rendered.path
    }
}
