import Foundation

actor AutomaticXMPWriter {
    private var latestSequenceByAssetID: [String: UInt64] = [:]

    /// Writes each photo's sidecar; returns the failures, each written sidecar's new
    /// modification time (so our own writes never read as another app's changes), and the
    /// photos left alone because another app changed their sidecar since `baselines`.
    func write(_ assets: [Asset], sequence: UInt64, baselines: [String: Double] = [:])
        -> (failures: Int, written: [String: Double], changedElsewhere: Set<String>) {
        var failures = 0
        var written: [String: Double] = [:]
        var changedElsewhere = Set<String>()
        for asset in assets {
            let latest = latestSequenceByAssetID[asset.id] ?? 0
            guard sequence >= latest else { continue }
            latestSequenceByAssetID[asset.id] = sequence

            switch Self.writeUnlessChanged(asset, baseline: baselines[asset.id]) {
            case .written(let time): written[asset.id] = time
            case .changedElsewhere: changedElsewhere.insert(asset.id)
            case .failed: failures += 1
            case .skipped: break
            }
        }
        return (failures, written, changedElsewhere)
    }

    enum Outcome: Equatable {
        case written(Double?)
        case changedElsewhere
        case failed
        case skipped
    }

    /// Writes one photo's sidecar, unless another app changed it since `baseline` (its time
    /// when we last read or wrote it): that change is the user's to read first.
    nonisolated static func writeUnlessChanged(_ asset: Asset, baseline: Double?) -> Outcome {
        // a virtual copy shares its master's sidecar and never writes it, as in Lightroom
        guard !asset.deleted, !asset.isDemo, !asset.isVirtualCopy, let path = asset.localPath,
              FileManager.default.fileExists(atPath: path) else { return .skipped }
        if let baseline, let time = XMPSidecar.modificationTime(forOriginal: path), abs(time - baseline) > 1 {
            return .changedElsewhere
        }
        let sidecar = XMPSidecar.sidecarURL(for: URL(fileURLWithPath: path))
        guard XMPSidecar.write(asset, to: sidecar) else { return .failed }
        return .written(XMPSidecar.modificationTime(forOriginal: path))
    }
}
