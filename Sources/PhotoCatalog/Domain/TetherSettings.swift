// ============================================================
//  Tethered capture — a shooting session's settings and the names its shots take
// ============================================================
import Foundation

/// A tethered session, as in Lightroom: shots from a camera on a cable, or from a folder
/// another app saves them to, land in a folder named for the session, take the session's name
/// if asked, get a develop preset and keywords, and show at once.
struct TetherSettings: Codable, Equatable, Sendable {
    enum Naming: String, Codable, CaseIterable, Sendable {
        /// The camera's own file names.
        case original
        /// The session's name and a number: "Studio-0001.CR3".
        case sessionSequence

        var title: String {
            switch self {
            case .original: L("原文件名")
            case .sessionSequence: L("会话名-序号")
            }
        }
    }

    var sessionName = ""
    /// Where sessions are kept: each gets a folder by its name inside.
    var destinationPath = TetherSettings.defaultDestination
    var naming: Naming = .sessionSequence
    /// A develop preset every shot gets ("" for none).
    var presetId = ""
    /// Keywords every shot gets, comma separated.
    var keywords = ""
    /// Auto import: the folder another app saves shots to; "" takes shots from a camera.
    var watchedFolderPath = ""

    static var defaultDestination: String {
        // resolved: a sandboxed copy is given its container's link to Pictures
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].resolvingSymlinksInPath()
            .appendingPathComponent("PhotoCatalog Tether", isDirectory: true).path
    }

    init() {}

    /// The session's folder name: its name, or the day's date when it has none. Slashes and
    /// colons, which can't be in a file name, become dashes.
    func folderName(on date: Date = .now) -> String {
        let name = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            let format = DateFormatter()
            format.dateFormat = "yyyy-MM-dd"
            return L("联机拍摄 \(format.string(from: date))")
        }
        return name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }
}

extension TetherSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionName = try c.decodeIfPresent(String.self, forKey: .sessionName) ?? ""
        destinationPath = try c.decodeIfPresent(String.self, forKey: .destinationPath) ?? Self.defaultDestination
        naming = try c.decodeIfPresent(Naming.self, forKey: .naming) ?? .sessionSequence
        presetId = try c.decodeIfPresent(String.self, forKey: .presetId) ?? ""
        keywords = try c.decodeIfPresent(String.self, forKey: .keywords) ?? ""
        watchedFolderPath = try c.decodeIfPresent(String.self, forKey: .watchedFolderPath) ?? ""
    }
}

/// Names a session's shots as they arrive. With the session's name, a RAW and the JPEG shot
/// with it share one number; numbering goes on after the shots already in the folder, so a
/// session picked up again doesn't overwrite any; and a name that's taken gets "_1".
struct TetherNamer {
    let prefix: String
    let naming: TetherSettings.Naming
    /// Each camera file name's number, and the extensions already named with it.
    private var numbers: [String: (number: Int, extensions: Set<String>)] = [:]
    private var next = 1
    private var taken: Set<String>

    init(session: String, naming: TetherSettings.Naming, existing: [String]) {
        prefix = session
        self.naming = naming
        taken = Set(existing.map { $0.lowercased() })
        let start = (session + "-").lowercased()
        for name in existing {
            let stem = (name as NSString).deletingPathExtension.lowercased()
            guard stem.hasPrefix(start), let number = Int(stem.dropFirst(start.count)) else { continue }
            next = max(next, number + 1)
        }
    }

    mutating func name(for original: String) -> String {
        let ext = (original as NSString).pathExtension
        let stem = (original as NSString).deletingPathExtension
        let base: String
        switch naming {
        case .original:
            base = stem
        case .sessionSequence:
            let key = stem.lowercased()
            // the same camera name and extension again is a new shot (the camera's counter rolled over)
            if let known = numbers[key], !known.extensions.contains(ext.lowercased()) {
                numbers[key]?.extensions.insert(ext.lowercased())
                base = Self.numbered(prefix, known.number)
            } else {
                numbers[key] = (next, [ext.lowercased()])
                base = Self.numbered(prefix, next)
                next += 1
            }
        }
        func named(_ base: String) -> String { ext.isEmpty ? base : base + "." + ext }
        var name = named(base)
        var suffix = 1
        while taken.contains(name.lowercased()) {
            name = named("\(base)_\(suffix)")
            suffix += 1
        }
        taken.insert(name.lowercased())
        return name
    }

    private static func numbered(_ prefix: String, _ number: Int) -> String {
        prefix + "-" + String(format: "%04d", number)
    }
}
