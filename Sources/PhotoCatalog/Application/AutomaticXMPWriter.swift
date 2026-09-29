import Foundation

actor AutomaticXMPWriter {
    private var latestSequenceByAssetID: [String: UInt64] = [:]

    /// Writes each photo's sidecar; returns the failures and each written sidecar's new
    /// modification time, so our own writes never read as another app's changes.
    func write(_ assets: [Asset], sequence: UInt64) -> (failures: Int, written: [String: Double]) {
        var failures = 0
        var written: [String: Double] = [:]
        for asset in assets {
            let latest = latestSequenceByAssetID[asset.id] ?? 0
            guard sequence >= latest else { continue }
            latestSequenceByAssetID[asset.id] = sequence

            // a virtual copy shares its master's sidecar and never writes it, as in Lightroom
            guard !asset.deleted, !asset.isDemo, !asset.isVirtualCopy, let path = asset.localPath,
                  FileManager.default.fileExists(atPath: path) else { continue }
            let sidecar = XMPSidecar.sidecarURL(for: URL(fileURLWithPath: path))
            if XMPSidecar.write(asset, to: sidecar) {
                written[asset.id] = XMPSidecar.modificationTime(forOriginal: path)
            } else {
                failures += 1
            }
        }
        return (failures, written)
    }
}
