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
    /// Every field but the dates, by value in one place, so a copy of the storage is one copy of
    /// them. Date's layout is resilient: a struct holding one has no fixed layout either, and each
    /// of its fields would be found through the struct's metadata at run time instead of read at
    /// a constant offset, so the dates are properties of their own.
    private struct Fields {
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
        var deleted: Bool
        var localPath: String?
        var captureDateSource: String
        var contentHash: String?
        var quickHash: String?
        var isDemo: Bool
        var faces: Int
        var perceptualHash: UInt64?
        var masterId: String?
        var copyName: String?
        var duration: Double?
    }

    // Mutated only through `uniqueStorage()`, i.e. while no other value shares it, so the runtime
    // exclusivity check guards nothing; a class's Date properties would keep it in Release.
    private final class Storage: @unchecked Sendable {
        // first, so its offset is a constant (the dates' sizes are known only at run time)
        @exclusivity(unchecked) var fields: Fields
        @exclusivity(unchecked) var date: Date
        @exclusivity(unchecked) var fileModifiedAt: Date?
        @exclusivity(unchecked) var fileCreatedAt: Date?
        @exclusivity(unchecked) var importedAt: Date

        init(_ fields: Fields, date: Date, fileModifiedAt: Date?, fileCreatedAt: Date?, importedAt: Date) {
            self.fields = fields
            self.date = date
            self.fileModifiedAt = fileModifiedAt
            self.fileCreatedAt = fileCreatedAt
            self.importedAt = importedAt
        }

        // out of line, as it was when Storage listed every field: each setter stays a uniqueness
        // check and a store where it's used, and the rare copy is a call
        @inline(never)
        func copy() -> Storage {
            Storage(fields, date: date, fileModifiedAt: fileModifiedAt, fileCreatedAt: fileCreatedAt, importedAt: importedAt)
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
         perceptualHash: UInt64? = nil,
         masterId: String? = nil,
         copyName: String? = nil,
         duration: Double? = nil) {
        storage = Storage(Fields(id: id, pid: pid, ori: ori, thumb: thumb, preview: preview, filename: filename, type: type, isRaw: isRaw, folderId: folderId, folderName: folderName, width: width, height: height, orientation: orientation, camera: camera, lens: lens, focal: focal, aperture: aperture, shutter: shutter, iso: iso, colorSpace: colorSpace, hasICCProfile: hasICCProfile, fileMB: fileMB, rating: rating, flag: flag, colorLabel: colorLabel, keywords: keywords, title: title, caption: caption, author: author, copyright: copyright, makerNotes: makerNotes, project: project, client: client, location: location, gps: gps, gpsAltitude: gpsAltitude, status: status, deleted: deleted, localPath: localPath, captureDateSource: captureDateSource, contentHash: contentHash, quickHash: quickHash, isDemo: isDemo, faces: faces, perceptualHash: perceptualHash, masterId: masterId, copyName: copyName, duration: duration),
                          date: date, fileModifiedAt: fileModifiedAt, fileCreatedAt: fileCreatedAt, importedAt: importedAt)
    }

    private init(storage: Storage) { self.storage = storage }

    private mutating func uniqueStorage() -> Storage {
        if !isKnownUniquelyReferenced(&storage) { storage = storage.copy() }
        return storage
    }

    var id: String { storage.fields.id }
    var pid: Int { storage.fields.pid }
    /// "p" portrait / "l" landscape.
    var ori: String { storage.fields.ori }
    /// Cached thumbnail path, or a remote URL for demo photos.
    var thumb: String { storage.fields.thumb }
    /// Cached preview path, or a remote URL for demo photos.
    var preview: String { storage.fields.preview }
    var filename: String {
        get { storage.fields.filename }
        set { uniqueStorage().fields.filename = newValue }
    }
    /// ARW / CR3 / NEF / RAF / DNG / HEIC, or a video's MOV / MP4 / M4V.
    var type: String { storage.fields.type }
    var isRaw: Bool { storage.fields.isRaw }
    /// A video's length in seconds (nil for photos, or a video whose length couldn't be read).
    var duration: Double? { storage.fields.duration }
    /// The file types imported as videos (played, never developed).
    static let videoTypes: Set<String> = ["MOV", "MP4", "M4V"]
    /// Decided by the file type, so a video whose metadata couldn't be read is still a video.
    var isVideo: Bool { Self.videoTypes.contains(type) }
    var folderId: String {
        get { storage.fields.folderId }
        set { uniqueStorage().fields.folderId = newValue }
    }
    var folderName: String {
        get { storage.fields.folderName }
        set { uniqueStorage().fields.folderName = newValue }
    }
    /// Capture date (mutable for batch time shift, §4.2).
    var date: Date {
        get { storage.date }
        set { uniqueStorage().date = newValue }
    }
    var width: Int { storage.fields.width }
    var height: Int { storage.fields.height }
    var orientation: Int { storage.fields.orientation }
    var camera: String { storage.fields.camera }
    var lens: String { storage.fields.lens }
    var focal: Int { storage.fields.focal }
    var aperture: Double { storage.fields.aperture }
    var shutter: String { storage.fields.shutter }
    var iso: Int { storage.fields.iso }
    var colorSpace: String { storage.fields.colorSpace }
    var hasICCProfile: Bool {
        get { storage.fields.hasICCProfile }
        set { uniqueStorage().fields.hasICCProfile = newValue }
    }
    var fileMB: Double {
        get { storage.fields.fileMB }
        set { uniqueStorage().fields.fileMB = newValue }
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
        get { storage.fields.rating }
        set { uniqueStorage().fields.rating = newValue }
    }
    var flag: Flag {
        get { storage.fields.flag }
        set { uniqueStorage().fields.flag = newValue }
    }
    var colorLabel: ColorLabel? {
        get { storage.fields.colorLabel }
        set { uniqueStorage().fields.colorLabel = newValue }
    }
    var keywords: [String] {
        get { storage.fields.keywords }
        set { uniqueStorage().fields.keywords = newValue }
    }
    var title: String {
        get { storage.fields.title }
        set { uniqueStorage().fields.title = newValue }
    }
    var caption: String {
        get { storage.fields.caption }
        set { uniqueStorage().fields.caption = newValue }
    }
    var author: String {
        get { storage.fields.author }
        set { uniqueStorage().fields.author = newValue }
    }
    var copyright: String {
        get { storage.fields.copyright }
        set { uniqueStorage().fields.copyright = newValue }
    }
    var makerNotes: String {
        get { storage.fields.makerNotes }
        set { uniqueStorage().fields.makerNotes = newValue }
    }
    var project: String {
        get { storage.fields.project }
        set { uniqueStorage().fields.project = newValue }
    }
    var client: String {
        get { storage.fields.client }
        set { uniqueStorage().fields.client = newValue }
    }
    var location: String {
        get { storage.fields.location }
        set { uniqueStorage().fields.location = newValue }
    }
    var gps: (Double, Double) {
        get { storage.fields.gps }
        set { uniqueStorage().fields.gps = newValue }
    }
    var gpsAltitude: Double? {
        get { storage.fields.gpsAltitude }
        set { uniqueStorage().fields.gpsAltitude = newValue }
    }
    var status: AssetStatus {
        get { storage.fields.status }
        set { uniqueStorage().fields.status = newValue }
    }
    var importedAt: Date {
        get { storage.importedAt }
        set { uniqueStorage().importedAt = newValue }
    }
    var deleted: Bool {
        get { storage.fields.deleted }
        set { uniqueStorage().fields.deleted = newValue }
    }
    /// Original file on disk (nil for demo assets).
    var localPath: String? {
        get { storage.fields.localPath }
        set { uniqueStorage().fields.localPath = newValue }
    }
    var captureDateSource: String {
        get { storage.fields.captureDateSource }
        set { uniqueStorage().fields.captureDateSource = newValue }
    }
    var contentHash: String? {
        get { storage.fields.contentHash }
        set { uniqueStorage().fields.contentHash = newValue }
    }
    var quickHash: String? {
        get { storage.fields.quickHash }
        set { uniqueStorage().fields.quickHash = newValue }
    }
    /// False once scanned from a real folder.
    var isDemo: Bool {
        get { storage.fields.isDemo }
        set { uniqueStorage().fields.isDemo = newValue }
    }
    /// Vision-detected face count (§4.3).
    var faces: Int {
        get { storage.fields.faces }
        set { uniqueStorage().fields.faces = newValue }
    }
    /// Cached dHash for similar-photo grouping (§6.10).
    var perceptualHash: UInt64? {
        get { storage.fields.perceptualHash }
        set { uniqueStorage().fields.perceptualHash = newValue }
    }
    /// The photo this is a virtual copy of: the same original file, with its own develop
    /// settings and metadata. Nil for a photo that owns its file.
    var masterId: String? {
        get { storage.fields.masterId }
        set { uniqueStorage().fields.masterId = newValue }
    }
    /// A virtual copy's name, such as "副本 1".
    var copyName: String? {
        get { storage.fields.copyName }
        set { uniqueStorage().fields.copyName = newValue }
    }
    var isVirtualCopy: Bool { storage.fields.masterId != nil }

    /// A virtual copy of this photo: everything carried over, with a new id and name.
    func virtualCopy(id: String, name: String) -> Asset {
        var fields = storage.fields
        fields.id = id
        fields.deleted = false
        fields.isDemo = false
        fields.faces = 0
        fields.masterId = masterId ?? self.id
        fields.copyName = name
        return Asset(storage: Storage(fields, date: date, fileModifiedAt: fileModifiedAt, fileCreatedAt: fileCreatedAt,
                                      importedAt: .now))
    }

    /// Takes every editable field that `new` changed from `old`, leaving the rest as they are:
    /// undo and redo replay one step onto the photo as it is now, so whatever changed it since
    /// (a rename, a trash, an offline check, a rescan, a sidecar read) stays.
    mutating func takeChanges(from old: Asset, to new: Asset) {
        guard old.storage !== new.storage else { return }
        if old.filename != new.filename { filename = new.filename }
        if old.folderId != new.folderId { folderId = new.folderId }
        if old.folderName != new.folderName { folderName = new.folderName }
        if old.date != new.date { date = new.date }
        if old.hasICCProfile != new.hasICCProfile { hasICCProfile = new.hasICCProfile }
        if old.fileMB != new.fileMB { fileMB = new.fileMB }
        if old.fileModifiedAt != new.fileModifiedAt { fileModifiedAt = new.fileModifiedAt }
        if old.fileCreatedAt != new.fileCreatedAt { fileCreatedAt = new.fileCreatedAt }
        if old.rating != new.rating { rating = new.rating }
        if old.flag != new.flag { flag = new.flag }
        if old.colorLabel != new.colorLabel { colorLabel = new.colorLabel }
        if old.keywords != new.keywords { keywords = new.keywords }
        if old.title != new.title { title = new.title }
        if old.caption != new.caption { caption = new.caption }
        if old.author != new.author { author = new.author }
        if old.copyright != new.copyright { copyright = new.copyright }
        if old.makerNotes != new.makerNotes { makerNotes = new.makerNotes }
        if old.project != new.project { project = new.project }
        if old.client != new.client { client = new.client }
        if old.location != new.location { location = new.location }
        if old.gps.0 != new.gps.0 || old.gps.1 != new.gps.1 { gps = new.gps }
        if old.gpsAltitude != new.gpsAltitude { gpsAltitude = new.gpsAltitude }
        if old.status != new.status { status = new.status }
        if old.importedAt != new.importedAt { importedAt = new.importedAt }
        if old.deleted != new.deleted { deleted = new.deleted }
        if old.localPath != new.localPath { localPath = new.localPath }
        if old.captureDateSource != new.captureDateSource { captureDateSource = new.captureDateSource }
        if old.contentHash != new.contentHash { contentHash = new.contentHash }
        if old.quickHash != new.quickHash { quickHash = new.quickHash }
        if old.isDemo != new.isDemo { isDemo = new.isDemo }
        if old.faces != new.faces { faces = new.faces }
        if old.perceptualHash != new.perceptualHash { perceptualHash = new.perceptualHash }
        if old.masterId != new.masterId { masterId = new.masterId }
        if old.copyName != new.copyName { copyName = new.copyName }
    }

    var megapixels: Double { Double(width * height) / 1_000_000 }

    /// A file's size as `fileMB` keeps it, and back. One conversion for every comparison by size
    /// (a rescan's changed files, a card's photos imported before, exact duplicates), which only
    /// agree while they round alike.
    static func megabytes(bytes: Int64) -> Double { Double(bytes) / (1024 * 1024) }
    static func bytes(megabytes: Double) -> Int64 { Int64((megabytes * 1024 * 1024).rounded()) }
    var fileBytes: Int64 { Self.bytes(megabytes: fileMB) }

    /// The text a search looks through, for the search box and a smart album's 全文搜索 alike,
    /// so an album saved from a search finds what the search did.
    var searchHaystack: String {
        ([filename, camera, lens, title, caption, location, project, client] + keywords).joined(separator: " ")
    }

    /// Whether the photo is of `type` as the filters and smart albums name it: RAW, VIDEO (any
    /// movie), or a file type.
    func matchesType(_ type: String) -> Bool {
        switch type {
        case "RAW": isRaw
        case "VIDEO": isVideo
        default: self.type == type
        }
    }

    /// A video's length as a clock: "0:23", "12:05", "1:02:09".
    var durationText: String? { duration.map(Self.clock) }

    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600, minutes = total / 60 % 60, rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }

    /// The label stored with coordinates: "30.500, 114.300", or empty without a location.
    static func locationLabel(_ gps: (Double, Double)?) -> String {
        gps.map { String(format: "%.3f, %.3f", $0.0, $0.1) } ?? ""
    }
    var hasGPS: Bool { Self.hasGPSCoordinates(gps, location: location) }

    static func hasGPSCoordinates(_ gps: (Double, Double), location: String) -> Bool {
        if !(gps.0 == 0 && gps.1 == 0) { return true }
        guard !location.isEmpty else { return false }   // most photos: no coordinates in any form
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
    var name: String
    var assetIds: [String]
    /// The album set it's filed in; nil at the top level.
    var setId: String? = nil
}

