import Foundation

actor AutomaticXMPWriter {
    private var latestSequenceByAssetID: [String: UInt64] = [:]

    func write(_ assets: [Asset], sequence: UInt64) -> Int {
        var failures = 0
        for asset in assets {
            let latest = latestSequenceByAssetID[asset.id] ?? 0
            guard sequence >= latest else { continue }
            latestSequenceByAssetID[asset.id] = sequence

            guard !asset.deleted, !asset.isDemo, let path = asset.localPath,
                  FileManager.default.fileExists(atPath: path) else { continue }
            let sidecar = XMPSidecar.sidecarURL(for: URL(fileURLWithPath: path))
            if !XMPSidecar.write(asset, to: sidecar) { failures += 1 }
        }
        return failures
    }
}
