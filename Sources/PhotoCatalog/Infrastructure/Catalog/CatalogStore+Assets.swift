import Foundation

extension CatalogStore {
    // ---------- assets ----------
    static let columns = """
    id,pid,ori,thumb,preview,filename,type,is_raw,folder_id,folder_name,\
    capture_date,width,height,orientation,camera,lens,focal,aperture,shutter,iso,\
    color_space,has_icc_profile,file_mb,rating,flag,color_label,keywords,title,caption,author,copyright,maker_notes,project,client,location,gps_lat,gps_lon,gps_altitude,\
    status,imported_at,deleted,is_demo,local_path,capture_date_source,content_hash,quick_hash,faces,\
    file_modified_at,file_created_at,perceptual_hash,master_id,copy_name,duration
    """

    func upsert(_ assets: [Asset]) throws {
        try db.transaction { try upsertRows(assets) }
    }

    /// `assets` and, when given, the source folder they're filed under, in one transaction: a
    /// photo is never in the catalog without its folder.
    func upsert(_ assets: [Asset], addingSourceRoot root: SourceRootRecord?) throws {
        try db.transaction {
            try upsertRows(assets)
            if let root {
                try addSourceRoot(id: root.id, displayName: root.displayName, path: root.pathHint,
                                  bookmark: root.bookmarkData,
                                  mode: ImportMode(rawValue: root.managementMode) ?? .referenced,
                                  volumeIdentifier: root.volumeIdentifier)
            }
        }
    }

    /// The asset row's insert, plain and as an upsert, each giving back the row's rowid.
    /// The upsert is a true in-place one. INSERT OR REPLACE would DELETE the conflicting row
    /// before re-inserting, which — with foreign_keys=ON — fires album_assets' ON DELETE CASCADE
    /// and silently drops the asset from every manual album on each metadata edit. The
    /// ON CONFLICT…DO UPDATE form updates the row in place, leaving FK children intact.
    private static let assetInsertSQL: (insert: String, upsert: String) = {
        let cols = columns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let placeholders = Array(repeating: "?", count: cols.count).joined(separator: ",")
        let assignments = cols.filter { $0 != "id" }.map { "\($0)=excluded.\($0)" }.joined(separator: ",")
        let insert = "INSERT INTO assets(\(columns)) VALUES(\(placeholders))"
        return (insert + " RETURNING rowid AS r;",
                insert + " ON CONFLICT(id) DO UPDATE SET \(assignments) RETURNING rowid AS r;")
    }()

    func upsertRows(_ assets: [Asset], updatingExisting: Bool = true) throws {
        let sql = updatingExisting ? Self.assetInsertSQL.upsert : Self.assetInsertSQL.insert
        var written: [(rowid: Int, asset: Asset)] = []
        for a in assets {
            guard let rowid = try db.queryMap(sql, Self.params(a), transform: { $0.int("r") }).first else { continue }
            written.append((rowid, a))
        }
        try writeSearchRows(written, comparing: updatingExisting)
    }

    /// The columns a review edit and a metadata edit change (`AppState.editScope(from:to:)`).
    private static let reviewColumns: Set<String> = ["rating", "flag", "color_label"]
    private static let metadataColumns: Set<String> = [
        "keywords", "title", "caption", "author", "copyright", "maker_notes",
        "project", "client", "location", "gps_lat", "gps_lon", "gps_altitude",
    ]

