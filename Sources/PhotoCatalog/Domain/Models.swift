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
///
/// Its fields live in one shared, copy-on-write object, so an `Asset` is a single reference:
/// the catalog, every filtered or sorted list and every undo snapshot share photos instead of
/// copying ~700 bytes each (at 500k photos, the difference between ~1 and ~4 GB). Changing a
/// field copies that one photo's storage only when another value still shares it.
struct Asset: Identifiable, Equatable, Sendable {
    // Mutated only through `uniqueStorage()`, i.e. while no other value shares it.
    private final class Storage: @unchecked Sendable {
        var id: String
        var pid: Int
        var ori: String
        var thumb: String
        var preview: String
        var filename: String
        var type: String
        var isRaw: Bool
        var folderId: String
        var folderName: String
        var date: Date
        var width: Int
        var height: Int
        var orientation: Int
        var camera: String
        var lens: String
        var focal: Int
        var aperture: Double
        var shutter: String
        var iso: Int
        var colorSpace: String
        var hasICCProfile: Bool
        var fileMB: Double
        var fileModifiedAt: Date?
        var fileCreatedAt: Date?
        var rating: Int
        var flag: Flag
        var colorLabel: ColorLabel?
        var keywords: [String]
        var title: String
        var caption: String
        var author: String
        var copyright: String
        var makerNotes: String
        var project: String
        var client: String
        var location: String
        var gps: (Double, Double)
        var gpsAltitude: Double?
        var status: AssetStatus
        var importedAt: Date
        var deleted: Bool
        var localPath: String?
        var captureDateSource: String
        var contentHash: String?
        var quickHash: String?
        var isDemo: Bool
        var faces: Int
        var perceptualHash: UInt64?

        init(id: String, pid: Int, ori: String, thumb: String, preview: String, filename: String, type: String, isRaw: Bool, folderId: String, folderName: String, date: Date, width: Int, height: Int, orientation: Int, camera: String, lens: String, focal: Int, aperture: Double, shutter: String, iso: Int, colorSpace: String, hasICCProfile: Bool, fileMB: Double, fileModifiedAt: Date?, fileCreatedAt: Date?, rating: Int, flag: Flag, colorLabel: ColorLabel?, keywords: [String], title: String, caption: String, author: String, copyright: String, makerNotes: String, project: String, client: String, location: String, gps: (Double, Double), gpsAltitude: Double?, status: AssetStatus, importedAt: Date, deleted: Bool, localPath: String?, captureDateSource: String, contentHash: String?, quickHash: String?, isDemo: Bool, faces: Int, perceptualHash: UInt64?) {
            self.id = id
            self.pid = pid
            self.ori = ori
            self.thumb = thumb
            self.preview = preview
            self.filename = filename
            self.type = type
            self.isRaw = isRaw
            self.folderId = folderId
            self.folderName = folderName
            self.date = date
            self.width = width
            self.height = height
            self.orientation = orientation
            self.camera = camera
            self.lens = lens
            self.focal = focal
            self.aperture = aperture
            self.shutter = shutter
            self.iso = iso
            self.colorSpace = colorSpace
            self.hasICCProfile = hasICCProfile
            self.fileMB = fileMB
            self.fileModifiedAt = fileModifiedAt
            self.fileCreatedAt = fileCreatedAt
            self.rating = rating
            self.flag = flag
            self.colorLabel = colorLabel
            self.keywords = keywords
            self.title = title
            self.caption = caption
            self.author = author
            self.copyright = copyright
            self.makerNotes = makerNotes
            self.project = project
            self.client = client
            self.location = location
            self.gps = gps
            self.gpsAltitude = gpsAltitude
            self.status = status
            self.importedAt = importedAt
            self.deleted = deleted
            self.localPath = localPath
            self.captureDateSource = captureDateSource
            self.contentHash = contentHash
            self.quickHash = quickHash
            self.isDemo = isDemo
            self.faces = faces
            self.perceptualHash = perceptualHash
        }

        func copy() -> Storage {
            Storage(id: id, pid: pid, ori: ori, thumb: thumb, preview: preview, filename: filename, type: type, isRaw: isRaw, folderId: folderId, folderName: folderName, date: date, width: width, height: height, orientation: orientation, camera: camera, lens: lens, focal: focal, aperture: aperture, shutter: shutter, iso: iso, colorSpace: colorSpace, hasICCProfile: hasICCProfile, fileMB: fileMB, fileModifiedAt: fileModifiedAt, fileCreatedAt: fileCreatedAt, rating: rating, flag: flag, colorLabel: colorLabel, keywords: keywords, title: title, caption: caption, author: author, copyright: copyright, makerNotes: makerNotes, project: project, client: client, location: location, gps: gps, gpsAltitude: gpsAltitude, status: status, importedAt: importedAt, deleted: deleted, localPath: localPath, captureDateSource: captureDateSource, contentHash: contentHash, quickHash: quickHash, isDemo: isDemo, faces: faces, perceptualHash: perceptualHash)
        }
    }

