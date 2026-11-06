import Foundation

enum AssetQueryScope: Equatable, Sendable {
    case all
    case recent(since: Date)
    case unrated
    case picks
    case rejected
    case missingOrOffline
    case places
    case people
    case folder(sourceId: String, directoryPath: String? = nil)
    case album(id: String)
    case smart(rule: SmartRule)
    case keyword(String)
    case project(String)
    case client(String)
    case captureDate(String)
}

struct AssetQuery: Equatable, Sendable {
    var scope: AssetQueryScope = .all
    var filters = Filters()
    var search = ""
    var sort = Sort()
    var referenceDate = Date.now
}

struct AssetPage: Sendable {
    let assets: [Asset]
    let totalCount: Int
    let offset: Int

    var hasMore: Bool { offset + assets.count < totalCount }
}

extension CatalogStore {
    // ---------- assets ----------
    /// Trigram FTS search returning substring matches for queries of at least three characters;
    /// nil when the index can't answer — a shorter query, or an index that can't be read — so
    /// the caller searches otherwise rather than finding nothing.
    func search(_ query: String) -> [String]? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 3 else { return nil }
        let match = Self.ftsMatch(q)
        guard let rows = try? db.query("""
        SELECT asset_search.asset_id
        FROM asset_search
        JOIN assets ON assets.id = asset_search.asset_id
        WHERE assets.deleted=0 AND asset_search MATCH ?;
        """, [.text(match)]) else { return nil }
        return rows.compactMap { $0.text("asset_id") }
    }

    /// Videos, by their file type (`Asset.videoTypes`).
    static let videoPredicate = "a.type IN (" + Asset.videoTypes.sorted().map { "'\($0)'" }.joined(separator: ",") + ")"

    /// Returns a stable page and the full match count from one read transaction.
    /// All user-controlled values are bound parameters; only enum-backed sort columns enter SQL.
    func loadAssetPage(matching query: AssetQuery = AssetQuery(),
                       offset: Int = 0, limit: Int = 200) throws -> AssetPage {
        let safeOffset = max(0, offset)
        let safeLimit = max(0, limit)
        let sql = Self.assetSQL(for: query)
        var totalCount = 0
        var assets: [Asset] = []

        try db.transaction {
            totalCount = try db.queryMap(
                "SELECT COUNT(*) AS total FROM assets AS a WHERE \(sql.predicate);",
                sql.params
            ) { $0.int("total") }.first ?? 0

            guard safeLimit > 0, safeOffset < totalCount else { return }
            // decoded as the whole catalog is, so a page's photos are those it later loads
            let decoder = AssetRowDecoder(columns: Self.columnNames)
            assets = try db.queryRows(
                """
                SELECT \(Self.columns)
                FROM assets AS a
                WHERE \(sql.predicate)
                ORDER BY \(Self.orderClause(for: query.sort))
                LIMIT ? OFFSET ?;
                """,
                sql.params + [.int(safeLimit), .int(safeOffset)],
                transform: decoder.asset(from:)
            )
        }
        return AssetPage(assets: assets, totalCount: totalCount, offset: safeOffset)
    }

    private struct AssetSQL {
        let predicate: String
        let params: [SQLValue]
    }

    private static func assetSQL(for query: AssetQuery) -> AssetSQL {
        var predicates = ["a.deleted=0"]
        var params: [SQLValue] = []

        func append(_ predicate: String, _ values: [SQLValue] = []) {
            predicates.append(predicate)
            params.append(contentsOf: values)
        }

        switch query.scope {
        case .all:
            break
        case .recent(let since):
            append("a.imported_at > ?", [.double(since.timeIntervalSince1970)])
        case .unrated:
            append("a.rating=0 AND a.flag<>'reject'")
        case .picks:
            append("a.flag='pick'")
        case .rejected:
            append("a.flag='reject'")
        case .missingOrOffline:
            append("a.status IN ('missing','offline')")
        case .places:
            append(hasGPSPredicate)
        case .people:
            append("a.faces>0")
        case .folder(let sourceId, let directoryPath):
            append("a.folder_id=?", [.text(sourceId)])
            if let directoryPath {
                let path = directoryPath.count > 1 && directoryPath.hasSuffix("/")
                    ? String(directoryPath.dropLast()) : directoryPath
                let prefix = path == "/" ? "/" : path + "/"
                append("a.local_path IS NOT NULL AND instr(a.local_path, ?)=1", [.text(prefix)])
            }
        case .album(let id):
            append("EXISTS (SELECT 1 FROM album_assets aa WHERE aa.album_id=? AND aa.asset_id=a.id)",
                   [.text(id)])
        case .smart(let rule):
            let smart = smartPredicate(rule, referenceDate: query.referenceDate)
            append(smart.predicate, smart.params)
        case .keyword(let keyword):
            append("""
            EXISTS (
              SELECT 1
              FROM json_each(CASE WHEN json_valid(a.keywords) THEN a.keywords ELSE '[]' END) kw
              WHERE CAST(kw.value AS TEXT)=?
            )
            """, [.text(keyword)])
        case .project(let project):
            append("a.project=?", [.text(project)])
        case .client(let client):
            append("a.client=?", [.text(client)])
        case .captureDate(let key):
            if let range = CaptureDates.interval(for: key) {
                append("a.capture_date>=? AND a.capture_date<?",
                       [.double(range.start.timeIntervalSince1970), .double(range.end.timeIntervalSince1970)])
            } else {
                append("0")
            }
        }

        let filters = query.filters
        if filters.minRating > 0 {
            append("a.rating>=?", [.int(filters.minRating)])
        }
        if filters.flag != "any" {
            append("a.flag=?", [.text(filters.flag)])
        }
        if filters.color != "any" {
            append("a.color_label=?", [.text(filters.color)])
        }
        if filters.type != "any" {
            if filters.type == "RAW" {
                append("a.is_raw=1")
            } else if filters.type == "VIDEO" {
                append(Self.videoPredicate)
            } else {
                append("a.type=?", [.text(filters.type)])
            }
        }

        let camera = filters.camera.trimmingCharacters(in: .whitespacesAndNewlines)
        if !camera.isEmpty {
            append(textContainsPredicate(column: "a.camera"), [.text(camera)])
        }
        let lens = filters.lens.trimmingCharacters(in: .whitespacesAndNewlines)
        if !lens.isEmpty {
            append(textContainsPredicate(column: "a.lens"), [.text(lens)])
        }
        if filters.date != "any" {
            if let range = filters.captureDateInterval(now: query.referenceDate) {
                append("a.capture_date>=? AND a.capture_date<?",
                       [.double(range.start.timeIntervalSince1970), .double(range.end.timeIntervalSince1970)])
            } else {
                append("0")
            }
        }
        if filters.gps == "yes" {
            append(hasGPSPredicate)
        } else if filters.gps == "no" {
            append("NOT \(hasGPSPredicate)")
        }
        if filters.status != "any" {
            append("a.status=?", [.text(filters.status)])
        }

        let search = query.search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !search.isEmpty {
            let searchSQL = searchPredicate(search)
            append(searchSQL.predicate, searchSQL.params)
        }

        return AssetSQL(predicate: predicates.map { "(\($0))" }.joined(separator: " AND "),
                        params: params)
    }

    private static func smartPredicate(_ rule: SmartRule, referenceDate: Date) -> AssetSQL {
        let conditions = rule.conditions.map { smartConditionPredicate($0, referenceDate: referenceDate) }
        guard !conditions.isEmpty else {
            return AssetSQL(predicate: rule.match == "all" ? "1" : "0", params: [])
        }
        let separator = rule.match == "all" ? " AND " : " OR "
        return AssetSQL(
            predicate: conditions.map { "(\($0.predicate))" }.joined(separator: separator),
            params: conditions.flatMap(\.params)
        )
    }

    private static func smartConditionPredicate(_ condition: SmartCondition,
                                                referenceDate: Date) -> AssetSQL {
        switch condition.field {
        case "rating":
            let op = [">=", "<=", "="].contains(condition.op) ? condition.op : "="
            return AssetSQL(predicate: "a.rating\(op)?", params: [.int(Int(condition.value) ?? 0)])
        case "flag":
            return AssetSQL(predicate: "a.flag=?", params: [.text(condition.value)])
        case "colorLabel":
            if condition.value.isEmpty {
                return AssetSQL(predicate: "a.color_label IS NULL", params: [])
            }
            return AssetSQL(predicate: "a.color_label=?", params: [.text(condition.value)])
        case "keywords":
            let contains = """
            EXISTS (
              SELECT 1
              FROM json_each(CASE WHEN json_valid(a.keywords) THEN a.keywords ELSE '[]' END) kw
              WHERE \(textContainsPredicate(column: "CAST(kw.value AS TEXT)"))
            )
            """
            return AssetSQL(predicate: condition.op == "包含" ? contains : "NOT (\(contains))",
                            params: [.text(condition.value)])
        case "camera", "lens":
            let column = condition.field == "camera" ? "a.camera" : "a.lens"
            let predicate = condition.op == "=" ? "\(column)=?" : textContainsPredicate(column: column)
            return AssetSQL(predicate: predicate, params: [.text(condition.value)])
        case "type":
            if condition.value == "RAW" {
                return AssetSQL(predicate: "a.is_raw=1", params: [])
            }
            if condition.value == "VIDEO" {
                return AssetSQL(predicate: Self.videoPredicate, params: [])
            }
            return AssetSQL(predicate: "a.type=?", params: [.text(condition.value)])
        case "captureYear":
            let op = [">=", "<=", "="].contains(condition.op) ? condition.op : "="
            return AssetSQL(
                predicate: "CAST(strftime('%Y', a.capture_date, 'unixepoch') AS INTEGER)\(op)?",
                params: [.int(Int(condition.value) ?? 0)]
            )
        case "datePreset":
            if condition.value == "any" { return AssetSQL(predicate: "1", params: []) }
            guard let range = CaptureDates.presetInterval(condition.value, now: referenceDate) else {
                return AssetSQL(predicate: "0", params: [])
            }
            return AssetSQL(predicate: "a.capture_date>=? AND a.capture_date<?", params: [
                .double(range.start.timeIntervalSince1970),
                .double(range.end.timeIntervalSince1970),
            ])
        case "captureDate":
            guard let range = CaptureDates.interval(for: condition.value) else {
                return AssetSQL(predicate: "0", params: [])
            }
            if condition.op == ">=" {
                return AssetSQL(predicate: "a.capture_date>=?", params: [.double(range.start.timeIntervalSince1970)])
            }
            if condition.op == "<=" {
                return AssetSQL(predicate: "a.capture_date<?", params: [.double(range.end.timeIntervalSince1970)])
            }
            return AssetSQL(predicate: "a.capture_date>=? AND a.capture_date<?", params: [
                .double(range.start.timeIntervalSince1970), .double(range.end.timeIntervalSince1970),
            ])
        case "gps":
            return AssetSQL(predicate: condition.value == "yes" ? hasGPSPredicate : "NOT \(hasGPSPredicate)",
                            params: [])
        case "status":
            return AssetSQL(predicate: "a.status=?", params: [.text(condition.value)])
        case "search":
            return searchPredicate(condition.value)
        default:
            return AssetSQL(predicate: "1", params: [])
        }
    }

    private static func searchPredicate(_ value: String) -> AssetSQL {
        let query = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 3 else {
            let content = """
            COALESCE(a.filename,'') || ' ' || COALESCE(a.camera,'') || ' ' ||
            COALESCE(a.lens,'') || ' ' || COALESCE(a.title,'') || ' ' ||
            COALESCE(a.caption,'') || ' ' || COALESCE(a.location,'') || ' ' ||
            COALESCE(a.project,'') || ' ' || COALESCE(a.client,'') || ' ' ||
            COALESCE(a.keywords,'')
            """
            return AssetSQL(predicate: textContainsPredicate(column: "(\(content))"), params: [.text(query)])
        }
        return AssetSQL(
            predicate: "a.id IN (SELECT asset_id FROM asset_search WHERE asset_search MATCH ?)",
            params: [.text(ftsMatch(query))]
        )
    }

    private static func textContainsPredicate(column: String) -> String {
        "instr(lower(COALESCE(\(column), '')), lower(?))>0"
    }

    private static func orderClause(for sort: Sort) -> String {
        let direction = sort.descending ? "DESC" : "ASC"
        let column: String
        switch sort.field {
        case .capture: column = "a.capture_date"
        case .imported: column = "a.imported_at"
        case .name: column = "a.filename COLLATE NOCASE"
        case .rating: column = "a.rating"
        case .size: column = "a.file_mb"
        }
        return "\(column) \(direction), a.id \(direction)"
    }

    private static func ftsMatch(_ query: String) -> String {
        "\"\(query.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static let hasGPSPredicate = """
    (
      a.gps_lat<>0 OR a.gps_lon<>0 OR (
        instr(a.location, ',')>1 AND
        instr(substr(a.location, instr(a.location, ',')+1), ',')=0 AND
        trim(substr(a.location, 1, instr(a.location, ',')-1))<>'' AND
        trim(substr(a.location, instr(a.location, ',')+1))<>'' AND
        trim(substr(a.location, 1, instr(a.location, ',')-1)) NOT GLOB '*[^0-9.+-]*' AND
        trim(substr(a.location, instr(a.location, ',')+1)) NOT GLOB '*[^0-9.+-]*' AND
        CAST(trim(substr(a.location, 1, instr(a.location, ',')-1)) AS REAL) BETWEEN -90 AND 90 AND
        CAST(trim(substr(a.location, instr(a.location, ',')+1)) AS REAL) BETWEEN -180 AND 180
      )
    )
    """

    func assetCount(includeDeleted: Bool = false) -> Int {
        db.scalarInt("SELECT COUNT(*) FROM assets" + (includeDeleted ? ";" : " WHERE deleted=0;"))
    }
}
