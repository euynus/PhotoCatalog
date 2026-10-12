import XCTest

/// English counted nouns: a count of one reads in the singular. The forms come from
/// `en.lproj/Localizable.stringsdict`, which `script/check_localization.py plurals` generates from
/// the English table; these are read straight from the repository, whatever this Mac's language.
final class PluralLocalizationTests: XCTestCase {
    private static let english = Bundle(path: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/Localization/en.lproj").path)

    private func english(_ key: String, _ arguments: CVarArg...) throws -> String {
        let bundle = try XCTUnwrap(Self.english, "no en.lproj in Resources/Localization")
        let format = bundle.localizedString(forKey: key, value: nil, table: nil)
        return String(format: format, locale: Locale(identifier: "en_US"), arguments: arguments)
    }

    func testCountedNounsAreSingularForOne() throws {
        // generated before: lower-case nouns after a count
        XCTAssertEqual(try english("已从「%@」移除 %lld 张照片", "Trip", 1), "Removed 1 photo from “Trip”")

        // title-case nouns
        XCTAssertEqual(try english("打印 %lld 张照片", 1), "Print 1 Photo")
        XCTAssertEqual(try english("打印 %lld 张照片", 3), "Print 3 Photos")
        XCTAssertEqual(try english("PhotoCatalog 打印 %lld 张照片", 1), "PhotoCatalog: Print 1 Photo")
        XCTAssertEqual(try english("导出 %lld 张照片", 1), "Export 1 Photo")
        XCTAssertEqual(try english("添加 %lld 个位置", 1), "Add 1 Location")
        XCTAssertEqual(try english("添加 %lld 个位置", 2), "Add 2 Locations")

        // a noun after a file format, its count a positional argument
        XCTAssertEqual(try english("正在为 %@ 准备 %lld 张 TIFF…", "Photoshop", 1), "Preparing 1 TIFF file for Photoshop…")
        XCTAssertEqual(try english("正在为 %@ 准备 %lld 张 TIFF…", "Photoshop", 4), "Preparing 4 TIFF files for Photoshop…")
    }
}