/// A folder of albums, smart albums and other sets in the sidebar (Lightroom's collection
/// set; `albums` table, type = set). It holds no photos itself.
struct AlbumSet: Identifiable, Hashable {
    let id: String
    var name: String
    var parentId: String? = nil
}

/// Smart album — name + rule + cached match count.
struct SmartAlbum: Identifiable {
    let id: String
    var name: String
    var rule: SmartRule
    var count: Int
    var setId: String? = nil
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

enum ViewMode: String { case grid, loupe, compare, survey, develop, analysis }

/// Workspace appearance preference; the photo canvas is dark in every mode.
enum AppAppearance: String, CaseIterable, Sendable {
    case system, light, dark

    var label: String {
        switch self {
        case .system: return L("跟随系统")
        case .light: return L("浅色")
        case .dark: return L("深色")
        }
    }
}

/// The UI language: the system's choice, or one picked in Settings.
enum AppLanguage: String, CaseIterable, Sendable {
    case system, chinese = "zh-Hans", english = "en"

    /// Languages are named in their own language, so anyone can find theirs.
    var label: String {
        switch self {
        case .system: return L("跟随系统")
        case .chinese: return "简体中文"
        case .english: return "English"
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
            // an open end adds nothing; with neither end the empty keys match nothing, like the filter
            if dateStart != nil || dateEnd == nil {
                conditions.append(SmartCondition(field: "captureDate", op: ">=", value: dateStart.map { CaptureDates.key($0) } ?? ""))
            }
            if dateEnd != nil || dateStart == nil {
                conditions.append(SmartCondition(field: "captureDate", op: "<=", value: dateEnd.map { CaptureDates.key($0) } ?? ""))
            }
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
            case .capture: return L("拍摄时间")
            case .imported: return L("导入时间")
            case .name: return L("文件名")
            case .rating: return L("评分")
            case .size: return L("文件大小")
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

/// What a slideshow, a web gallery or a book shows with a photo: their choices share these names.
protocol PhotoCaption: RawRepresentable where RawValue == String {}

/// A web gallery's or a book's caption, in the order their pickers list them. (The slideshow
/// lists the same choices in another order, so it keeps its own.)
enum GalleryCaption: String, Codable, CaseIterable, Sendable, PhotoCaption {
    case none, title, caption, filename

    var title: String {
        switch self {
        case .none: L("无")
        case .title: L("标题")
        case .caption: L("说明")
        case .filename: L("文件名")
        }
    }
}

extension PhotoCaption {
    func text(for asset: Asset) -> String {
        text(title: asset.title, caption: asset.caption, filename: asset.filename)
    }

    func text(title: String, caption: String, filename: String) -> String {
        switch rawValue {
        case "title": title
        case "caption": caption
        case "filename": filename
        default: ""
        }
    }
}
