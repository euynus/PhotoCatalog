// ============================================================
//  RelocationService - find a moved original selected by the user
//  using filename, size, dimensions, and content hash.
// ============================================================
import Foundation

enum RelocationService {
    static func replacement(for asset: Asset, selected url: URL) -> URL? {
        let candidates = candidateURLs(from: url)
        guard !candidates.isEmpty else { return nil }

        if let hash = asset.contentHash {
            for candidate in candidates where likelySameKind(asset, candidate) {
                if HashService.contentHash(candidate) == hash {
                    return candidate
                }
            }
        }

        return candidates
            .map { (url: $0, score: matchScore(asset, $0)) }
            .filter { $0.score >= 6 }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
                }
                return lhs.score > rhs.score
            }
            .first?.url
    }

    private static func candidateURLs(from url: URL) -> [URL] {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        if values?.isRegularFile == true {
            return FileScanner.isSupported(url) ? [url] : []
        }
        guard values?.isDirectory == true else { return [] }
        return FileScanner.scan(url)
    }

    private static func likelySameKind(_ asset: Asset, _ url: URL) -> Bool {
        let filenameMatches = url.lastPathComponent == asset.filename
        let extMatches = url.pathExtension.uppercased() == asset.type.uppercased()
        let sizeMatches = fileMB(url).map { abs($0 - asset.fileMB) < 0.01 } ?? false
        return filenameMatches || (extMatches && sizeMatches)
    }

    private static func matchScore(_ asset: Asset, _ url: URL) -> Int {
        var score = 0
        if url.lastPathComponent == asset.filename { score += 5 }
        if url.pathExtension.uppercased() == asset.type.uppercased() { score += 2 }
        if let mb = fileMB(url), abs(mb - asset.fileMB) < 0.01 { score += 3 }

        let meta = MetadataReader.read(url)
        if meta.width == asset.width && meta.height == asset.height { score += 3 }
        if abs(meta.captureDate.timeIntervalSince(asset.date)) < 2 { score += 2 }
        return score
    }

    private static func fileMB(_ url: URL) -> Double? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return nil }
        return Double(size) / (1024 * 1024)
    }
}