    /// Writes only the review columns, the metadata columns or both of these photos, in one
    /// transaction: an edit's own columns, rather than the whole row and every index on it as
    /// the upsert does. A photo whose row has gone is written whole.
    func updateEditableColumns(_ assets: [Asset], review: Bool, metadata: Bool) throws {
        let edited = (review ? Self.reviewColumns : []).union(metadata ? Self.metadataColumns : [])
        guard !edited.isEmpty, !assets.isEmpty else { return }
        // the upsert's own values, taken by position, so both write a column the same way
        let positions = Self.columnNames.indices.filter { edited.contains(Self.columnNames[$0]) }
        let sql = "UPDATE assets SET " + positions.map { "\(Self.columnNames[$0])=?" }.joined(separator: ",")
            + " WHERE id=? RETURNING rowid AS r;"
        try db.transaction {
            var written: [(rowid: Int, asset: Asset)] = []
            for asset in assets {
                let values = Self.params(asset)
                let updated = try db.queryMap(sql, positions.map { values[$0] } + [.text(asset.id)],
                                              transform: { $0.int("r") }).first
                guard let rowid = try updated ?? db.queryMap(Self.assetInsertSQL.upsert, values,
                                                             transform: { $0.int("r") }).first else { continue }
                written.append((rowid, asset))
            }
            try writeSearchRows(written, comparing: true)
        }
    }

    /// Keeps the FTS index in sync with these photos' rows; its rows share the asset's rowid
    /// (schema v20). With `comparing`, a photo whose indexed words are already its own is left.
    private func writeSearchRows(_ written: [(rowid: Int, asset: Asset)], comparing: Bool) throws {
        var searchRows: [(rowid: Int, id: String, content: String)] = []
        for (rowid, a) in written {
            // Its row changes only with the words it holds: a rating, a flag or Move to Trash leaves
            // them, and writing them again (the trigrams of every word) cost ~0.4 ms a photo.
            let content = Self.searchContent(a)
            if comparing, let row = try db.query("SELECT asset_id, content FROM asset_search WHERE rowid=?;",
                                                 [.int(rowid)]).first,
               row.text("asset_id") == a.id, row.text("content") == content { continue }
            searchRows.append((rowid, a.id, content))
        }
        // FTS5 keeps a transaction's index changes in memory while their rowids rise, and writes
        // them out as a new segment (to be merged later) each time one doesn't: rows taken in the
        // selection's order wrote one segment for about every other photo.
        searchRows.sort { $0.rowid < $1.rowid }
        for row in searchRows {
            searchIndexWrites &+= 1
            try db.run("DELETE FROM asset_search WHERE rowid=?;", [.int(row.rowid)])
            try db.run("INSERT INTO asset_search(rowid, asset_id, content) VALUES(?,?,?);", [
                .int(row.rowid),
                .text(row.id),
                .text(row.content),
            ])
        }
    }

    private static func searchContent(_ asset: Asset) -> String {
        [asset.filename, asset.title, asset.caption, asset.keywords.joined(separator: " "),
         asset.camera, asset.lens, asset.location, asset.project, asset.client]
            .joined(separator: " ")
    }

    func updateRatings(_ rating: Int, assetIDs: Set<String>) throws {
        try updateAssetColumn("rating", value: .int(rating), assetIDs: assetIDs)
    }

    func updateFlags(_ flag: Flag, assetIDs: Set<String>) throws {
        try updateAssetColumn("flag", value: .text(flag.rawValue), assetIDs: assetIDs)
    }

    func updateColorLabels(_ color: ColorLabel?, assetIDs: Set<String>) throws {
        try updateAssetColumn("color_label", value: color.map { .text($0.rawValue) } ?? .null,
                              assetIDs: assetIDs)
    }

    /// Saves what a check of the originals found, on each photo still at the path it was checked
    /// at: a rename or move saved since the check began is newer than what the check saw.
    func updateAssetAvailability(_ updates: [AssetAvailabilityUpdate]) throws {
        guard !updates.isEmpty else { return }
        try db.transaction {
            for update in updates {
                try db.run(
                    "UPDATE assets SET status=?, local_path=? WHERE id=? AND deleted=0 AND local_path IS ?;",
                    [
                        .text(update.status.rawValue),
                        update.localPath.map(SQLValue.text) ?? .null,
                        .text(update.assetId),
                        update.checkedPath.map(SQLValue.text) ?? .null,
                    ]
                )
            }
        }
    }

