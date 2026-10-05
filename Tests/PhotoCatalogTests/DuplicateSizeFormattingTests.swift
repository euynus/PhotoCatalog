import XCTest
@testable import PhotoCatalog

final class DuplicateSizeFormattingTests: XCTestCase {
    func testSmallDuplicateSizeUsesKilobytesInsteadOfZeroMegabytes() {
        let text = fileSizeText(megabytes: 0.125)

        XCTAssertTrue(text.contains("KB"), "Unexpected byte count: \(text)")
        XCTAssertFalse(text.contains("0 MB"))
    }

    func testDuplicateSizeUsesMegabytesForLargerFiles() {
        let text = fileSizeText(megabytes: 2.5)

        XCTAssertTrue(text.contains("MB"), "Unexpected byte count: \(text)")
    }

    func testSmallImageDoesNotDisplayAsZeroMegapixels() {
        XCTAssertEqual(megapixelText(0.02782), "<0.1 MP")
        XCTAssertEqual(megapixelText(0), "0 MP")
        XCTAssertEqual(megapixelText(12.34), "12.3 MP")
    }
}
