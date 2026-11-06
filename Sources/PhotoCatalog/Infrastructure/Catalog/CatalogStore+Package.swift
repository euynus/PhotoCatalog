import Foundation

extension CatalogStore {
    var cacheURL: URL { packageURL.appendingPathComponent("Cache") }
    var thumb256URL: URL { cacheURL.appendingPathComponent("Thumbnails/256") }
    var thumb512URL: URL { cacheURL.appendingPathComponent("Thumbnails/512") }
    var preview1600URL: URL { cacheURL.appendingPathComponent("Previews/1600") }
    var preview2048URL: URL { cacheURL.appendingPathComponent("Previews/2048") }
    var backupsURL: URL { packageURL.appendingPathComponent("Backups") }
    var configURL: URL { packageURL.appendingPathComponent("Config") }
    var originalsURL: URL { packageURL.appendingPathComponent("Originals") }
    var logsURL: URL { packageURL.appendingPathComponent("Logs") }
    var tempURL: URL { packageURL.appendingPathComponent("Temp") }

    static var defaultURL: URL {
        FileAccessService.picturesFolder.appendingPathComponent("PhotoCatalog Library.photolibrary")
    }

    // ---------- backup (§6.12) ----------
    @discardableResult
    func backup(stamp: String) throws -> URL {
        let src = packageURL.appendingPathComponent("catalog.sqlite")
        // the stamp is 1-second granular, so a pre-restore safety backup can collide with an
        // auto-backup from the same second — never overwrite an existing backup; pick -N instead.
        // Anything by that name takes it, a symbolic link too, even one pointing nowhere (which
        // fileExists doesn't see): the copy would be written wherever it points.
        let fm = FileManager.default
        var dest = backupsURL.appendingPathComponent("catalog-\(stamp).sqlite")
        var n = 1
        while (try? fm.attributesOfItem(atPath: dest.path)) != nil {
            dest = backupsURL.appendingPathComponent("catalog-\(stamp)-\(n).sqlite")
            n += 1
        }
        // SQLite's own copy, as of one commit and WAL included: a self-contained file (the restore
        // path deletes -wal/-shm sidecars) that writes made meanwhile can't tear, as they could a
        // byte copy of the file on a volume without clones. It refuses a link planted at the name
        // meanwhile; as SQLite refuses one anywhere in a path, the folders' links are resolved first.
        do {
            try Database.snapshot(from: Self.physical(src),
                                  to: Self.physical(backupsURL).appendingPathComponent(dest.lastPathComponent),
                                  followingLinks: false)
        } catch {
            for path in [dest.path, dest.path + "-journal", dest.path + "-wal", dest.path + "-shm"] {
                try? fm.removeItem(atPath: path)
            }
            throw error
        }
        return dest
    }

    /// `url` with every symbolic link in its path resolved, or as it is when it can't be.
    private static func physical(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    // ---------- manifest.json (§9) ----------
    func writeManifestIfNeeded() {
        let url = packageURL.appendingPathComponent("manifest.json")
        let existing = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        if existing["schemaVersion"] as? Int == Self.latestSchemaVersion { return }
        let manifest: [String: Any] = [
            "libraryVersion": 1, "schemaVersion": Self.latestSchemaVersion,
            "createdAt": existing["createdAt"] as? String ?? Self.iso(Date()),
            "appBuild": "1.0.0", "uuid": existing["uuid"] as? String ?? UUID().uuidString,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: manifest, options: .prettyPrinted) {
            try? data.write(to: url)
        }
    }
}