    /// One statement per column whatever the number of photos: a placeholder per photo made a
    /// statement, cached for good, for every batch size up to 500 (~100 MB at worst). One photo,
    /// a rating key's case, keeps its own statement and skips the JSON.
    private func updateAssetColumn(_ column: String, value: SQLValue, assetIDs: Set<String>) throws {
        guard !assetIDs.isEmpty else { return }
        try db.transaction {
            if assetIDs.count == 1, let id = assetIDs.first {
                try db.run("UPDATE assets SET \(column)=? WHERE id IN (?);", [value, .text(id)])
                return
            }
            let ids = String(decoding: try JSONSerialization.data(withJSONObject: assetIDs.sorted()), as: UTF8.self)
            try db.run("UPDATE assets SET \(column)=? WHERE id IN (SELECT value FROM json_each(?));",
                       [value, .text(ids)])
        }
    }

    func loadAssets() throws -> [Asset] {
        // through a connection of its own: the read takes seconds at 500k photos, and on the
        // catalog's connection an edit or search made while a catalog opened waited for all of it
        try loadAssets(aside: db.readOnlyConnection())
    }

    /// `loadAssets()` read through `reader` when there is one, else through the catalog's
    /// connection. A read aside that fails (busy past its timeout, say) is made again through the
    /// catalog's connection rather than failing the catalog's open.
    func loadAssets(aside reader: Database?) throws -> [Asset] {
        if let reader, let loaded = try? loadAssets(through: reader) { return loaded }
        return try loadAssets(through: db)
    }

    /// `loadAssets()` read through `connection`.
    func loadAssets(through connection: Database) throws -> [Asset] {
        // Read the table in its own order and sort in memory: ORDER BY via the capture-date
        // index fetched every row with a random seek into the table — random reads across the
        // whole file, most of a 10-20 s cold load at 500k photos. Soft-deleted rows are skipped.
        Self.readAhead(db.path)
        let decoder = AssetRowDecoder(columns: Self.columnNames)
        let loaded = try connection.queryRows(
            "SELECT \(Self.columns) FROM assets NOT INDEXED WHERE deleted=0;",
            transform: decoder.asset(from:)
        )
        // newest first, as the library shows by default; ties in a stable id order
        let dates = loaded.map { $0.date.timeIntervalSince1970 }
        var order = Array(loaded.indices)
        order.sort { dates[$0] != dates[$1] ? dates[$0] > dates[$1] : loaded[$0].id > loaded[$1].id }
        return order.map { loaded[$0] }
    }

    /// Reads the database file front to back, so the table scan that follows hits the page
    /// cache. Catalogs grow by imports, which interleave table, index and search pages across
    /// the file; the scan then made scattered 4 KB reads (~80 MB/s, 6 s at 500k photos cold),
    /// while one sequential pass runs at the disk's full speed (~1 s for 900 MB).
    private static func readAhead(_ path: String) {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = fcntl(fd, F_RDAHEAD, 1)
        var buffer = [UInt8](repeating: 0, count: 8 << 20)
        while buffer.withUnsafeMutableBytes({ read(fd, $0.baseAddress, $0.count) }) > 0 {}
    }

    static let columnNames = columns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Decodes whole-catalog loads from raw columns (no dictionary per row) into native strings —
    /// keywords decoded by JSONSerialization were bridged NSStrings, many times slower to hash
    /// and compare — and shares values that repeat across photos (folders, lenses, keyword
    /// sets…) instead of allocating each again.
    final class AssetRowDecoder {
        private var strings: [String: String] = [:]
        private var keywordSets: [String: [String]] = [:]
        private var cameras: [String: String] = [:]
        private let id, pid, ori, thumb, preview, filename, type, isRaw, folderId, folderName,
                    captureDate, width, height, orientation, camera, lens, focal, aperture, shutter, iso,
                    colorSpace, hasICCProfile, fileMB, rating, flag, colorLabel, keywords, title, caption,
                    author, copyright, makerNotes, project, client, location, gpsLat, gpsLon, gpsAltitude,
                    status, importedAt, deleted, isDemo, localPath, captureDateSource, contentHash,
                    quickHash, faces, fileModifiedAt, fileCreatedAt, perceptualHash, masterId, copyName, duration: Int32

