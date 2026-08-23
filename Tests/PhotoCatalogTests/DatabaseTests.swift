import Foundation
import XCTest
@testable import PhotoCatalog

final class DatabaseTests: XCTestCase {
    func testQueryMapDecodesRowsInOrderAndDropsNilTransforms() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-query-map-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let database = try Database(path: directory.appendingPathComponent("catalog.sqlite").path)
        try database.execChecked("CREATE TABLE samples (id INTEGER PRIMARY KEY, name TEXT, score REAL, payload BLOB);")
        try database.run(
            "INSERT INTO samples (id, name, score, payload) VALUES (?, ?, ?, ?);",
            [.int(1), .text("first"), .double(1.5), .blob(Data([0x01]))]
        )
        try database.run(
            "INSERT INTO samples (id, name, score, payload) VALUES (?, ?, ?, ?);",
            [.int(2), .text("skip"), .double(2.5), .blob(Data([0x02]))]
        )
        try database.run(
            "INSERT INTO samples (id, name, score, payload) VALUES (?, ?, ?, ?);",
            [.int(3), .text("third"), .double(3.5), .blob(Data([0x03]))]
        )

        let decoded: [(Int, String, Double, Data)] = try database.queryMap(
            "SELECT id, name, score, payload FROM samples ORDER BY id;"
        ) { row in
            guard row.text("name") != "skip",
                  let id = row.int("id"),
                  let name = row.text("name"),
                  let score = row.double("score"),
                  let payload = row.blob("payload") else { return nil }
            return (id, name, score, payload)
        }

        XCTAssertEqual(decoded.map(\.0), [1, 3])
        XCTAssertEqual(decoded.map(\.1), ["first", "third"])
        XCTAssertEqual(decoded.map(\.2), [1.5, 3.5])
        XCTAssertEqual(decoded.map(\.3), [Data([0x01]), Data([0x03])])
    }
}
