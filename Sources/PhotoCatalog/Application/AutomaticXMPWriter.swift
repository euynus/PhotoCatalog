import Foundation

/// Writes the app's sidecars, automatic and on request alike, one at a time and in the order
/// they were asked for: each write carries the next sequence, and one older than the last
/// written for a photo is skipped rather than landing after it with older values.
actor AutomaticXMPWriter {
    private var latestSequenceByAssetID: [String: UInt64] = [:]
    /// Each sidecar's modification time right after our own last write to it, by path. A write
    /// queued before that one ran knows only the time from before it, and our own write is no
    /// change made elsewhere; a RAW and its JPEG share one sidecar, written one after the other.
    private var ownWriteTimes: [String: Double] = [:]

    /// What a write did: the failures, each written sidecar's new modification time (so our own
    /// writes never read as another app's changes), the photos left alone because another app
    /// changed their sidecar since `baselines`, and those whose original is out of reach (its
    /// drive unplugged), to write once it's back.
    struct Result: Sendable {
        var failures = 0
        var written: [String: Double] = [:]
        var changedElsewhere = Set<String>()
        var unavailable = Set<String>()
        /// Whether RAW+JPEG pairing was on, and the photos whose sidecar that decided (a RAW's
        /// JPEG, the RAW): once it's switched, what was found for them is about other sidecars.
        var pairing = true
        var pairingDependent = Set<String>()
    }

    /// Writes each photo's sidecar. `overwritingChanges` writes one another app changed too, as
    /// Save Metadata to Files does when asked.
    func write(_ assets: [Asset], sequence: UInt64, baselines: [String: Double] = [:],
               overwritingChanges: Bool = false) -> Result {
        var result = Result()
        result.pairing = XMPSidecar.pairsRawAndJpeg
        let paths = assets.compactMap(\.localPath)
        let choicesByPath = Dictionary(zip(paths, XMPSidecar.sidecarChoices(for: paths.map(URL.init(fileURLWithPath:)))),
                                       uniquingKeysWith: { first, _ in first })
        for asset in assets {
            let latest = latestSequenceByAssetID[asset.id] ?? 0
            guard sequence >= latest else { continue }
            latestSequenceByAssetID[asset.id] = sequence

            let choices = asset.localPath.flatMap { choicesByPath[$0] }
            if let choices, choices.paired != choices.unpaired { result.pairingDependent.insert(asset.id) }
            let sidecar = choices.map { result.pairing ? $0.paired : $0.unpaired }
            let ownWrite = overwritingChanges ? nil : sidecar.flatMap { ownWriteTimes[$0.path] }
            let baseline = overwritingChanges ? nil : baselines[asset.id]
            switch Self.writeUnlessChanged(asset, baseline: baseline, ownWrite: ownWrite, sidecar: sidecar) {
            case .written(let time):
                result.written[asset.id] = time
                if let sidecar, let time { ownWriteTimes[sidecar.path] = time }
            case .changedElsewhere: result.changedElsewhere.insert(asset.id)
            case .failed: result.failures += 1
            case .unavailable: result.unavailable.insert(asset.id)
            case .skipped: break
            }
        }
        return result
    }

    enum Outcome: Equatable {
        case written(Double?)
        case changedElsewhere
        case failed
        /// The original isn't there to write beside (its drive is unplugged, say).
        case unavailable
        /// Nothing to write: a demo photo, a virtual copy, one removed from the catalog.
        case skipped
    }

    /// Writes one photo's sidecar, unless another app changed it since we last knew it: since
    /// `baseline` (its time when we last read or wrote it, as of the edit) or `ownWrite` (its
    /// time after our own last write), whichever is later. That change is the user's to read first.
    nonisolated static func writeUnlessChanged(_ asset: Asset, baseline: Double?, ownWrite: Double? = nil,
                                               sidecar: URL? = nil) -> Outcome {
        // a virtual copy shares its master's sidecar and never writes it, as in Lightroom
        guard !asset.deleted, !asset.isDemo, !asset.isVirtualCopy, let path = asset.localPath else { return .skipped }
        guard FileManager.default.fileExists(atPath: path) else { return .unavailable }
        let sidecar = sidecar ?? XMPSidecar.sidecarURL(for: URL(fileURLWithPath: path))
        if let known = [baseline, ownWrite].compactMap({ $0 }).max(),
           let time = XMPSidecar.modificationTime(of: sidecar), abs(time - known) > 1 {
            return .changedElsewhere
        }
        guard XMPSidecar.write(asset, to: sidecar) else { return .failed }
        return .written(XMPSidecar.modificationTime(of: sidecar))
    }
}
