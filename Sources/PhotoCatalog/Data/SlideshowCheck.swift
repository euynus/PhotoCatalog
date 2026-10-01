import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Slideshows: what shows when (fades between photos, a repeating show coming round), the
/// order (shuffled alike every time), timing fitted to music, pan and zoom that never shows an
/// edge, and the video: as long as the show, each photo where it should be, the music on it.
enum SlideshowCheck {
    static func run() {
        checkTimeline()
        checkSettings()
        checkVideo()
        print("--- slideshow assertions passed ---")
    }

    private static func checkTimeline() {
        let once = SlideshowTimeline(count: 3, slide: 2, fade: 0.5, repeats: false)
        let start = once.frame(at: 0.5), fading = once.frame(at: 1.75), last = once.frame(at: 5.9), over = once.frame(at: 6.1)
        assert(once.duration == 6 && start.index == 0 && start.next == nil && fading.index == 0 && fading.next == 1
               && abs(fading.blend - 0.5) < 1e-9 && last.index == 2 && last.next == nil && !last.finished && over.finished,
               "each photo shows its time and fades into the next; a show that doesn't repeat ends")
        let looping = SlideshowTimeline(count: 3, slide: 2, fade: 0.5, repeats: true)
        assert(looping.frame(at: 5.75).next == 0 && looping.frame(at: 6.5).index == 0 && !looping.frame(at: 60).finished,
               "a repeating show fades its last photo into its first and goes round")
        let cut = SlideshowTimeline(count: 2, slide: 1, fade: 0, repeats: false)
        assert(cut.frame(at: 0.99).next == nil && cut.frame(at: 1.01).index == 1, "no fade is a cut")
        assert(SlideshowTimeline(count: 2, slide: 1, fade: 5, repeats: false).fade == 0.5, "a fade takes at most half a photo's time")
        let early = once.frame(at: 1.6), late = once.frame(at: 1.9)
        assert(early.captionAlpha > 0 && early.nextCaptionAlpha == 0 && late.captionAlpha == 0 && late.nextCaptionAlpha > 0,
               "captions take turns through a fade, never showing both")

        var smallest = 2.0, largest = 0.0, farthest = 0.0
        for index in 0..<20 {
            for step in 0...10 {
                let motion = SlideshowTimeline.panAndZoom(index: index, progress: Double(step) / 10)
                smallest = min(smallest, motion.scale)
                largest = max(largest, motion.scale)
                farthest = max(farthest, abs(motion.offset.dx), abs(motion.offset.dy))
            }
        }
        let first = SlideshowTimeline.panAndZoom(index: 3, progress: 0.4)
        let again = SlideshowTimeline.panAndZoom(index: 3, progress: 0.4)
        func scale(_ index: Int, _ progress: Double) -> Double { SlideshowTimeline.panAndZoom(index: index, progress: progress).scale }
        let zoomsInThenOut = scale(0, 1) > scale(0, 0) && scale(1, 1) < scale(1, 0)
        let staysInside = smallest >= 1.05 - 1e-9 && largest <= 1.13 + 1e-9 && farthest <= (smallest - 1) / 2 + 1e-9
        assert(staysInside && zoomsInThenOut && first.scale == again.scale && first.offset == again.offset,
               "pan and zoom: the same for the same photo, zooming in and out in turn, never drifting past an edge")
        let rect = SlideshowLayout.rect(imageSize: CGSize(width: 3000, height: 2000), in: CGSize(width: 1920, height: 1080))
        assert(abs(rect.height - 1080) < 0.01 && abs(rect.midX - 960) < 0.01, "a photo is fitted in the frame, centered")
    }

    private static func checkSettings() {
        var settings = SlideshowSettings()
        assert(settings.order(5, seed: 7) == [0, 1, 2, 3, 4], "in list order unless shuffled")
        settings.shuffle = true
        let shuffled = settings.order(12, seed: 7)
        assert(shuffled == settings.order(12, seed: 7) && Set(shuffled) == Set(0..<12) && shuffled != Array(0..<12)
               && settings.order(12, seed: 8) != shuffled, "shuffled the same way for the same photos, every photo once")
        settings.fitToMusic = true
        assert(settings.slideSeconds(fitting: 10, toMusic: 60) == 6 && settings.slideSeconds(fitting: 10, toMusic: 5) == 1
               && settings.slideSeconds(fitting: 10, toMusic: nil) == settings.slideSeconds,
               "fitted to music, each photo shows long enough to fill it (but at least a second)")
        let stored = try! JSONDecoder().decode(SlideshowSettings.self, from: JSONEncoder().encode(settings))
        let empty = try! JSONDecoder().decode(SlideshowSettings.self, from: Data("{}".utf8))
        assert(stored == settings && empty == SlideshowSettings(), "settings persist, and missing ones take their defaults")
    }

