// ============================================================
//  Domain models
// ============================================================
import Foundation

/// Pick/reject flag — `pick_flag` in the PRD schema.
enum Flag: String, Hashable, Sendable {
    case none, pick, reject
}

/// Original-file accessibility state — `status` in the PRD schema.
enum AssetStatus: String, Hashable, Sendable {
    case ready, offline, missing
}

/// A photo asset — the in-memory analogue of the `assets` table (§10.2).
struct Asset: Identifiable, Equatable, Sendable {
    let id: String
    let pid: Int
    let ori: String          // "p" portrait / "l" landscape
    let thumb: String        // remote thumbnail URL
    let preview: String      // remote preview URL
    var filename: String
    let type: String         // ARW / CR3 / NEF / RAF / DNG / HEIC
    let isRaw: Bool
    var folderId: String
    var folderName: String
    var date: Date           // capture date (mutable for batch time shift, §4.2)
    let width: Int
    let height: Int
    let orientation: Int
    let camera: String
    let lens: String
    let focal: Int
    let aperture: Double
    let shutter: String
    let iso: Int
    let colorSpace: String
    var hasICCProfile: Bool = false
    var fileMB: Double
    var fileModifiedAt: Date? = nil
    var fileCreatedAt: Date? = nil

    // user metadata (mutable)
    var rating: Int
    var flag: Flag
    var colorLabel: ColorLabel?
    var keywords: [String]
    var title: String
    var caption: String
    var author: String = ""
    var copyright: String = ""
    var makerNotes: String = ""
    var project: String = ""
    var client: String = ""

    let location: String
    let gps: (Double, Double)
    var gpsAltitude: Double? = nil
    var status: AssetStatus
    var importedAt: Date
    var deleted: Bool = false

    // ---- real-pipeline fields (defaults keep demo data source-compatible) ----
    var localPath: String? = nil               // original file on disk (nil for demo assets)
    var captureDateSource: String = "EXIF · DateTimeOriginal"
    var contentHash: String? = nil
    var quickHash: String? = nil
    var isDemo: Bool = true                     // false once scanned from a real folder
    var faces: Int = 0                          // Vision-detected face count (§4.3)
    var perceptualHash: UInt64? = nil           // cached dHash for similar-photo grouping (§6.10)

    var megapixels: Double { Double(width * height) / 1_000_000 }
    var hasGPS: Bool { Self.hasGPSCoordinates(gps, location: location) }

    static func hasGPSCoordinates(_ gps: (Double, Double), location: String) -> Bool {
        if !(gps.0 == 0 && gps.1 == 0) { return true }
        let parts = location.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 2,
              let latitude = Double(parts[0]),
              let longitude = Double(parts[1]) else { return false }
        return (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    static func == (lhs: Asset, rhs: Asset) -> Bool { lhs.id == rhs.id }
}

/// A scanned source folder collection.
struct Folder: Identifiable, Hashable {
    let id: String
    let name: String
    var status: String = "online"
}

struct FolderTreeItem: Identifiable, Hashable, Sendable {
    let id: String
    let sourceId: String
    let name: String
    let status: String
    let depth: Int
    let directoryPath: String?

    var isSourceRoot: Bool { directoryPath == nil }
}

struct RecentCatalog: Identifiable, Equatable, Sendable {
    let path: String
    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var parentPath: String { URL(fileURLWithPath: path).deletingLastPathComponent().path }
}

enum ExportDirectoryStructure: String, CaseIterable, Sendable {
    case flat
    case date
    case sourceFolder
    case album
}

enum ImportDuplicateStrategy: String, CaseIterable, Sendable {
    case keep
    case skipExact
    case groupExact
}

/// Manual album (`albums` table, type = album).
struct Album: Identifiable, Hashable {
    let id: String
    let name: String
    var assetIds: [String]
}

/// Smart album — name + rule + cached match count.
struct SmartAlbum: Identifiable {
    let id: String
    let name: String
    var rule: SmartRule
    var count: Int
}

/// A keyword with its asset count for the sidebar.
struct KeywordCount: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let count: Int
}

/// A detected duplicate group (`duplicate_groups` / `duplicate_items`).
struct DuplicateGroup: Identifiable {
    let id: String
    let method: String   // contentHash / perceptualHash
    let score: Double
    let items: [Asset]
}

struct PhotoStack: Identifiable, Equatable, Sendable {
    let id: String
    let method: String
    let assetIds: [String]

