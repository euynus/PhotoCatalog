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

/// Direct column access to the current row, for decoders too hot to build a dictionary per
/// row. Valid only inside the `queryRows` callback.
struct SQLiteRow {
    fileprivate let stmt: OpaquePointer

    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(stmt, column) == SQLITE_NULL }
    func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(stmt, column)) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(stmt, column) }

    /// The column's UTF-8 bytes (text is read before its length, as SQLite requires).
    func bytes(_ column: Int32) -> UnsafeBufferPointer<UInt8> {
        guard let text = sqlite3_column_text(stmt, column) else { return UnsafeBufferPointer(start: nil, count: 0) }
        return UnsafeBufferPointer(start: text, count: Int(sqlite3_column_bytes(stmt, column)))
    }

    /// A native Swift string (nil for NULL).
    func text(_ column: Int32) -> String? {
        isNull(column) ? nil : String(decoding: bytes(column), as: UTF8.self)
    }
}

enum DBError: Error, CustomStringConvertible {
    case open(String), prepare(String), step(String), bind(String)
    var description: String {
        switch self {
        case .open(let m): return "sqlite open failed: \(m)"
        case .prepare(let m): return "sqlite prepare failed: \(m)"
        case .step(let m): return "sqlite step failed: \(m)"
        case .bind(let m): return "sqlite bind failed: \(m)"
        }
    }
}