    private var storage: Storage

    init(id: String,
         pid: Int,
         ori: String,
         thumb: String,
         preview: String,
         filename: String,
         type: String,
         isRaw: Bool,
         folderId: String,
         folderName: String,
         date: Date,
         width: Int,
         height: Int,
         orientation: Int,
         camera: String,
         lens: String,
         focal: Int,
         aperture: Double,
         shutter: String,
         iso: Int,
         colorSpace: String,
         hasICCProfile: Bool = false,
         fileMB: Double,
         fileModifiedAt: Date? = nil,
         fileCreatedAt: Date? = nil,
         rating: Int,
         flag: Flag,
         colorLabel: ColorLabel? = nil,
         keywords: [String],
         title: String,
         caption: String,
         author: String = "",
         copyright: String = "",
         makerNotes: String = "",
         project: String = "",
         client: String = "",
         location: String,
         gps: (Double, Double),
         gpsAltitude: Double? = nil,
         status: AssetStatus,
         importedAt: Date,
         deleted: Bool = false,
         localPath: String? = nil,
         captureDateSource: String = "EXIF · DateTimeOriginal",
         contentHash: String? = nil,
         quickHash: String? = nil,
         isDemo: Bool = true,
         faces: Int = 0,
         perceptualHash: UInt64? = nil) {
        storage = Storage(id: id, pid: pid, ori: ori, thumb: thumb, preview: preview, filename: filename, type: type, isRaw: isRaw, folderId: folderId, folderName: folderName, date: date, width: width, height: height, orientation: orientation, camera: camera, lens: lens, focal: focal, aperture: aperture, shutter: shutter, iso: iso, colorSpace: colorSpace, hasICCProfile: hasICCProfile, fileMB: fileMB, fileModifiedAt: fileModifiedAt, fileCreatedAt: fileCreatedAt, rating: rating, flag: flag, colorLabel: colorLabel, keywords: keywords, title: title, caption: caption, author: author, copyright: copyright, makerNotes: makerNotes, project: project, client: client, location: location, gps: gps, gpsAltitude: gpsAltitude, status: status, importedAt: importedAt, deleted: deleted, localPath: localPath, captureDateSource: captureDateSource, contentHash: contentHash, quickHash: quickHash, isDemo: isDemo, faces: faces, perceptualHash: perceptualHash)
    }

    private mutating func uniqueStorage() -> Storage {
        if !isKnownUniquelyReferenced(&storage) { storage = storage.copy() }
        return storage
    }

