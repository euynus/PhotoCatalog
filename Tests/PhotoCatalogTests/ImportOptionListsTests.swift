import XCTest
@testable import PhotoCatalog

/// Settings and the Import sheet take their import choices from ImportOptionLists: the same
/// values, labels and order each sheet wrote out before.
final class ImportOptionListsTests: XCTestCase {
    func testImportModes() {
        XCTAssertEqual(ImportOptionLists.modes.map(\.value), ["referenced", "managed"])
        XCTAssertEqual(ImportOptionLists.modes.map(\.label), [L("原位添加"), L("复制到目录库")])
    }

    func testArchiveRules() {
        XCTAssertEqual(ImportOptionLists.archiveRules.map(\.value), ["date", "camera"])
        XCTAssertEqual(ImportOptionLists.archiveRules.map(\.label), [L("按日期"), L("按相机")])
    }

    func testDuplicateStrategiesStartWithGrouping() {
        XCTAssertEqual(ImportOptionLists.duplicateStrategies.map(\.value), ["groupExact", "skipExact", "keep"])
        XCTAssertEqual(ImportOptionLists.duplicateStrategies.map(\.label), [L("分组"), L("跳过"), L("保留")])
    }

    /// Every value a list offers reads back as its setting, so no choice hits a fallback.
    func testEveryValueIsASetting() {
        XCTAssertEqual(ImportOptionLists.modes.compactMap { ImportMode(rawValue: $0.value) }, [.referenced, .managed])
        XCTAssertEqual(ImportOptionLists.archiveRules.compactMap { ManagedArchiveRule(rawValue: $0.value) },
                       [.date, .camera])
        XCTAssertEqual(ImportOptionLists.duplicateStrategies.compactMap { ImportDuplicateStrategy(rawValue: $0.value) },
                       [.groupExact, .skipExact, .keep])
        XCTAssertEqual(Set(ImportOptionLists.archiveRules.map(\.value)), Set(ManagedArchiveRule.allCases.map(\.rawValue)))
        XCTAssertEqual(Set(ImportOptionLists.duplicateStrategies.map(\.value)),
                       Set(ImportDuplicateStrategy.allCases.map(\.rawValue)))
    }
}