// @unchecked Sendable: access to the SQLite handle and statement cache is serialized below.
final class Database: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    // prepared-statement cache (keyed by SQL); db access is serialized so this is safe.
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
        let checkpointer = WALCheckpointer(handle: db, lock: lock)
        self.checkpointer = checkpointer
        // replaces SQLite's own checkpoint after a commit, which ran on the committing thread
        sqlite3_wal_hook(db, { context, handle, _, pages in
            guard let context else { return SQLITE_OK }
            Unmanaged<WALCheckpointer>.fromOpaque(context).takeUnretainedValue().committed(pages: Int(pages), on: handle)
            return SQLITE_OK
        }, Unmanaged.passUnretained(checkpointer).toOpaque())
    }

    deinit {
        // a checkpoint already running finishes first; one still queued finds the handle closed
        // (not under the lock while waiting: the checkpoint needs it)
        if let checkpointer {
            lock.lock()
            checkpointer.closed = true
            lock.unlock()
            checkpointer.queue.sync {}
        }
        lock.lock()
        defer { lock.unlock() }
        for stmt in statementCache.values { sqlite3_finalize(stmt) }
        sqlite3_close(db)
    }

    /// Moves the WAL's pages into the database file in the background once a commit leaves it
    /// past `threshold` pages, as SQLite would at the end of the commit itself (on the main
    /// thread, for an edit: ~40% of putting 1000 photos in the Trash was that checkpoint and its
    /// sync). The same passive checkpoint on the same connection, under the same lock, so it
    /// never runs inside a transaction; only the thread changes.
    final class WALCheckpointer: @unchecked Sendable {
        /// SQLite's own default.
        static let threshold = 1000
        /// Past this, a commit checkpoints at once, as before: the background one hasn't kept up.
        static let ceiling = 10 * threshold

        let queue = DispatchQueue(label: "PhotoCatalog.wal-checkpoint", qos: .utility)
        private let handle: OpaquePointer?
        private let lock: NSRecursiveLock
        /// Guarded by `lock`.
        var closed = false
        private var pending = false
        private(set) var checkpoints = 0

        init(handle: OpaquePointer?, lock: NSRecursiveLock) {
            self.handle = handle
            self.lock = lock
        }

        /// From the WAL hook, at the end of a commit (under `lock`): `pages` are in the WAL.
        func committed(pages: Int, on connection: OpaquePointer?) {
            if pages >= Self.ceiling {
                sqlite3_wal_checkpoint_v2(connection, nil, SQLITE_CHECKPOINT_PASSIVE, nil, nil)
                checkpoints &+= 1
                return
            }
            guard pages >= Self.threshold, !pending else { return }
            pending = true
            queue.async { [self] in
                lock.lock()
                defer { lock.unlock() }
                pending = false
                guard !closed else { return }
                sqlite3_wal_checkpoint_v2(handle, nil, SQLITE_CHECKPOINT_PASSIVE, nil, nil)
                checkpoints &+= 1
            }
        }
    }

    /// Nil only when the database couldn't be opened.
    private var checkpointer: WALCheckpointer?

    /// Waits for a background checkpoint (for tests).
    func drainCheckpoints() { checkpointer?.queue.sync {} }

    /// The background checkpoints' queue and how many have run (for tests).
    var checkpointQueue: DispatchQueue? { checkpointer?.queue }
    var checkpointCount: Int { locked { checkpointer?.checkpoints ?? 0 } }

    @discardableResult
    func exec(_ sql: String) -> Bool {
        locked {
            sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
        }
    }

    func execChecked(_ sql: String) throws {
        // the message is read under the same lock: another thread's statement would replace it
        try locked {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw DBError.step(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    /// Checkpoint the WAL into the main database file and truncate it, returning true only when
    /// the WAL was fully flushed. Unlike `PRAGMA wal_checkpoint`, this reports busy/partial
    /// checkpoints (which would otherwise leave recent commits only in the -wal sidecar).
    func walCheckpointTruncate() -> Bool {
        locked {
            sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil) == SQLITE_OK
        }
    }

    /// Copies the database at `source` into `target` (created if missing, replaced if not) with
    /// SQLite's online backup, through a connection of its own that holds one read transaction:
    /// the copy is the database as of one commit, what's still only in the WAL included, while
    /// writers carry on. A copy of the file instead can mix pages from before and after a write
    /// made meanwhile. With `followingLinks` false, a path through a symbolic link is refused.
    /// `checkCancellation` runs between steps; what it throws is passed on.
    static func snapshot(from source: URL, to target: URL, followingLinks: Bool = true,
                         checkCancellation: () throws -> Void = {}) throws {
        var read: OpaquePointer?, write: OpaquePointer?
        defer { sqlite3_close(read); sqlite3_close(write) }
        let links = followingLinks ? 0 : SQLITE_OPEN_NOFOLLOW
        guard sqlite3_open_v2(source.path, &read, SQLITE_OPEN_READONLY | links, nil) == SQLITE_OK else {
            throw DBError.open("cannot open the database to copy")
        }
        guard sqlite3_open_v2(target.path, &write, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | links, nil) == SQLITE_OK else {
            throw DBError.open("cannot create the copy")
        }
        sqlite3_busy_timeout(read, 100)
        guard sqlite3_exec(read, "BEGIN; SELECT count(*) FROM sqlite_master;", nil, nil, nil) == SQLITE_OK else {
            throw DBError.step("cannot start a read of the database to copy")
        }
        defer { sqlite3_exec(read, "ROLLBACK;", nil, nil, nil) }
        guard let backup = sqlite3_backup_init(write, "main", read, "main") else {
            throw DBError.step("backup could not start: " + String(cString: sqlite3_errmsg(write)))
        }
        var finished = false
        defer { if !finished { sqlite3_backup_finish(backup) } }
        var busyAttempts = 0
        while true {
            try checkCancellation()
            let status = sqlite3_backup_step(backup, 256)
            if status == SQLITE_DONE { break }
            if status == SQLITE_BUSY || status == SQLITE_LOCKED {
                busyAttempts += 1
                guard busyAttempts <= 160 else { throw DBError.step("the database stayed busy") }
                Thread.sleep(forTimeInterval: 0.025)
            } else if status != SQLITE_OK {
                throw DBError.step("backup failed (\(status))")
            }
        }
        let status = sqlite3_backup_finish(backup)
        finished = true
        guard status == SQLITE_OK else { throw DBError.step("backup could not finish (\(status))") }
    }

    /// `PRAGMA integrity_check` through a read-only connection of its own: the check reads the
    /// whole file (seconds on a large catalog, tens of them cold), and on this connection it held
    /// the lock every edit waits for. True when SQLite reports nothing wrong. Like `snapshot`, it needs the catalog's
    /// security scope active and the WAL's -shm there, as it is while this connection is open; its
    /// read holds back background checkpoints until it ends, so the WAL grows by what is written
    /// meanwhile (the ceiling still bounds it).
    func integrityCheck() throws -> Bool {
        let read = try Self.openReadOnly(path)
        defer { sqlite3_close(read) }
        sqlite3_busy_timeout(read, 4000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(read, "PRAGMA integrity_check;", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw DBError.prepare(String(cString: sqlite3_errmsg(read)))
        }
        defer { sqlite3_finalize(statement) }
        var rows: [String] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw DBError.step(String(cString: sqlite3_errmsg(read))) }
            rows.append(sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "")
        }
        return rows == ["ok"]
    }

    /// A read-only connection of its own to the database at `path`, for work that shouldn't wait
    /// on this connection's lock. The caller closes it.
    private static func openReadOnly(_ path: String) throws -> OpaquePointer {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close(handle)
            throw DBError.open(message)
        }
        return handle
    }

    func run(_ sql: String, _ params: [SQLValue] = []) throws {
        try locked {
            let stmt = try preparedStatement(sql, params)
            defer { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
                throw DBError.step(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    func query(_ sql: String, _ params: [SQLValue] = []) throws -> [Row] {
        try queryMap(sql, params) { $0 }
    }

    /// Decodes rows as SQLite advances so callers with large result sets do not
    /// retain an intermediate array of dictionaries alongside their final models.
    func queryMap<T>(_ sql: String, _ params: [SQLValue] = [],
                     transform: (Row) throws -> T?) throws -> [T] {
        try locked {
            let stmt = try preparedStatement(sql, params)
            defer { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
            var values: [T] = []
            let columns = SQLiteRow(stmt: stmt)
            let cols = Int(sqlite3_column_count(stmt))
            // column names are stable for the statement — read them once, not per row
            let names = (0..<cols).map { String(cString: sqlite3_column_name(stmt, Int32($0))) }
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { return values }
                guard rc == SQLITE_ROW else {
                    throw DBError.step(String(cString: sqlite3_errmsg(db)))
                }
                let value = try autoreleasepool { () throws -> T? in
                    var row = Row(minimumCapacity: cols)
                    for c in 0..<cols {
                        let i = Int32(c)
                        let name = names[c]
                        switch sqlite3_column_type(stmt, i) {
                        case SQLITE_INTEGER: row[name] = .int(Int(sqlite3_column_int64(stmt, i)))
                        case SQLITE_FLOAT: row[name] = .double(sqlite3_column_double(stmt, i))
                        // by its byte count: a NUL inside the text doesn't end it
                        case SQLITE_TEXT: row[name] = .text(String(decoding: columns.bytes(i), as: UTF8.self))
                        case SQLITE_BLOB:
                            // an empty BLOB has no bytes to point at (the pointer is NULL), but
                            // it's still a value: a face kept without a vector, say
                            if let bytes = sqlite3_column_blob(stmt, i) {
                                row[name] = .blob(Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, i))))
                            } else { row[name] = .blob(Data()) }
                        default: row[name] = .null
                        }
                    }
                    return try transform(row)
                }
                if let value { values.append(value) }
            }
        }
    }

    /// Like `queryMap`, but hands the transform raw column access instead of a dictionary.
    func queryRows<T>(_ sql: String, _ params: [SQLValue] = [],
                      transform: (SQLiteRow) throws -> T?) throws -> [T] {
        try locked {
            let stmt = try preparedStatement(sql, params)
            defer { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
            var values: [T] = []
            let row = SQLiteRow(stmt: stmt)
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { return values }
                guard rc == SQLITE_ROW else { throw DBError.step(String(cString: sqlite3_errmsg(db))) }
                if let value = try transform(row) { values.append(value) }
            }
        }
    }

    func transaction(_ body: () throws -> Void) throws {
        try locked {
            guard exec("BEGIN;") else { throw DBError.step(String(cString: sqlite3_errmsg(db))) }
            do {
                try body()
            } catch {
                exec("ROLLBACK;")
                throw error
            }
            guard exec("COMMIT;") else {
                let message = String(cString: sqlite3_errmsg(db))
                exec("ROLLBACK;")
                throw DBError.step(message)
            }
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
            let rc: Int32
            switch p {
            case .int(let v): rc = sqlite3_bind_int64(stmt, idx, Int64(v))
            case .double(let v): rc = sqlite3_bind_double(stmt, idx, v)
            case .text(let v):
                // by its byte count, so a NUL inside doesn't end it
                rc = v.withCString {
                    sqlite3_bind_text64(stmt, idx, $0, sqlite3_uint64(v.utf8.count), SQLITE_TRANSIENT, UInt8(SQLITE_UTF8))
                }
            case .blob(let d) where d.isEmpty:
                // empty data may have no address, and a NULL pointer would bind NULL, not an empty BLOB
                rc = sqlite3_bind_zeroblob(stmt, idx, 0)
            case .blob(let d):
                // a 64-bit length: data past SQLite's limit is refused (SQLITE_TOOBIG), never cut short
                rc = d.withUnsafeBytes {
                    sqlite3_bind_blob64(stmt, idx, $0.baseAddress, sqlite3_uint64($0.count), SQLITE_TRANSIENT)
                }
            case .null: rc = sqlite3_bind_null(stmt, idx)
            }
            // a value that doesn't bind (a parameter with no placeholder, one too big) would leave
            // NULL in its place: the statement isn't run without it
            guard rc == SQLITE_OK else {
                throw DBError.bind("parameter \(idx) of \(sqlite3_bind_parameter_count(stmt)): "
                                   + String(cString: sqlite3_errstr(rc)))
            }
        }
        return stmt
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
