// ============================================================
//  Slideshow — its settings, and what's on screen at each moment (Lightroom's Slideshow)
// ============================================================
import CoreGraphics
import Foundation

struct SlideshowSettings: Codable, Equatable, Sendable {
    enum Caption: String, Codable, CaseIterable, Sendable {
        case none, title, filename, caption

        var title: String {
            switch self {
            case .none: L("无")
            case .title: L("标题")
            case .filename: L("文件名")
            case .caption: L("说明")
            }
        }
    }

    enum Backdrop: String, Codable, CaseIterable, Sendable {
        case black, gray, white

        var title: String {
            switch self {
            case .black: L("黑色")
            case .gray: L("灰色")
            case .white: L("白色")
            }
        }

        /// The backdrop's gray, 0…1.
        var gray: Double {
            switch self {
            case .black: 0
            case .gray: 0.25
            case .white: 1
            }
        }

        /// A caption's gray on it.
        var captionGray: Double { self == .white ? 0.15 : 0.92 }
    }

    enum VideoSize: String, Codable, CaseIterable, Sendable {
        case hd720, hd1080, uhd4K

        var title: String {
            switch self {
            case .hd720: "720p"
            case .hd1080: "1080p"
            case .uhd4K: "4K"
            }
        }

        var pixels: CGSize {
            switch self {
            case .hd720: CGSize(width: 1280, height: 720)
            case .hd1080: CGSize(width: 1920, height: 1080)
            case .uhd4K: CGSize(width: 3840, height: 2160)
            }
        }
    }

    /// How long each photo shows, fade included, in seconds.
    var slideSeconds = 4.0
    /// How long one photo takes to fade into the next (0: a cut).
    var fadeSeconds = 1.0
    var shuffle = false
    /// Plays again from the start after the last photo (the player; a video plays once).
    var repeats = true
    var caption: Caption = .none
    /// A slow zoom and drift across each photo.
    var panAndZoom = true
    var backdrop: Backdrop = .black
    /// Music to play with it ("" for none).
    var musicPath = ""
    /// Each photo shows long enough for the slideshow to last as long as the music.
    var fitToMusic = false
    var videoSize: VideoSize = .hd1080

    static let slideRange = 1.0...20.0
    static let fadeRange = 0.0...3.0

    init() {}

    /// The order the photos play in: as listed, or shuffled the same way every time for the
    /// same photos (so the video matches what was watched).
    func order(_ count: Int, seed: UInt64) -> [Int] {
        guard shuffle, count > 1 else { return Array(0..<count) }
        var generator = SeededGenerator(seed: seed)
        return Array(0..<count).shuffled(using: &generator)
    }

    /// Each photo's time on screen when fitting `count` photos to music `seconds` long.
    func slideSeconds(fitting count: Int, toMusic seconds: Double?) -> Double {
        guard fitToMusic, let seconds, seconds > 0, count > 0 else { return slideSeconds }
        return max(Self.slideRange.lowerBound, seconds / Double(count))
    }
}

extension SlideshowSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SlideshowSettings()
        slideSeconds = try c.decodeIfPresent(Double.self, forKey: .slideSeconds) ?? defaults.slideSeconds
        fadeSeconds = try c.decodeIfPresent(Double.self, forKey: .fadeSeconds) ?? defaults.fadeSeconds
        shuffle = try c.decodeIfPresent(Bool.self, forKey: .shuffle) ?? false
        repeats = try c.decodeIfPresent(Bool.self, forKey: .repeats) ?? true
        caption = try c.decodeIfPresent(Caption.self, forKey: .caption) ?? .none
        panAndZoom = try c.decodeIfPresent(Bool.self, forKey: .panAndZoom) ?? true
        backdrop = try c.decodeIfPresent(Backdrop.self, forKey: .backdrop) ?? .black
        musicPath = try c.decodeIfPresent(String.self, forKey: .musicPath) ?? ""
        fitToMusic = try c.decodeIfPresent(Bool.self, forKey: .fitToMusic) ?? false
        videoSize = try c.decodeIfPresent(VideoSize.self, forKey: .videoSize) ?? .hd1080
    }
}

/// SplitMix64: the same shuffle for the same seed.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// What a slideshow shows at a moment: each photo has `slide` seconds, the last `fade` of
/// them fading into the next photo; a repeating show fades its last photo into its first.
struct SlideshowTimeline: Equatable, Sendable {
    let count: Int
    let slide: Double
    let fade: Double
    let repeats: Bool

    init(count: Int, slide: Double, fade: Double, repeats: Bool) {
        self.count = count
        self.slide = max(0.1, slide)
        self.fade = min(max(0, fade), self.slide / 2)
        self.repeats = repeats
    }

    /// How long one pass lasts.
    var duration: Double { Double(count) * slide }

    struct Frame: Equatable {
        /// The photo showing (a position in the play order), and how far through its time it is.
        let index: Int
        let progress: Double
        /// The photo fading in over it, and how far (0…1); nil outside a fade.
        let next: Int?
        let blend: Double
        /// A show that doesn't repeat has ended.
        let finished: Bool

        /// How visible each photo's caption is: one gives way to the other, the first fading
        /// out over the fade's first half and the next in over its second, so two captions in
        /// the same place never mix.
        var captionAlpha: Double { max(0, 1 - 2 * blend) }
        var nextCaptionAlpha: Double { max(0, 2 * blend - 1) }
    }

    func frame(at time: Double) -> Frame {
        guard count > 0 else { return Frame(index: 0, progress: 0, next: nil, blend: 0, finished: true) }
        var t = max(0, time)
        if repeats { t = t.truncatingRemainder(dividingBy: duration) } else if t >= duration {
            return Frame(index: count - 1, progress: 1, next: nil, blend: 0, finished: true)
        }
        let index = min(count - 1, Int(t / slide))
        let within = t - Double(index) * slide
        let fadeStart = slide - fade
        let hasNext = index + 1 < count || repeats && count > 1
        guard fade > 0, within > fadeStart, hasNext else {
            return Frame(index: index, progress: within / slide, next: nil, blend: 0, finished: false)
        }
        return Frame(index: index, progress: within / slide, next: (index + 1) % count,
                     blend: (within - fadeStart) / fade, finished: false)
    }

    /// The pan and zoom of photo `index` (a position in the play order) at `progress` through
    /// its time on screen, and on into the next photo's fade: a scale of at least 1 and a
    /// shift of the photo's center as fractions of the frame. Each photo moves its own way,
    /// zooming in or out in turn; it's never smaller than 5% past fitting and never drifts more
    /// than half that, so a photo that fills the frame never shows an edge.
    static func panAndZoom(index: Int, progress: Double) -> (scale: Double, offset: CGVector) {
        var generator = SeededGenerator(seed: UInt64(index) &* 2_654_435_761 &+ 97)
        let angle = Double.random(in: 0..<(2 * .pi), using: &generator)
        let drift = 0.02
        let zoomIn = index % 2 == 0
        let t = min(1, max(0, progress))
        let scale = zoomIn ? 1.05 + 0.08 * t : 1.13 - 0.08 * t
        let along = (t - 0.5) * 2 * drift
        return (scale, CGVector(dx: cos(angle) * along, dy: sin(angle) * along))
    }
}
