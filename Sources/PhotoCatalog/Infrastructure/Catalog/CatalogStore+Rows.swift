import Foundation

extension CatalogStore {
    // ---------- row <-> Asset ----------
    private static func keywordsJSON(_ kws: [String]) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: kws), encoding: .utf8)) ?? "[]"
    }

    /// One formatter for every timestamp: making one took ~0.25 ms, as long as writing the row
    /// (applying settings to 1000 photos spent half its time there). The class is documented
    /// thread-safe.
    nonisolated(unsafe) private static let isoFormatter = ISO8601DateFormatter()

    static func iso(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    static func filenameStamp(_ date: Date) -> String {
        iso(date)
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        return isoFormatter.date(from: string)
    }

    static func importJobPayload(sessionId: String, sourcePath: String,
                                         mode: ImportMode, autoTag: Bool,
                                         archiveRule: ManagedArchiveRule?,
                                         readSidecar: Bool?, previewMaxPixel: Int?,
                                         options: ImportOptionsSnapshot?) -> String {
        let payload = ImportJobPayload(sessionId: sessionId, sourcePath: sourcePath,
                                       mode: mode.rawValue, autoTag: autoTag,
                                       archiveRule: archiveRule?.rawValue,
                                       readSidecar: readSidecar,
                                       previewMaxPixel: previewMaxPixel, options: options)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(payload)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func params(_ a: Asset) -> [SQLValue] {
        [
            .text(a.id), .int(a.pid), .text(a.ori), .text(a.thumb), .text(a.preview),
            .text(a.filename), .text(a.type), .int(a.isRaw ? 1 : 0), .text(a.folderId), .text(a.folderName),
            .double(a.date.timeIntervalSince1970), .int(a.width), .int(a.height), .int(a.orientation),
            .text(a.camera), .text(a.lens), .int(a.focal), .double(a.aperture), .text(a.shutter), .int(a.iso),
            .text(a.colorSpace), .int(a.hasICCProfile ? 1 : 0),
            .double(a.fileMB), .int(a.rating), .text(a.flag.rawValue),
            a.colorLabel.map { SQLValue.text($0.rawValue) } ?? .null,
            .text(keywordsJSON(a.keywords)), .text(a.title), .text(a.caption),
            .text(a.author), .text(a.copyright), .text(a.makerNotes),
            .text(a.project), .text(a.client),
            .text(a.location), .double(a.gps.0), .double(a.gps.1),
            a.gpsAltitude.map { SQLValue.double($0) } ?? .null,
            .text(a.status.rawValue),
            .double(a.importedAt.timeIntervalSince1970), .int(a.deleted ? 1 : 0), .int(a.isDemo ? 1 : 0),
            a.localPath.map { SQLValue.text($0) } ?? .null,
            .text(a.captureDateSource),
            a.contentHash.map { SQLValue.text($0) } ?? .null,
            a.quickHash.map { SQLValue.text($0) } ?? .null,
            .int(a.faces),
            a.fileModifiedAt.map { SQLValue.double($0.timeIntervalSince1970) } ?? .null,
            a.fileCreatedAt.map { SQLValue.double($0.timeIntervalSince1970) } ?? .null,
            a.perceptualHash.map { SQLValue.int(Int(Int64(bitPattern: $0))) } ?? .null,
            a.masterId.map { SQLValue.text($0) } ?? .null,
            a.copyName.map { SQLValue.text($0) } ?? .null,
            a.duration.map { SQLValue.double($0) } ?? .null,
        ]
    }

    static func importSession(from row: Row) -> ImportSessionRecord? {
        guard let id = row.text("id"),
              let state = row.text("state"),
              let startedAt = date(row.text("started_at")) else { return nil }
        return ImportSessionRecord(
            id: id,
            rootId: row.text("root_id"),
            state: state,
            totalCount: row.int("total_count") ?? 0,
            importedCount: row.int("imported_count") ?? 0,
            skippedCount: row.int("skipped_count") ?? 0,
            failedCount: row.int("failed_count") ?? 0,
            startedAt: startedAt,
            finishedAt: date(row.text("finished_at")),
            errorMessage: row.text("error_message"))
    }

    static func job(from row: Row) -> JobRecord? {
        guard let id = row.text("id"),
              let type = row.text("type"),
              let state = row.text("state"),
              let payloadJSON = row.text("payload_json"),
              let createdAt = date(row.text("created_at")),
              let updatedAt = date(row.text("updated_at")) else { return nil }
        return JobRecord(
            id: id,
            type: type,
            priority: row.int("priority") ?? 0,
            state: state,
            payloadJSON: payloadJSON,
            attempts: row.int("attempts") ?? 0,
            maxAttempts: row.int("max_attempts") ?? 3,
            lockedAt: date(row.text("locked_at")),
            lastError: row.text("last_error"),
            createdAt: createdAt,
            updatedAt: updatedAt)
    }
}
