import XCTest
@testable import PhotoCatalog

/// An option the binary doesn't know stops it with its usage instead of opening the app, so a
/// headless run with a mistyped or removed check flag never becomes a window on the user's library.
final class LaunchOptionsTests: XCTestCase {
    func testAnUnknownOptionIsFound() {
        XCTAssertEqual(LaunchOptions.unknownOption(in: ["PhotoCatalog", "--help"]), "--help")
        XCTAssertEqual(LaunchOptions.unknownOption(in: ["PhotoCatalog", "--selfchek"]), "--selfchek")
        XCTAssertEqual(LaunchOptions.unknownOption(in: ["PhotoCatalog", "--"]), "--")
        XCTAssertEqual(LaunchOptions.unknownOption(in: ["PhotoCatalog", "/tmp/A.photolibrary", "--probe-check"]),
                       "--probe-check")
    }

    func testWhatTheAppIsOpenedWithIsNotAnOption() {
        XCTAssertNil(LaunchOptions.unknownOption(in: ["PhotoCatalog"]))
        XCTAssertNil(LaunchOptions.unknownOption(in: ["PhotoCatalog", "/tmp/A.photolibrary"]))
        XCTAssertNil(LaunchOptions.unknownOption(in: ["PhotoCatalog", "-pc_pairRawJpeg", "YES", "-NSDocumentRevisionsDebugMode", "YES"]))
        XCTAssertNil(LaunchOptions.unknownOption(in: ["PhotoCatalog", "--selfcheck", "--benchmark"]))
        // the program's own name never counts, whatever it is
        XCTAssertNil(LaunchOptions.unknownOption(in: ["--odd-name"]))
    }

    func testEveryModeMainRunsIsKnown() {
        for mode in ["--selfcheck", "--benchmark", "--pipeline", "--scale", "--import-memory-check",
                     "--full-backup-check", "--task-center-check", "--description-review-check"] {
            XCTAssertNil(LaunchOptions.unknownOption(in: ["PhotoCatalog", mode]), mode)
            XCTAssertTrue(LaunchOptions.usage.contains(mode), mode)
        }
    }
}
