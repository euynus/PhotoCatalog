// ============================================================
//  Domain models
// ============================================================
import Foundation

/// Pick/reject flag — `pick_flag` in the PRD schema.
enum Flag: String, Hashable {
    case none, pick, reject
}

/// Original-file accessibility state — `status` in the PRD schema.
enum AssetStatus: String, Hashable {
    case ready, offline, missing
}

/// A photo asset — the in-memory analogue of the `assets` table (§10.2).
struct Asset: Identifiable, Equatable {
    let id: String
    let pid: Int
    let ori: String          // "p" portrait / "l" landscape
    let thumb: String        // remote thumbnail URL
    let preview: String      // remote preview URL
    var filename: String
    let type: String         // ARW / CR3 / NEF / RAF / DNG / HEIC
    let isRaw: Bool
    let folderId: String
    let folderName: String
    let date: Date           // capture date
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
    var fileMB: Double

    // user metadata (mutable)
    var rating: Int
    var flag: Flag
    var colorLabel: ColorLabel?
    var keywords: [String]
    var title: String
    var caption: String

    let location: String
    let gps: (Double, Double)
    var status: AssetStatus
    let importedAt: Date
    var deleted: Bool = false

    // ---- real-pipeline fields (defaults keep demo data source-compatible) ----
    var localPath: String? = nil               // original file on disk (nil for demo assets)
    var captureDateSource: String = "EXIF · DateTimeOriginal"
    var contentHash: String? = nil
    var quickHash: String? = nil
    var isDemo: Bool = true                     // false once scanned from a real folder

    var megapixels: Double { Double(width * height) / 1_000_000 }

    static func == (lhs: Asset, rhs: Asset) -> Bool { lhs.id == rhs.id }
}

/// A scanned source folder collection.
struct Folder: Identifiable, Hashable {
    let id: String
    let name: String
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

/// Sidebar / navigation selection.
struct Selection: Equatable {
    enum Kind: String { case lib, folder, album, smart, keyword }
    var type: Kind
    var id: String
    var name: String
}

enum ViewMode: String { case grid, loupe, compare }

/// Active filter-bar state.
struct Filters: Equatable {
    var minRating: Int = 0
    var flag: String = "any"     // any / pick / reject
    var color: String = "any"    // any / red / orange / ...
    var type: String = "any"     // any / RAW / HEIC

    var activeCount: Int {
        (minRating > 0 ? 1 : 0) + (flag != "any" ? 1 : 0)
            + (color != "any" ? 1 : 0) + (type != "any" ? 1 : 0)
    }
    var isEmpty: Bool { activeCount == 0 }
}

/// Sort descriptor for the content header.
struct Sort: Equatable {
    enum Field: String, CaseIterable { case capture, imported, name, rating, size
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
