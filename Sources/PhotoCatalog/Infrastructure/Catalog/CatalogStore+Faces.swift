import Foundation

extension CatalogStore {
    // ---------- faces ----------
    func loadFaces() throws -> [FaceRecord] {
        try db.query("SELECT id, asset_id, x, y, w, h, quality, vector, person, confirmed FROM faces;").compactMap { row in
            guard let id = row.text("id"), let assetId = row.text("asset_id"), let blob = row.blob("vector") else {
                return nil
            }
            let vector = blob.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            return FaceRecord(id: id, assetId: assetId,
                              box: CGRect(x: row.double("x") ?? 0, y: row.double("y") ?? 0,
                                          width: row.double("w") ?? 0, height: row.double("h") ?? 0),
                              quality: Float(row.double("quality") ?? 0), vector: vector,
                              person: row.text("person"), confirmed: (row.int("confirmed") ?? 0) != 0)
        }
    }

    func loadFaceScannedAssetIds() throws -> Set<String> {
        Set(try db.query("SELECT asset_id FROM face_scans;").compactMap { $0.text("asset_id") })
    }

    /// Records a scan of each asset (replacing earlier faces for it) in one transaction.
    func saveFaceScans(_ scans: [String: [FaceRecord]]) throws {
        let now = Self.iso(.now)
        try db.transaction {
            for (assetId, faces) in scans {
                try db.run("DELETE FROM faces WHERE asset_id=?;", [.text(assetId)])
                for face in faces {
                    let blob = face.vector.withUnsafeBufferPointer { Data(buffer: $0) }
                    try db.run("""
                    INSERT INTO faces(id, asset_id, x, y, w, h, quality, vector, person, confirmed)
                    VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """, [.text(face.id), .text(assetId), .double(face.box.minX), .double(face.box.minY),
                          .double(face.box.width), .double(face.box.height), .double(Double(face.quality)),
                          .blob(blob), face.person.map { .text($0) } ?? .null, .int(face.confirmed ? 1 : 0)])
                }
                try db.run("""
                INSERT INTO face_scans(asset_id, scanned_at) VALUES(?, ?)
                ON CONFLICT(asset_id) DO UPDATE SET scanned_at=excluded.scanned_at;
                """, [.text(assetId), .text(now)])
            }
        }
    }

    /// Names (or with nil, un-names) faces.
    func setFacePeople(_ changes: [String: (person: String?, confirmed: Bool)]) throws {
        try db.transaction {
            for (id, change) in changes {
                try db.run("UPDATE faces SET person=?, confirmed=? WHERE id=?;",
                           [change.person.map { .text($0) } ?? .null, .int(change.confirmed ? 1 : 0), .text(id)])
            }
        }
    }
}
