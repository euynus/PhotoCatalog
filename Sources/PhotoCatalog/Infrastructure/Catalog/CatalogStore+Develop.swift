import Foundation

extension CatalogStore {
    // ---------- develop settings ----------
    func loadDevelopSettings() throws -> [String: DevelopSettings] {
        let decoder = JSONDecoder()
        var result: [String: DevelopSettings] = [:]
        for row in try db.query("SELECT asset_id, settings FROM develop_settings;") {
            guard let id = row.text("asset_id"), let json = row.text("settings"),
                  let settings = try? decoder.decode(DevelopSettings.self, from: Data(json.utf8)) else { continue }
            result[id] = settings
        }
        return result
    }

    /// Stores `settings` for each asset; neutral settings delete the row (the photo is as shot).
    func saveDevelopSettings(_ settings: [String: DevelopSettings]) throws {
        try db.transaction { try writeDevelopSettings(settings) }
    }

    /// As `saveDevelopSettings(_:)`, with the stored text of some of the values already encoded
    /// (`DevelopHistoryStep.json`); the others are encoded here.
    func saveDevelopSettings(_ settings: [String: DevelopSettings], json: [String: String]) throws {
        try db.transaction { try writeDevelopSettings(settings, json: json) }
    }

    /// Virtual copies with the develop settings they start from, in one transaction: a copy is
    /// never in the catalog without them.
    func saveVirtualCopies(_ copies: [Asset], developSettings: [String: DevelopSettings]) throws {
        try db.transaction {
            try upsertRows(copies)
            try writeDevelopSettings(developSettings)
        }
    }

    private func writeDevelopSettings(_ settings: [String: DevelopSettings], json encoded: [String: String] = [:]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for (id, value) in settings {
            if value.isNeutral {
                try db.run("DELETE FROM develop_settings WHERE asset_id=?;", [.text(id)])
            } else {
                let json = try encoded[id] ?? String(decoding: encoder.encode(value), as: UTF8.self)
                try db.run("""
                INSERT INTO develop_settings(asset_id, settings, updated_at) VALUES(?, ?, ?)
                ON CONFLICT(asset_id) DO UPDATE SET settings=excluded.settings, updated_at=excluded.updated_at;
                """, [.text(id), .text(json), .text(Self.iso(.now))])
            }
        }
    }

    // ---------- sidecars changed by other apps ----------
    /// Each photo's sidecar modification time (seconds since 1970) as of our last read or write.
    func loadXMPSyncTimes() throws -> [String: Double] {
        var result: [String: Double] = [:]
        for row in try db.query("SELECT asset_id, modified_at FROM xmp_sync;") {
            if let id = row.text("asset_id"), let time = row.double("modified_at") { result[id] = time }
        }
        return result
    }

    func saveXMPSyncTimes(_ times: [String: Double]) throws {
        guard !times.isEmpty else { return }
        try db.transaction {
            for (id, time) in times {
                try db.run("""
                INSERT INTO xmp_sync(asset_id, modified_at) VALUES(?, ?)
                ON CONFLICT(asset_id) DO UPDATE SET modified_at=excluded.modified_at;
                """, [.text(id), .double(time)])
            }
        }
    }

    // ---------- develop history and snapshots ----------
    /// A photo's develop steps, oldest first.
    func loadDevelopHistory(_ assetId: String) throws -> [DevelopHistoryStep] {
        try db.query("""
        SELECT seq, name, created_at, settings FROM develop_history WHERE asset_id=? ORDER BY seq;
        """, [.text(assetId)]).compactMap { row in
            guard let seq = row.int("seq"), let name = row.text("name"), let json = row.text("settings") else { return nil }
            return DevelopHistoryStep(seq: seq, name: name, date: Self.date(row.text("created_at")) ?? .distantPast,
                                      json: json)
        }
    }

    /// Adds a step to each photo's history, dropping the oldest beyond the limit. Returns the
    /// steps as stored.
    @discardableResult
    func appendDevelopHistory(_ steps: [String: (name: String, settings: DevelopSettings)], date: Date = .now) throws
        -> [String: DevelopHistoryStep] {
        try appendDevelopHistory(steps.mapValues { (name: $0.name, json: DevelopHistoryStep.json($0.settings)) },
                                 date: date)
    }

    /// As above, with each step's settings already in their stored form (`DevelopHistoryStep.json`).
    @discardableResult
    func appendDevelopHistory(_ steps: [String: (name: String, json: String)], date: Date = .now) throws
        -> [String: DevelopHistoryStep] {
        var stored: [String: DevelopHistoryStep] = [:]
        let created = Self.iso(date)
        try db.transaction {
            for (id, step) in steps {
                let json = step.json
                // one statement numbers and inserts the step
                guard let seq = try db.queryMap("""
                INSERT INTO develop_history(asset_id, seq, name, created_at, settings)
                SELECT ?, COALESCE(MAX(seq), 0) + 1, ?, ?, ? FROM develop_history WHERE asset_id=?
                RETURNING seq;
                """, [.text(id), .text(step.name), .text(created), .text(json), .text(id)],
                                        transform: { $0.int("seq") }).first ?? nil else { continue }
                // trimming only once the history is long enough to need it
                if seq > DevelopHistoryStep.limit {
                    try db.run("DELETE FROM develop_history WHERE asset_id=? AND seq<=?;",
                               [.text(id), .int(seq - DevelopHistoryStep.limit)])
                }
                stored[id] = DevelopHistoryStep(seq: seq, name: step.name, date: date, json: json)
            }
        }
        return stored
    }

    /// Takes each photo's newest step away (an undone edit).
    func removeLastDevelopHistory(_ assetIds: [String]) throws {
        try db.transaction {
            for id in assetIds {
                try db.run("""
                DELETE FROM develop_history WHERE asset_id=?
                  AND seq=(SELECT MAX(seq) FROM develop_history WHERE asset_id=?);
                """, [.text(id), .text(id)])
            }
        }
    }

    func clearDevelopHistory(_ assetId: String) throws {
        try db.run("DELETE FROM develop_history WHERE asset_id=?;", [.text(assetId)])
    }

    /// A photo's snapshots, oldest first.
    func loadDevelopSnapshots(_ assetId: String) throws -> [DevelopSnapshot] {
        let decoder = JSONDecoder()
        return try db.query("""
        SELECT id, name, created_at, settings FROM develop_snapshots WHERE asset_id=? ORDER BY created_at, rowid;
        """, [.text(assetId)]).compactMap { row in
            guard let id = row.text("id"), let name = row.text("name"), let json = row.text("settings"),
                  let settings = try? decoder.decode(DevelopSettings.self, from: Data(json.utf8)) else { return nil }
            return DevelopSnapshot(id: id, name: name, date: Self.date(row.text("created_at")) ?? .distantPast,
                                   settings: settings)
        }
    }

    func saveDevelopSnapshot(_ snapshot: DevelopSnapshot, for assetId: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(snapshot.settings), as: UTF8.self)
        try db.run("""
        INSERT INTO develop_snapshots(id, asset_id, name, created_at, settings) VALUES(?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET name=excluded.name, settings=excluded.settings;
        """, [.text(snapshot.id), .text(assetId), .text(snapshot.name), .text(Self.iso(snapshot.date)), .text(json)])
    }

    func deleteDevelopSnapshot(_ id: String) throws {
        try db.run("DELETE FROM develop_snapshots WHERE id=?;", [.text(id)])
    }
}
