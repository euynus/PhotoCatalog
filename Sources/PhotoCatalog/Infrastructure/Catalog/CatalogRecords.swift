import Foundation

struct SourceRootRecord: Identifiable, Sendable {
    let id: String
    let displayName: String
    let pathHint: String
    let bookmarkData: Data?
    let managementMode: String
    let status: String
    let volumeIdentifier: String?
}

/// What a catalog keeps beside its photos, read whole as it opens.
struct CatalogCollections: Sendable {
    var developSettings: [String: DevelopSettings] = [:]
    /// The Quick Collection among them, under its reserved id.
    var albums: [Album] = []
    var smartAlbums: [SmartAlbum] = []
    var albumSets: [AlbumSet] = []
    var xmpSyncTimes: [String: Double] = [:]
}

struct ImportSessionRecord: Identifiable, Equatable, Sendable {
    let id: String
    let rootId: String?
    let state: String
    let totalCount: Int
    let importedCount: Int
    let skippedCount: Int
    let failedCount: Int
    let startedAt: Date
    let finishedAt: Date?
    let errorMessage: String?
}

struct JobRecord: Identifiable, Equatable, Sendable {
    let id: String
    let type: String
    let priority: Int
    let state: String
    let payloadJSON: String
    let attempts: Int
    let maxAttempts: Int
    let lockedAt: Date?
    let lastError: String?
    let createdAt: Date
    let updatedAt: Date
}

struct ImportJobPayload: Codable, Equatable, Sendable {
    let kind: String
    let sessionId: String
    let sourcePath: String
    let mode: String
    let autoTag: Bool
    let archiveRule: String?
    let readSidecar: Bool?
    let previewMaxPixel: Int?
    let options: ImportOptionsSnapshot?

    init(kind: String = "importFolder", sessionId: String, sourcePath: String,
         mode: String, autoTag: Bool, archiveRule: String? = nil,
         readSidecar: Bool? = nil, previewMaxPixel: Int? = nil, options: ImportOptionsSnapshot? = nil) {
        self.kind = kind
        self.sessionId = sessionId
        self.sourcePath = sourcePath
        self.mode = mode
        self.autoTag = autoTag
        self.archiveRule = archiveRule
        self.readSidecar = readSidecar
        self.previewMaxPixel = previewMaxPixel
        self.options = options
    }
}

enum CatalogStoreError: Error, Equatable {
    case incompatibleSchema(current: Int, supported: Int)
}
