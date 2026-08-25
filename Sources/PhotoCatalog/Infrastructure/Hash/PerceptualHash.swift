// ============================================================
//  PerceptualHash — dHash + Hamming-distance similarity grouping
//  (PRD §6.10 DUP-002/003, §12.9 similar duplicates)
// ============================================================
import Foundation
import CoreGraphics
import ImageIO

enum PerceptualHash {
    /// Automatic startup analysis is pairwise. Keep it bounded until the P2
    /// similarity feature moves to an indexed nearest-neighbor implementation.
    static let automaticAnalysisLimit = 5_000

    static func canRunAutomaticAnalysis(assetCount: Int) -> Bool {
        assetCount <= automaticAnalysisLimit
    }

    /// 64-bit difference hash computed from a 9×8 grayscale downscale.
    static func dHash(path: String) -> UInt64? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return dHash(cg)
    }

    static func dHash(_ image: CGImage) -> UInt64? {
        let w = 9, h = 8
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let stride = ctx.bytesPerRow
        let buf = data.bindMemory(to: UInt8.self, capacity: stride * h)
        var hash: UInt64 = 0
        var bit = 0
        for row in 0..<h {
            for col in 0..<(w - 1) {
                if buf[row * stride + col] > buf[row * stride + col + 1] {
                    hash |= (UInt64(1) << UInt64(bit))
                }
                bit += 1
            }
        }
        return hash
    }

    static func hamming(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

    /// Group assets whose cached-thumbnail dHash is within `threshold` (but not exact-content matches).
    static func similarGroups(_ assets: [Asset], threshold: Int = 10) -> [DuplicateGroup] {
        let hashed: [(asset: Asset, hash: UInt64)] = assets.compactMap { a in
            // reuse the persisted dHash; only decode the thumbnail when it's missing
            if let h = a.perceptualHash { return (a, h) }
            guard !a.thumb.isEmpty, !a.thumb.hasPrefix("http"), let h = dHash(path: a.thumb) else { return nil }
            return (a, h)
        }
        var used = Set<String>()
        var groups: [DuplicateGroup] = []
        var n = 0
        for i in hashed.indices {
            let base = hashed[i]
            if used.contains(base.asset.id) { continue }
            var members: [(Asset, Int)] = []
            for j in (i + 1)..<hashed.count {
                let cand = hashed[j]
                if used.contains(cand.asset.id) { continue }
                let d = hamming(base.hash, cand.hash)
                if d <= threshold && base.asset.contentHash != cand.asset.contentHash {
                    members.append((cand.asset, d))
                }
            }
            guard !members.isEmpty else { continue }
            used.insert(base.asset.id)
            members.forEach { used.insert($0.0.id) }
            let worst = members.map { $0.1 }.max() ?? 0
            groups.append(DuplicateGroup(
                id: "dg-sim-\(n)", method: "perceptualHash",
                score: 1.0 - Double(worst) / 64.0,
                items: [base.asset] + members.map { $0.0 }))
            n += 1
        }
        return groups
    }
}
