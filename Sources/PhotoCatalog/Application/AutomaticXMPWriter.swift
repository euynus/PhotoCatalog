import Foundation

actor AutomaticXMPWriter {
    private var latestSequenceByAssetID: [String: UInt64] = [:]
    /// Each sidecar's modification time right after our own last write to it, by path. A write
    /// queued before that one ran knows only the time from before it, and our own write is no
    /// change made elsewhere; a RAW and its JPEG share one sidecar, written one after the other.
    private var ownWriteTimes: [String: Double] = [:]

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

            let sidecar = asset.localPath.map { XMPSidecar.sidecarURL(for: URL(fileURLWithPath: $0)) }
            let ownWrite = sidecar.flatMap { ownWriteTimes[$0.path] }
            switch Self.writeUnlessChanged(asset, baseline: baselines[asset.id], ownWrite: ownWrite, sidecar: sidecar) {
            case .written(let time):
                written[asset.id] = time
                if let sidecar, let time { ownWriteTimes[sidecar.path] = time }
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

    /// Writes one photo's sidecar, unless another app changed it since we last knew it: since
    /// `baseline` (its time when we last read or wrote it, as of the edit) or `ownWrite` (its
    /// time after our own last write), whichever is later. That change is the user's to read first.
    nonisolated static func writeUnlessChanged(_ asset: Asset, baseline: Double?, ownWrite: Double? = nil,
                                               sidecar: URL? = nil) -> Outcome {
        // a virtual copy shares its master's sidecar and never writes it, as in Lightroom
        guard !asset.deleted, !asset.isDemo, !asset.isVirtualCopy, let path = asset.localPath,
              FileManager.default.fileExists(atPath: path) else { return .skipped }
        let sidecar = sidecar ?? XMPSidecar.sidecarURL(for: URL(fileURLWithPath: path))
        if let known = [baseline, ownWrite].compactMap({ $0 }).max(),
           let time = XMPSidecar.modificationTime(of: sidecar), abs(time - known) > 1 {
            return .changedElsewhere
        }
        guard XMPSidecar.write(asset, to: sidecar) else { return .failed }
        return .written(XMPSidecar.modificationTime(of: sidecar))
    }
}
