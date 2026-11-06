import XCTest
@testable import PhotoCatalog

/// The web gallery and the book share one caption type: their saved settings read and write the
/// same text as before, and their pickers list the choices in the same order.
final class GalleryCaptionTests: XCTestCase {
    func testCaptionsKeepTheirSavedValuesAndOrder() throws {
        XCTAssertEqual(WebGallerySettings.Caption.allCases.map(\.rawValue), ["none", "title", "caption", "filename"])
        XCTAssertEqual(BookSettings.Caption.allCases.map(\.rawValue), ["none", "title", "caption", "filename"])
        XCTAssertEqual(SlideshowSettings.Caption.allCases.map(\.rawValue), ["none", "title", "filename", "caption"])
        for caption in GalleryCaption.allCases {
            var gallery = WebGallerySettings()
            gallery.caption = caption
            let galleryJSON = try JSONEncoder().encode(gallery)
            XCTAssertTrue(String(decoding: galleryJSON, as: UTF8.self).contains("\"caption\":\"\(caption.rawValue)\""))
            XCTAssertEqual(try JSONDecoder().decode(WebGallerySettings.self, from: galleryJSON), gallery)
            var book = BookSettings()
            book.caption = caption
            let bookJSON = try JSONEncoder().encode(book)
            XCTAssertTrue(String(decoding: bookJSON, as: UTF8.self).contains("\"caption\":\"\(caption.rawValue)\""))
            XCTAssertEqual(try JSONDecoder().decode(BookSettings.self, from: bookJSON), book)
        }
    }
}