    var id: String { storage.id }
    var pid: Int { storage.pid }
    /// "p" portrait / "l" landscape.
    var ori: String { storage.ori }
    /// Cached thumbnail path, or a remote URL for demo photos.
    var thumb: String { storage.thumb }
    /// Cached preview path, or a remote URL for demo photos.
    var preview: String { storage.preview }
    var filename: String {
        get { storage.filename }
        set { uniqueStorage().filename = newValue }
    }
    /// ARW / CR3 / NEF / RAF / DNG / HEIC.
    var type: String { storage.type }
    var isRaw: Bool { storage.isRaw }
    var folderId: String {
        get { storage.folderId }
        set { uniqueStorage().folderId = newValue }
    }
    var folderName: String {
        get { storage.folderName }
        set { uniqueStorage().folderName = newValue }
    }
    /// Capture date (mutable for batch time shift, §4.2).
    var date: Date {
        get { storage.date }
        set { uniqueStorage().date = newValue }
    }
    var width: Int { storage.width }
    var height: Int { storage.height }
    var orientation: Int { storage.orientation }
    var camera: String { storage.camera }
    var lens: String { storage.lens }
    var focal: Int { storage.focal }
    var aperture: Double { storage.aperture }
    var shutter: String { storage.shutter }
    var iso: Int { storage.iso }
    var colorSpace: String { storage.colorSpace }
    var hasICCProfile: Bool {
        get { storage.hasICCProfile }
        set { uniqueStorage().hasICCProfile = newValue }
    }
    var fileMB: Double {
        get { storage.fileMB }
        set { uniqueStorage().fileMB = newValue }
    }
    var fileModifiedAt: Date? {
        get { storage.fileModifiedAt }
        set { uniqueStorage().fileModifiedAt = newValue }
    }
    var fileCreatedAt: Date? {
        get { storage.fileCreatedAt }
        set { uniqueStorage().fileCreatedAt = newValue }
    }
    // user metadata (mutable)
    var rating: Int {
        get { storage.rating }
        set { uniqueStorage().rating = newValue }
    }
    var flag: Flag {
        get { storage.flag }
        set { uniqueStorage().flag = newValue }
    }
    var colorLabel: ColorLabel? {
        get { storage.colorLabel }
        set { uniqueStorage().colorLabel = newValue }
    }
    var keywords: [String] {
        get { storage.keywords }
        set { uniqueStorage().keywords = newValue }
    }
    var title: String {
        get { storage.title }
        set { uniqueStorage().title = newValue }
    }
    var caption: String {
        get { storage.caption }
        set { uniqueStorage().caption = newValue }
    }
    var author: String {
        get { storage.author }
        set { uniqueStorage().author = newValue }
    }
    var copyright: String {
        get { storage.copyright }
        set { uniqueStorage().copyright = newValue }
    }
    var makerNotes: String {
        get { storage.makerNotes }
        set { uniqueStorage().makerNotes = newValue }
    }
    var project: String {
        get { storage.project }
        set { uniqueStorage().project = newValue }
    }
    var client: String {
        get { storage.client }
        set { uniqueStorage().client = newValue }
    }
    var location: String {
        get { storage.location }
        set { uniqueStorage().location = newValue }
    }
    var gps: (Double, Double) {
        get { storage.gps }
        set { uniqueStorage().gps = newValue }
    }
    var gpsAltitude: Double? {
        get { storage.gpsAltitude }
        set { uniqueStorage().gpsAltitude = newValue }
    }
    var status: AssetStatus {
        get { storage.status }
        set { uniqueStorage().status = newValue }
    }
    var importedAt: Date {
        get { storage.importedAt }
        set { uniqueStorage().importedAt = newValue }
    }
    var deleted: Bool {
        get { storage.deleted }
        set { uniqueStorage().deleted = newValue }
    }
    /// Original file on disk (nil for demo assets).
    var localPath: String? {
        get { storage.localPath }
        set { uniqueStorage().localPath = newValue }
    }
    var captureDateSource: String {
        get { storage.captureDateSource }
        set { uniqueStorage().captureDateSource = newValue }
    }
    var contentHash: String? {
        get { storage.contentHash }
        set { uniqueStorage().contentHash = newValue }
    }
    var quickHash: String? {
        get { storage.quickHash }
        set { uniqueStorage().quickHash = newValue }
    }
    /// False once scanned from a real folder.
    var isDemo: Bool {
        get { storage.isDemo }
        set { uniqueStorage().isDemo = newValue }
    }
    /// Vision-detected face count (§4.3).
    var faces: Int {
        get { storage.faces }
        set { uniqueStorage().faces = newValue }
    }
    /// Cached dHash for similar-photo grouping (§6.10).
    var perceptualHash: UInt64? {
        get { storage.perceptualHash }
        set { uniqueStorage().perceptualHash = newValue }
    }

    var megapixels: Double { Double(width * height) / 1_000_000 }

    /// The label stored with coordinates: "30.500, 114.300", or empty without a location.
    static func locationLabel(_ gps: (Double, Double)?) -> String {
        gps.map { String(format: "%.3f, %.3f", $0.0, $0.1) } ?? ""
    }
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
    enum Kind: String, Codable { case lib, folder, album, smart, keyword, project, client, captureDate }
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

enum ViewMode: String { case grid, loupe, compare, develop, analysis }

/// Workspace appearance preference; the photo canvas is dark in every mode.
enum AppAppearance: String, CaseIterable, Sendable {
    case system, light, dark

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
}

/// Active filter-bar state.
struct Filters: Equatable, Sendable {
    var minRating: Int = 0
    var flag: String = "any"     // any / pick / reject
    var color: String = "any"    // any / red / orange / ...
    var type: String = "any"     // any / RAW / HEIC
    var camera: String = ""
    var lens: String = ""
    var date: String = "any"     // any / CaptureDates preset / custom
    var dateStart: Date?
    var dateEnd: Date?
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

    func captureDateInterval(now: Date = .now) -> DateInterval? {
        date == "custom"
            ? CaptureDates.interval(from: dateStart, through: dateEnd)
            : CaptureDates.presetInterval(date, now: now)
    }

    func matchesCaptureDate(_ value: Date, now: Date = .now) -> Bool {
        if date == "any" { return true }
        guard let interval = captureDateInterval(now: now) else { return false }
        return CaptureDates.contains(value, in: interval)
    }

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
        if date == "custom" {
            conditions.append(SmartCondition(field: "captureDate", op: ">=", value: dateStart.map { CaptureDates.key($0) } ?? ""))
            conditions.append(SmartCondition(field: "captureDate", op: "<=", value: dateEnd.map { CaptureDates.key($0) } ?? ""))
        } else if date != "any" {
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
