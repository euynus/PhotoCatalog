// ============================================================
//  Slideshow video — the slideshow written as an MP4, with its music
// ============================================================
import AVFoundation
import CoreGraphics
import CoreText
import Foundation

/// Where a photo sits in a slideshow frame: fitted inside it, then grown by `scale` around its
/// center and moved by `offset` (fractions of the frame). The player and the video both place
/// photos this way, so a video shows what was watched.
enum SlideshowLayout {
    static func rect(imageSize: CGSize, in frame: CGSize, scale: Double = 1, offset: CGVector = .zero) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let fit = min(frame.width / imageSize.width, frame.height / imageSize.height) * scale
        let size = CGSize(width: imageSize.width * fit, height: imageSize.height * fit)
        return CGRect(x: (frame.width - size.width) / 2 + offset.dx * frame.width,
                      y: (frame.height - size.height) / 2 + offset.dy * frame.height,
                      width: size.width, height: size.height)
    }
}

/// One photo of a slideshow video: how to render it, and its caption.
struct SlideshowSlide: Sendable {
    let item: PrintItem
    let caption: String
}

enum SlideshowVideo {
    static let framesPerSecond = 30
    /// How long the music fades out before the video ends.
    static let musicFade = 2.0

    /// Writes `slides` (in play order) as an H.264 MP4 at `settings`' size, each photo for
    /// `slideSeconds`, with the music when there is some (cut at the end, after fading out).
    /// `progress` gets 0…1; false when it was cancelled or couldn't be written (nothing is
    /// left behind).
    static func export(_ slides: [SlideshowSlide], settings: SlideshowSettings, slideSeconds: Double, music: URL?,
                       to url: URL, progress: @escaping @Sendable (Double) -> Void,
                       cancelled: @escaping @Sendable () -> Bool) -> Bool {
        guard !slides.isEmpty else { return false }
        try? FileManager.default.removeItem(at: url)
        let size = settings.videoSize.pixels
        let timeline = SlideshowTimeline(count: slides.count, slide: slideSeconds, fade: settings.fadeSeconds, repeats: false)
        let frames = Int((timeline.duration * Double(framesPerSecond)).rounded())
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return false }
        let colors: [String: Any] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
            AVVideoColorPropertiesKey: colors,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: size.width * size.height * 6],
        ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height,
        ])
        guard writer.canAdd(video) else { return false }
        writer.add(video)
        let audio = music.flatMap { MusicReader(url: $0, duration: timeline.duration) }
        let audioInput = audio.map { _ in
            AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: MusicReader.sampleRate,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000,
            ])
        }
        if let audioInput, writer.canAdd(audioInput) { writer.add(audioInput) }
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)

        let renderer = SlideRenderer(slides: slides, size: size, settings: settings)
        let group = DispatchGroup()
        let failed = Flag()
        group.enter()
        var frame = 0
        video.requestMediaDataWhenReady(on: DispatchQueue(label: "PhotoCatalog.slideshow.video")) {
            while video.isReadyForMoreMediaData {
                guard frame < frames, !cancelled(), !failed.isSet else {
                    video.markAsFinished()
                    group.leave()
                    return
                }
                let time = Double(frame) / Double(framesPerSecond)
                guard let pool = adaptor.pixelBufferPool, let buffer = renderer.frame(timeline.frame(at: time), pool: pool),
                      adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(framesPerSecond)))
                else {
                    failed.set()
                    continue
                }
                frame += 1
                if frame % 15 == 0 { progress(Double(frame) / Double(frames)) }
            }
        }
        if let audio, let audioInput, writer.inputs.contains(audioInput) {
            group.enter()
            audioInput.requestMediaDataWhenReady(on: DispatchQueue(label: "PhotoCatalog.slideshow.audio")) {
                while audioInput.isReadyForMoreMediaData {
                    guard !cancelled(), !failed.isSet, let buffer = audio.next() else {
                        audioInput.markAsFinished()
                        group.leave()
                        return
                    }
                    if !audioInput.append(buffer) { failed.set() }
                }
            }
        }
        group.wait()
        guard !cancelled(), !failed.isSet, writer.status == .writing else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            return false
        }
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(framesPerSecond)))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            return false
        }
        progress(1)
        return true
    }

    /// How long the music at `url` lasts, in seconds.
    static func musicDuration(_ url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        return seconds > 0 ? seconds : nil
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }
}

/// Draws slideshow frames, keeping the photos showing and about to show rendered.
private final class SlideRenderer: @unchecked Sendable {
    let slides: [SlideshowSlide]
    let size: CGSize
    let settings: SlideshowSettings
    private var rendered: [Int: CGImage] = [:]
    private let space = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()

    init(slides: [SlideshowSlide], size: CGSize, settings: SlideshowSettings) {
        self.slides = slides
        self.size = size
        self.settings = settings
    }

