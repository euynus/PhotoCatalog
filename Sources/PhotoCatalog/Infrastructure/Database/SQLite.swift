// ============================================================
//  Minimal SQLite wrapper over the system SQLite3 library.
//  (PRD §8: SQLite is the catalog store; we use the system lib
//   directly so the package has no external dependencies.)
// ============================================================
import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLValue {
    case int(Int)
    case double(Double)
    case text(String)
    case blob(Data)
    case null
}

typealias Row = [String: SQLValue]

extension Row {
    func int(_ k: String) -> Int? { if case .int(let v)? = self[k] { return v }; return nil }
    func double(_ k: String) -> Double? {
        if case .double(let v)? = self[k] { return v }
        if case .int(let v)? = self[k] { return Double(v) }
        return nil
    }
    func text(_ k: String) -> String? { if case .text(let v)? = self[k] { return v }; return nil }
    func blob(_ k: String) -> Data? { if case .blob(let v)? = self[k] { return v }; return nil }
    func bool(_ k: String) -> Bool { (int(k) ?? 0) != 0 }
}

enum DBError: Error, CustomStringConvertible {
    case open(String), prepare(String), step(String)
    var description: String {
        switch self {
        case .open(let m): return "sqlite open failed: \(m)"
        case .prepare(let m): return "sqlite prepare failed: \(m)"
        case .step(let m): return "sqlite step failed: \(m)"
        }
    }
}

// @unchecked Sendable: the system SQLite library is built in serialized threading
// mode, and in this app all db access is funnelled through the main thread anyway.
final class Database: @unchecked Sendable {
    private var db: OpaquePointer?
    // prepared-statement cache (keyed by SQL); db access is single-threaded so this is safe.
    // prepare_v2 statements auto-reprepare on schema change, so cached statements survive migrations.
    private var statementCache: [String: OpaquePointer] = [:]
    let path: String

    init(path: String) throws {
        self.path = path
        if sqlite3_open(path, &db) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw DBError.open(msg)
        }
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA foreign_keys=ON;")
        exec("PRAGMA busy_timeout=4000;")
    }

    deinit {
        for stmt in statementCache.values { sqlite3_finalize(stmt) }
        sqlite3_close(db)
    }

    @discardableResult
    func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    func execChecked(_ sql: String) throws {
        guard exec(sql) else { throw DBError.step(String(cString: sqlite3_errmsg(db))) }
    }

    /// Checkpoint the WAL into the main database file and truncate it, returning true only when
    /// the WAL was fully flushed. Unlike `PRAGMA wal_checkpoint`, this reports busy/partial
    /// checkpoints (which would otherwise leave recent commits only in the -wal sidecar).
    func walCheckpointTruncate() -> Bool {
        sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil) == SQLITE_OK
    }

    func run(_ sql: String, _ params: [SQLValue] = []) throws {
        let stmt = try preparedStatement(sql, params)
        defer { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw DBError.step(String(cString: sqlite3_errmsg(db)))
        }
    }

    func query(_ sql: String, _ params: [SQLValue] = []) throws -> [Row] {
        let stmt = try preparedStatement(sql, params)
        defer { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
        var rows: [Row] = []
        let cols = Int(sqlite3_column_count(stmt))
        // column names are stable for the statement — read them once, not per row
        let names = (0..<cols).map { String(cString: sqlite3_column_name(stmt, Int32($0))) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row = Row(minimumCapacity: cols)
            for c in 0..<cols {
                let i = Int32(c)
                let name = names[c]
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row[name] = .int(Int(sqlite3_column_int64(stmt, i)))
                case SQLITE_FLOAT: row[name] = .double(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(stmt, i)))
                case SQLITE_BLOB:
                    if let bytes = sqlite3_column_blob(stmt, i) {
                        row[name] = .blob(Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, i))))
                    } else { row[name] = .null }
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    func transaction(_ body: () throws -> Void) throws {
        guard exec("BEGIN;") else { throw DBError.step(String(cString: sqlite3_errmsg(db))) }
        do {
            try body()
            exec("COMMIT;")
        } catch {
            exec("ROLLBACK;")
            throw error
        }
    }

    func scalarInt(_ sql: String, _ params: [SQLValue] = []) -> Int {
        (try? query(sql, params).first?.values.first.flatMap {
            if case .int(let v) = $0 { return v }; return nil
        }) ?? nil ?? 0
    }

    func scalarText(_ sql: String, _ params: [SQLValue] = []) -> String? {
        (try? query(sql, params).first?.values.first.flatMap {
            if case .text(let v) = $0 { return v }; return nil
        }) ?? nil
    }

    private func preparedStatement(_ sql: String, _ params: [SQLValue]) throws -> OpaquePointer {
        let stmt: OpaquePointer
        if let cached = statementCache[sql] {
            stmt = cached
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        } else {
            var newStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &newStmt, nil) == SQLITE_OK, let prepared = newStmt else {
                throw DBError.prepare(String(cString: sqlite3_errmsg(db)))
            }
            statementCache[sql] = prepared
            stmt = prepared
        }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .int(let v): sqlite3_bind_int64(stmt, idx, Int64(v))
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case .blob(let d):
                _ = d.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(d.count), SQLITE_TRANSIENT) }
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }
}
