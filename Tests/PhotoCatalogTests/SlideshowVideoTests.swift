import XCTest
import AVFoundation
@testable import PhotoCatalog

/// Writing a slideshow video ends, however its inputs end.
final class SlideshowVideoTests: XCTestCase {
    /// A writer that stops (failed, or cancelled) never asks its inputs for more, so an input
    /// waiting its turn never says it's done: the export used to wait for it forever.
    func testAStoppedWriterEndsTheWaitForItsInputs() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pc-slideshow-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        writer.cancelWriting()
        // the input that will never come back
        let group = DispatchGroup()
        group.enter()
        let ended = expectation(description: "the wait ends")
        DispatchQueue.global().async {
            SlideshowVideo.waitForInputs(group, writer: writer, stop: { false })
            ended.fulfill()
        }
        wait(for: [ended], timeout: 5)
    }

    /// An input failing (or the export being cancelled) stops the writer and ends the wait,
    /// rather than leaving the other input waiting for its turn.
    func testAFailedInputEndsTheWait() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pc-slideshow-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let group = DispatchGroup()
        group.enter()
        let ended = expectation(description: "the wait ends")
        DispatchQueue.global().async {
            SlideshowVideo.waitForInputs(group, writer: writer, stop: { true })
            ended.fulfill()
        }
        wait(for: [ended], timeout: 5)
        XCTAssertNotEqual(writer.status, .writing, "the writer is stopped")
    }

    /// The wait may cancel the writer while an input is still finishing (the other input saw the
    /// failure and is about to say it's done): that input appending or finishing on the cancelled
    /// writer is refused quietly, not raised.
    func testAnInputFinishingAfterTheWriterWasCancelled() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pc-slideshow-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
        writer.cancelWriting()
        XCTAssertFalse(input.isReadyForMoreMediaData)
        XCTAssertFalse(adaptor.append(try XCTUnwrap(buffer), withPresentationTime: .zero))
        input.markAsFinished()
        XCTAssertEqual(writer.status, .cancelled)
    }
}
