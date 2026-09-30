// ============================================================
//  Update check — the newest release published on GitHub
// ============================================================
import Foundation

enum UpdateChecker {
    /// Releases are published on the project's public GitHub repository.
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/euynus/PhotoCatalog/releases/latest")!

    /// Where releases are read from: GitHub, or a feed named by `PC_UPDATE_FEED` (an https or
    /// file URL, for trying an update before it's published). A release from either still has to
    /// carry the app's own signature to be installed.
    static var feedURL: URL {
        if let text = ProcessInfo.processInfo.environment["PC_UPDATE_FEED"], let url = URL(string: text),
           url.isFileURL || url.scheme == "https" {
            return url
        }
        return latestReleaseURL
    }

    struct Release: Decodable, Equatable {
        let tagName: String
        let htmlURL: URL
        var assets: [Asset] = []

        struct Asset: Decodable, Equatable {
            let name: String
            let downloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case downloadURL = "browser_download_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }

        init(tagName: String, htmlURL: URL, assets: [Asset] = []) {
            self.tagName = tagName
            self.htmlURL = htmlURL
            self.assets = assets
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tagName = try container.decode(String.self, forKey: .tagName)
            htmlURL = try container.decode(URL.self, forKey: .htmlURL)
            assets = try container.decodeIfPresent([Asset].self, forKey: .assets) ?? []
        }

        /// "v1.2" → "1.2".
        var version: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }

        /// The app as `script/release.sh` publishes it: `PhotoCatalog-<version>.zip`.
        var archive: Asset? { assets.first { $0.name == "PhotoCatalog-\(version).zip" } }
    }

    enum Outcome: Equatable {
        case newer(Release)
        case upToDate
        case unavailable
    }

    /// Asks the feed once: when the user chooses to check, or at most daily when automatic
    /// checks are on.
    static func check(currentVersion: String) async -> Outcome {
        let url = feedURL
        let data: Data
        if url.isFileURL {
            guard let contents = try? Data(contentsOf: url) else { return .unavailable }
            data = contents
        } else {
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            guard let (body, response) = try? await URLSession.shared.data(for: request),
                  let status = (response as? HTTPURLResponse)?.statusCode else { return .unavailable }
            if status == 404 { return .upToDate }   // nothing published yet
            guard status == 200 else { return .unavailable }
            data = body
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data) else { return .unavailable }
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
