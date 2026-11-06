import AppKit
import Foundation

@MainActor
extension AppState {
    // ---------- photo merge ----------
    typealias PhotoMergeKind = PhotoMerge.Kind

    var canMergePhotos: Bool {
        onboarded && sheet == nil && !isMergingPhotos && selectionTargetIds.count >= 2 && canOperateOnSelectedOriginals
    }

    /// The selection's photos with originals on disk, one per file, in list order.
    func photoMergeCandidates() -> [Asset] {
        let ids = selectionTargetIds
        return fileOwners(list.filter { ids.contains($0.id) }).filter { hasExistingOriginal($0) && !$0.isVideo }
    }

    /// 照片 → 照片合并 → HDR… / 全景…: the merge dialog, with a preview.
    func showPhotoMerge(_ kind: PhotoMergeKind) {
        // the right-click menu offers this during a merge too: its dialog's Merge would do nothing
        guard !isMergingPhotos else {
            push(photoMergeKind == .hdr ? "正在合并 HDR…" : "正在合并全景…", "info")
            return
        }
        let targets = photoMergeCandidates()
        guard targets.count >= 2 else {
            push("请选择至少两张有原件的照片", "info")
            return
        }
        guard kind != .hdr || targets.count <= 9 else {
            push("HDR 合并最多 9 张照片", "info")
            return
        }
        guard kind != .panorama || targets.count <= 30 else {
            push("全景合并最多 30 张照片", "info")
            return
        }
        photoMergeTargets = targets
        photoMergeKind = kind
        sheet = "photoMerge"
    }

    /// The light each photo's exposure let in, from its metadata: t·ISO/N².
    nonisolated static func exposureBrightness(_ asset: Asset) -> Double? {
        guard let seconds = CaptureParameter.shutterSeconds(asset.shutter), asset.aperture > 0, asset.iso > 0 else {
            return nil
        }
        return seconds * Double(asset.iso) / (asset.aperture * asset.aperture)
    }

    /// The photos as the merge reads them, with the 35 mm equivalent focal length each file's
    /// metadata gives. The catalog's focal length is the lens's actual one (a phone's 4 mm), read
    /// from the same file, so it says nothing about the equivalent the file doesn't say.
    nonisolated static func photoMergeFrames(_ assets: [Asset]) -> [PhotoMerge.Frame] {
        assets.compactMap { asset in
            asset.localPath.map { path in
                let url = URL(fileURLWithPath: path)
                return PhotoMerge.Frame(url: url, isRaw: asset.isRaw, brightness: exposureBrightness(asset),
                                        focalLength35: PhotoMerge.focalLength35(url: url))
            }
        }
    }

    /// What a merge came to, on its way back from the merge queue.
    private enum PhotoMergeOutcome: Sendable {
        case merged(url: URL, reference: Int, asset: Asset?)
        case unreadable
        case readOnly
        case mismatchedFrame(Int)
        case panorama(PhotoMerge.PanoramaFailure)
    }

    /// Why bracketed photos couldn't be merged to HDR: the frame at `index` isn't the size and
    /// orientation of the first.
    nonisolated static func hdrMismatchMessage(_ index: Int) -> String {
        L("HDR 合并需要尺寸和方向相同的照片：第 \(index + 1) 张与第 1 张不同")
    }

    /// Why a panorama couldn't be made, for the dialog and the toast.
    nonisolated static func panoramaFailureMessage(_ failure: PhotoMerge.PanoramaFailure) -> String {
        switch failure {
        case .unreadable: L("全景合并失败：有照片无法读取")
        case .noOverlap(let index): L("第 \(index + 1) 与第 \(index + 2) 张照片没有足够的重叠，无法拼接")
        case .notMoving(let index): L("第 \(index + 1) 与第 \(index + 2) 张照片几乎没有移动，更像连拍而不是全景")
        case .notPanorama(let index):
            L("第 \(index + 1) 与第 \(index + 2) 张照片的移动方向与其他照片不一致，或上下偏移太大，不像一次连续的全景拍摄")
        }
    }

    /// Merges the dialog's photos — into an HDR photo beside the middle exposure
    /// (`<name>-HDR.tif`), or a panorama beside the first (`<name>-Pano.tif`) — added to the
    /// catalog with that photo's metadata and selected.
    func mergePhotos() {
        let targets = photoMergeTargets, kind = photoMergeKind
        guard targets.count >= 2, !isMergingPhotos, let coordinator, let store else { return }
        let options = hdrOptions
        let catalogURL = store.packageURL
        let previewSize = previewMaxPixel
        let albumId = selection.type == .album ? selection.id : nil
        isMergingPhotos = true
        push(kind == .hdr ? "正在合并 HDR…" : "正在合并全景…", "square.stack.3d.up")
        Task { [weak self, targets, coordinator] in
            let outcome: PhotoMergeOutcome = await withCheckedContinuation { continuation in
                PhotoMerge.queue.async {
                    let frames = Self.photoMergeFrames(targets)
                    guard frames.count == targets.count else { return continuation.resume(returning: .unreadable) }
                    let merged: (image: CIImage, reference: Int)
                    switch PhotoMerge.merge(frames, kind: kind, options: options, maxPixel: nil) {
                    case .success(let found): merged = found
                    case .failure(.unreadable): return continuation.resume(returning: .unreadable)
                    case .failure(.mismatchedFrame(let index)): return continuation.resume(returning: .mismatchedFrame(index))
                    case .failure(.panorama(let failure)): return continuation.resume(returning: .panorama(failure))
                    }
                    let original = frames[merged.reference].url
                    let folder = original.deletingLastPathComponent()
                    guard FileManager.default.isWritableFile(atPath: folder.path) else {
                        return continuation.resume(returning: .readOnly)
                    }
                    let url = Self.freeURL(in: folder, stem: original.deletingPathExtension().lastPathComponent
                                           + (kind == .hdr ? "-HDR" : "-Pano"), extension: "tif")
                    guard PhotoMerge.writeTIFF(merged.image, to: url) else { return continuation.resume(returning: .unreadable) }
                    let imported = coordinator.importFiles([url], from: folder, readSidecar: false,
                                                           previewMaxPixel: previewSize,
                                                           reusingRemovedIds: false).first
                    continuation.resume(returning: .merged(url: url, reference: merged.reference, asset: imported))
                }
            }
            guard let self else { return }
            self.isMergingPhotos = false
            guard self.store?.packageURL == catalogURL else { return }
            switch outcome {
            case .unreadable:
                self.push(kind == .hdr ? "HDR 合并失败：有照片无法读取" : "全景合并失败：有照片无法读取", "warning")
            case .readOnly:
                self.push("参考照片所在的文件夹是只读的，无法保存合并结果", "warning")
            case .mismatchedFrame(let index):
                self.push(verbatim: Self.hdrMismatchMessage(index), "warning")
            case .panorama(let failure):
                self.push(verbatim: Self.panoramaFailureMessage(failure), "warning")
            case .merged(let url, let reference, let asset):
                self.finishExternalEdit([(url, targets[reference], asset)], editor: nil, expected: 1, albumId: albumId)
                self.push(kind == .hdr ? "已合并为 HDR 照片" : "已合并为全景照片", "square.stack.3d.up")
            }
        }
    }
}
