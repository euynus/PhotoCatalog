// ============================================================
//  RelocationService - find a moved original selected by the user
//  using filename, size, dimensions, and content hash.
// ============================================================
import Foundation

enum RelocationService {
    static func replacement(for asset: Asset, selected url: URL) -> URL? {
        let candidates = candidateURLs(from: url)
        guard !candidates.isEmpty else { return nil }

        // a file whose bytes were read and aren't the photo's is another photo, whatever it's called
        var otherContent: Set<URL> = []
        if let hash = asset.contentHash {
            for candidate in candidates where likelySameKind(asset, candidate) {
                guard let candidateHash = HashService.contentHash(candidate) else { continue }
                if candidateHash == hash {
                    return candidate
                }
                otherContent.insert(candidate)
            }
        }

        return candidates
            .filter { !otherContent.contains($0) }
            .map { (url: $0, match: matchScore(asset, $0)) }
            // a name says little (camera counters repeat): what the file holds must back it up
            .filter { $0.match.contents >= 5 && $0.match.total >= 6 }
            .map { (url: $0.url, score: $0.match.total) }
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

    /// How well `url` matches: in all, and from what the file holds (size, dimensions, capture
    /// time) rather than what it's called — at least two of those three must agree.
    private static func matchScore(_ asset: Asset, _ url: URL) -> (total: Int, contents: Int) {
        var name = 0, contents = 0
        if url.lastPathComponent == asset.filename { name += 5 }
        if url.pathExtension.uppercased() == asset.type.uppercased() { name += 2 }
        if let mb = fileMB(url), abs(mb - asset.fileMB) < 0.01 { contents += 3 }

        let meta = MetadataReader.read(url)
        if meta.width == asset.width && meta.height == asset.height { contents += 3 }
        if abs(meta.captureDate.timeIntervalSince(asset.date)) < 2 { contents += 2 }
        return (name + contents, contents)
    }

    private static func fileMB(_ url: URL) -> Double? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return nil }
        return Asset.megabytes(bytes: size)
    }
}