        init(columns: [String]) {
            let index = Dictionary(uniqueKeysWithValues: columns.enumerated().map { ($1, Int32($0)) })
            func c(_ name: String) -> Int32 { index[name] ?? -1 }
            id = c("id"); pid = c("pid"); ori = c("ori"); thumb = c("thumb"); preview = c("preview")
            filename = c("filename"); type = c("type"); isRaw = c("is_raw"); folderId = c("folder_id")
            folderName = c("folder_name"); captureDate = c("capture_date"); width = c("width")
            height = c("height"); orientation = c("orientation"); camera = c("camera"); lens = c("lens")
            focal = c("focal"); aperture = c("aperture"); shutter = c("shutter"); iso = c("iso")
            colorSpace = c("color_space"); hasICCProfile = c("has_icc_profile"); fileMB = c("file_mb")
            rating = c("rating"); flag = c("flag"); colorLabel = c("color_label"); keywords = c("keywords")
            title = c("title"); caption = c("caption"); author = c("author"); copyright = c("copyright")
            makerNotes = c("maker_notes"); project = c("project"); client = c("client"); location = c("location")
            gpsLat = c("gps_lat"); gpsLon = c("gps_lon"); gpsAltitude = c("gps_altitude"); status = c("status")
            importedAt = c("imported_at"); deleted = c("deleted"); isDemo = c("is_demo"); localPath = c("local_path")
            captureDateSource = c("capture_date_source"); contentHash = c("content_hash")
            quickHash = c("quick_hash"); faces = c("faces"); fileModifiedAt = c("file_modified_at")
            fileCreatedAt = c("file_created_at"); perceptualHash = c("perceptual_hash")
            masterId = c("master_id"); copyName = c("copy_name"); duration = c("duration")
        }

        func asset(from row: SQLiteRow) -> Asset? {
            guard let assetId = row.text(id) else { return nil }
            let rawCamera = row.text(camera) ?? ""
            let cameraName = cameras[rawCamera] ?? {
                let normalized = shared(MetadataReader.normalizedCameraName(rawCamera))
                cameras[rawCamera] = normalized
                return normalized
            }()
            func date(_ column: Int32) -> Date? {
                row.isNull(column) ? nil : Date(timeIntervalSince1970: row.double(column))
            }
            return Asset(
                id: assetId, pid: row.int(pid), ori: row.text(ori) ?? "l",
                thumb: row.text(thumb) ?? "", preview: row.text(preview) ?? "",
                filename: row.text(filename) ?? "", type: row.text(type) ?? "",
                isRaw: row.int(isRaw) != 0, folderId: sharedText(row, folderId),
                folderName: sharedText(row, folderName),
                date: Date(timeIntervalSince1970: row.double(captureDate)),
                width: row.int(width), height: row.int(height),
                orientation: row.isNull(orientation) ? 1 : row.int(orientation),
                camera: cameraName, lens: sharedText(row, lens),
                focal: row.int(focal), aperture: row.double(aperture),
                shutter: row.text(shutter) ?? "", iso: row.int(iso),
                colorSpace: sharedText(row, colorSpace),
                hasICCProfile: row.int(hasICCProfile) != 0,
                fileMB: row.double(fileMB),
                fileModifiedAt: date(fileModifiedAt), fileCreatedAt: date(fileCreatedAt),
                rating: row.int(rating),
                flag: Flag(rawValue: row.text(flag) ?? "none") ?? .none,
                colorLabel: row.text(colorLabel).flatMap { ColorLabel(rawValue: $0) },
                keywords: keywordSet(row), title: row.text(title) ?? "", caption: row.text(caption) ?? "",
                author: sharedText(row, author), copyright: sharedText(row, copyright),
                makerNotes: row.text(makerNotes) ?? "",
                project: sharedText(row, project), client: sharedText(row, client),
                location: row.text(location) ?? "",
                gps: (row.double(gpsLat), row.double(gpsLon)),
                gpsAltitude: row.isNull(gpsAltitude) ? nil : row.double(gpsAltitude),
                status: AssetStatus(rawValue: row.text(status) ?? "ready") ?? .ready,
                importedAt: Date(timeIntervalSince1970: row.double(importedAt)),
                deleted: row.int(deleted) != 0,
                localPath: row.text(localPath),
                captureDateSource: row.isNull(captureDateSource)
                    ? "EXIF · DateTimeOriginal" : sharedText(row, captureDateSource),
                contentHash: row.text(contentHash), quickHash: row.text(quickHash),
                isDemo: row.int(isDemo) != 0, faces: row.int(faces),
                perceptualHash: row.isNull(perceptualHash) ? nil : UInt64(bitPattern: Int64(row.int(perceptualHash))),
                masterId: masterId < 0 ? nil : row.text(masterId), copyName: copyName < 0 ? nil : row.text(copyName),
                duration: duration < 0 || row.isNull(duration) ? nil : row.double(duration))
        }