    var count: Int { assetIds.count }
}

enum DuplicateResolutionAction {
    case removeFromCatalog
    case moveToTrash
}

/// Sidebar / navigation selection.
struct Selection: Equatable {
    enum Kind: String, Codable { case lib, folder, album, smart, keyword, project, client }
    var type: Kind
    var id: String
    var name: String
}

struct PinnedSidebarItem: Identifiable, Equatable, Codable, Sendable {
    let type: Selection.Kind
    let selectionId: String
    var name: String

    var id: String { "\(type.rawValue):\(selectionId)" }
}

enum ViewMode: String { case grid, loupe, compare }

/// Active filter-bar state.
struct Filters: Equatable, Sendable {
    var minRating: Int = 0
    var flag: String = "any"     // any / pick / reject
    var color: String = "any"    // any / red / orange / ...
    var type: String = "any"     // any / RAW / HEIC
    var camera: String = ""
    var lens: String = ""
    var date: String = "any"     // any / thisMonth / thisYear
    var gps: String = "any"      // any / yes / no
    var status: String = "any"   // any / ready / missing / offline

    var activeCount: Int {
        (minRating > 0 ? 1 : 0) + (flag != "any" ? 1 : 0)
            + (color != "any" ? 1 : 0) + (type != "any" ? 1 : 0)
            + (!camera.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 1 : 0)
            + (!lens.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 1 : 0)
            + (date != "any" ? 1 : 0) + (gps != "any" ? 1 : 0)
            + (status != "any" ? 1 : 0)
    }
    var isEmpty: Bool { activeCount == 0 }

    func smartConditions(search: String) -> [SmartCondition] {
        var conditions: [SmartCondition] = []
        if minRating > 0 {
            conditions.append(SmartCondition(field: "rating", op: ">=", value: "\(minRating)"))
        }
        if flag != "any" {
            conditions.append(SmartCondition(field: "flag", op: "=", value: flag))
        }
        if color != "any" {
            conditions.append(SmartCondition(field: "colorLabel", op: "=", value: color))
        }
        if type != "any" {
            conditions.append(SmartCondition(field: "type", op: "=", value: type))
        }
        let cameraQuery = camera.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cameraQuery.isEmpty {
            conditions.append(SmartCondition(field: "camera", op: "包含", value: cameraQuery))
        }
        let lensQuery = lens.trimmingCharacters(in: .whitespacesAndNewlines)
        if !lensQuery.isEmpty {
            conditions.append(SmartCondition(field: "lens", op: "包含", value: lensQuery))
        }
        if date != "any" {
            conditions.append(SmartCondition(field: "datePreset", op: "=", value: date))
        }
        if gps != "any" {
            conditions.append(SmartCondition(field: "gps", op: "=", value: gps))
        }
        if status != "any" {
            conditions.append(SmartCondition(field: "status", op: "=", value: status))
        }
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            conditions.append(SmartCondition(field: "search", op: "包含", value: q))
        }
        return conditions
    }
}

/// Sort descriptor for the content header.
struct Sort: Equatable, Sendable {
    enum Field: String, CaseIterable, Sendable { case capture, imported, name, rating, size
        var label: String {
            switch self {
            case .capture: return "拍摄时间"
            case .imported: return "导入时间"
            case .name: return "文件名"
            case .rating: return "评分"
            case .size: return "文件大小"
            }
        }
    }
    var field: Field = .capture
    var descending: Bool = true
}

/// A transient toast notification.
struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let icon: String
}
