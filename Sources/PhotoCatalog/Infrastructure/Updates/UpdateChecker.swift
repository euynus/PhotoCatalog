// ============================================================
//  Update check — the newest release published on GitHub
// ============================================================
import Foundation

enum UpdateChecker {
    /// Releases are published on the project's public GitHub repository.
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/euynus/PhotoCatalog/releases/latest")!

    struct Release: Decodable, Equatable {
        let tagName: String
        let htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }

        /// "v1.2" → "1.2".
        var version: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }
    }

    enum Outcome: Equatable {
        case newer(Release)
        case upToDate
        case unavailable
    }

    /// Asks GitHub once, when the user chooses to check; nothing runs in the background.
    static func check(currentVersion: String) async -> Outcome {
        var request = URLRequest(url: latestReleaseURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return .unavailable }
        if status == 404 { return .upToDate }   // nothing published yet
        guard status == 200, let release = try? JSONDecoder().decode(Release.self, from: data) else {
            return .unavailable
        }
        return isNewer(release.version, than: currentVersion) ? .newer(release) : .upToDate
    }

    /// Dotted versions compared number by number: 1.10 is newer than 1.9, 1.0 equals 1.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}
