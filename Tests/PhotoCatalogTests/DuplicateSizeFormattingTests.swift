import XCTest
@testable import PhotoCatalog

final class DuplicateSizeFormattingTests: XCTestCase {
    func testSmallDuplicateSizeUsesKilobytesInsteadOfZeroMegabytes() {
        let text = duplicateByteSizeText(megabytes: 0.125)

        XCTAssertTrue(text.contains("KB"), "Unexpected byte count: \(text)")
        XCTAssertFalse(text.contains("0 MB"))
    }

    func testDuplicateSizeUsesMegabytesForLargerFiles() {
        let text = duplicateByteSizeText(megabytes: 2.5)

        XCTAssertTrue(text.contains("MB"), "Unexpected byte count: \(text)")
    }
}