        private func shared(_ value: String) -> String {
            if let existing = strings[value] { return existing }
            strings[value] = value
            return value
        }

        private func sharedText(_ row: SQLiteRow, _ column: Int32) -> String {
            let bytes = row.bytes(column)
            // up to 15 UTF-8 bytes live inline in the String itself: nothing to share
            return bytes.count <= 15 ? String(decoding: bytes, as: UTF8.self) : shared(String(decoding: bytes, as: UTF8.self))
        }

        private func keywordSet(_ row: SQLiteRow) -> [String] {
            let bytes = row.bytes(keywords)
            guard bytes.count > 2 else { return [] }   // NULL, "" or "[]"
            let raw = String(decoding: bytes, as: UTF8.self)
            if let known = keywordSets[raw] { return known }
            let parsed = (Self.parseKeywords(bytes) ?? Self.parseKeywordsSlowly(raw)).map(shared)
            keywordSets[raw] = parsed
            return parsed
        }

        /// The compact arrays the catalog writes, `["a","b\/c"]`, straight from bytes; nil for
        /// anything else (other escapes, spacing), which goes through JSONSerialization.
        static func parseKeywords(_ bytes: UnsafeBufferPointer<UInt8>) -> [String]? {
            let quote: UInt8 = 0x22, backslash: UInt8 = 0x5C, slash: UInt8 = 0x2F, comma: UInt8 = 0x2C
            guard bytes.count >= 4, bytes[0] == 0x5B, bytes[1] == quote,
                  bytes[bytes.count - 2] == quote, bytes[bytes.count - 1] == 0x5D else { return nil }
            var result: [String] = []
            var current: [UInt8] = []
            let end = bytes.count - 2
            var i = 2
            while i < end {
                let byte = bytes[i]
                if byte == backslash {
                    guard i + 1 < end, bytes[i + 1] == slash else { return nil }
                    current.append(slash)
                    i += 2
                } else if byte == quote {
                    guard i + 2 < end, bytes[i + 1] == comma, bytes[i + 2] == quote else { return nil }
                    result.append(String(decoding: current, as: UTF8.self))
                    current.removeAll(keepingCapacity: true)
                    i += 3
                } else {
                    current.append(byte)
                    i += 1
                }
            }
            result.append(String(decoding: current, as: UTF8.self))
            return result
        }

        /// JSONSerialization hands back bridged strings; copy them into native ones.
        static func parseKeywordsSlowly(_ raw: String) -> [String] {
            let parsed = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String] ?? []
            return parsed.map { String(decoding: Array($0.utf8), as: UTF8.self) }
        }
    }
}