    /// Photo `index` rendered big enough for its largest zoom.
    private func image(_ index: Int) -> CGImage? {
        if let image = rendered[index] { return image }
        let item = slides[index].item
        let aspect = item.aspect
        let fit = min(size.width / aspect, size.height) * 1.15
        let pixels = CGSize(width: (fit * aspect).rounded(), height: fit.rounded())
        guard let developed = item.developed(forLongEdge: Double(max(pixels.width, pixels.height))),
              let image = DevelopRenderer.render(developed) else { return nil }
        // the photos showing now and next; earlier ones are let go
        rendered = rendered.filter { $0.key >= index - 1 }
        rendered[index] = image
        return image
    }

    func frame(_ frame: SlideshowTimeline.Frame, pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.setFillColor(gray: settings.backdrop.gray, alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))
        // the next photo fades in over this one; their captions take turns
        draw(frame.index, progress: frame.progress, alpha: 1, captionAlpha: frame.captionAlpha, in: context)
        if let next = frame.next { draw(next, progress: 0, alpha: frame.blend, captionAlpha: frame.nextCaptionAlpha, in: context) }
        return buffer
    }

    private func draw(_ index: Int, progress: Double, alpha: Double, captionAlpha: Double, in context: CGContext) {
        guard let image = image(index) else { return }
        let motion = settings.panAndZoom ? SlideshowTimeline.panAndZoom(index: index, progress: progress) : (scale: 1, offset: .zero)
        var rect = SlideshowLayout.rect(imageSize: CGSize(width: image.width, height: image.height), in: size,
                                        scale: motion.scale, offset: motion.offset)
        // the layout's y points down, the context's up
        rect.origin.y = size.height - rect.maxY
        context.saveGState()
        context.setAlpha(alpha)
        context.draw(image, in: rect)
        context.restoreGState()
        let caption = slides[index].caption
        if !caption.isEmpty, captionAlpha > 0 {
            context.saveGState()
            context.setAlpha(captionAlpha)
            drawCaption(caption, in: context)
            context.restoreGState()
        }
    }

    private func drawCaption(_ text: String, in context: CGContext) {
        let fontSize = size.height * 0.03
        let font = CTFontCreateWithName("Helvetica Neue" as CFString, fontSize, nil)
        let color = CGColor(gray: settings.backdrop.captionGray, alpha: 1)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        // a soft shadow keeps it readable over a light photo
        context.setShadow(offset: CGSize(width: 0, height: -1), blur: fontSize * 0.3,
                          color: CGColor(gray: settings.backdrop == .white ? 1 : 0, alpha: 0.7))
        context.textPosition = CGPoint(x: (size.width - width) / 2, y: size.height * 0.05)
        CTLineDraw(line, context)
    }
}

/// The music as 16-bit stereo PCM, cut at `duration` and fading out over its last seconds.
private final class MusicReader: @unchecked Sendable {
    static let sampleRate = 44_100.0
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let duration: Double

    init?(url: URL, duration: Double) {
        let asset = AVURLAsset(url: url)
        guard let track = Self.audioTrack(asset), let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.sampleRate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        self.reader = reader
        self.output = output
        self.duration = duration
    }

    /// The music's first audio track, waited for from synchronous code.
    private static func audioTrack(_ asset: AVURLAsset) -> AVAssetTrack? {
        let done = DispatchSemaphore(value: 0)
        let box = TrackBox()
        Task.detached {
            box.track = try? await asset.loadTracks(withMediaType: .audio).first
            done.signal()
        }
        guard done.wait(timeout: .now() + 10) == .success else { return nil }
        return box.track
    }

    private final class TrackBox: @unchecked Sendable { var track: AVAssetTrack? }

    /// The next buffer before the video's end, faded as the end nears; nil once past it.
    func next() -> CMSampleBuffer? {
        guard let buffer = output.copyNextSampleBuffer() else { return nil }
        let start = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
        guard start < duration else {
            reader.cancelReading()
            return nil
        }
        let fadeStart = duration - SlideshowVideo.musicFade
        guard start + CMSampleBufferGetDuration(buffer).seconds > fadeStart,
              let block = CMSampleBufferGetDataBuffer(buffer) else { return buffer }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                          dataPointerOut: &pointer) == kCMBlockBufferNoErr, let pointer else { return buffer }
        let samples = UnsafeMutableRawPointer(pointer).bindMemory(to: Int16.self, capacity: length / 2)
        let frames = length / 4
        for frame in 0..<frames {
            let time = start + Double(frame) / Self.sampleRate
            let gain = Float(min(1, max(0, (duration - time) / SlideshowVideo.musicFade)))
            samples[frame * 2] = Int16(Float(samples[frame * 2]) * gain)
            samples[frame * 2 + 1] = Int16(Float(samples[frame * 2 + 1]) * gain)
        }
        return buffer
    }
}