    private static func solid(_ url: URL, _ color: (Double, Double, Double)) {
        let context = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
    }

    /// A 440 Hz tone, `seconds` long.
    private static func tone(_ url: URL, seconds: Double) {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let frames = AVAudioFrameCount(seconds * 44_100)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<2 {
            for i in 0..<Int(frames) { buffer.floatChannelData![channel][i] = Float(sin(Double(i) * 2 * .pi * 440 / 44_100) * 0.3) }
        }
        let file = try! AVAudioFile(forWriting: url, settings: format.settings)
        try! file.write(from: buffer)
    }

    /// The frame at `seconds`, from a synchronous check.
    private static func frame(_ url: URL, at seconds: Double) -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var image: CGImage?
        generator.generateCGImageAsynchronously(for: CMTime(seconds: seconds, preferredTimescale: 600)) { result, _, _ in
            image = result
            done.signal()
        }
        done.wait()
        return image
    }

    /// The color at the middle of `image`, 0…255.
    private static func middle(_ image: CGImage) -> (r: Int, g: Int, b: Int) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    private static func checkVideo() {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("pc-slideshow-\(UUID().uuidString)")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let colors = [(0.9, 0.1, 0.1), (0.1, 0.8, 0.2), (0.1, 0.2, 0.9)]
        let slides = colors.enumerated().map { index, color -> SlideshowSlide in
            let url = folder.appendingPathComponent("slide\(index).png")
            solid(url, color)
            return SlideshowSlide(item: PrintItem(sourcePath: url.path, isRaw: false, develop: .neutral,
                                                  originalSize: CGSize(width: 600, height: 400), filename: url.lastPathComponent, title: ""),
                                  caption: index == 1 ? "Slide two" : "")
        }
        let music = folder.appendingPathComponent("tone.caf")
        tone(music, seconds: 5)
        var settings = SlideshowSettings()
        settings.videoSize = .hd720
        settings.fadeSeconds = 0.5
        settings.panAndZoom = false
        let output = folder.appendingPathComponent("show.mp4")
        assert(abs((SlideshowVideo.musicDuration(music) ?? 0) - 5) < 0.01, "the music's length is read")
        let made = SlideshowVideo.export(slides, settings: settings, slideSeconds: 1, music: music, to: output,
                                         progress: { _ in }, cancelled: { false })
        let asset = AVURLAsset(url: output)
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var duration = 0.0, size = CGSize.zero, audioTracks = 0
        Task.detached {
            duration = (try? await asset.load(.duration))?.seconds ?? 0
            if let track = try? await asset.loadTracks(withMediaType: .video).first { size = (try? await track.load(.naturalSize)) ?? .zero }
            audioTracks = (try? await asset.loadTracks(withMediaType: .audio))?.count ?? 0
            done.signal()
        }
        done.wait()
        assert(made && abs(duration - 3) < 0.1 && size == CGSize(width: 1280, height: 720) && audioTracks == 1,
               "the video lasts as long as the show, at its size, with the music")
        let shots = [0.25, 1.25, 2.25, 0.75].compactMap { frame(output, at: $0) }.map(middle)
        assert(shots.count == 4 && shots[0].r > 180 && shots[0].g < 60 && shots[1].g > 150 && shots[1].r < 60
               && shots[2].b > 180 && shots[2].r < 60 && shots[3].r > 60 && shots[3].g > 60,
               "each photo shows in its turn, and fades into the next")
        let cancelled = SlideshowVideo.export(slides, settings: settings, slideSeconds: 1, music: nil,
                                              to: folder.appendingPathComponent("cancelled.mp4"), progress: { _ in }, cancelled: { true })
        assert(!cancelled && !fm.fileExists(atPath: folder.appendingPathComponent("cancelled.mp4").path),
               "a cancelled video leaves nothing behind")
    }
}
