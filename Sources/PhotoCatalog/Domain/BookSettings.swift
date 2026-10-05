// ============================================================
//  Photo book — its pages, and which photos go where (Lightroom's Book module)
// ============================================================
import CoreGraphics
import Foundation

struct BookSettings: Codable, Equatable, Sendable {
    enum Size: String, Codable, CaseIterable, Sendable {
        case square, landscape, portrait, a4Landscape

        var title: String {
            switch self {
            case .square: L("20 × 20 厘米（方形）")
            case .landscape: L("25 × 20 厘米（横向）")
            case .portrait: L("20 × 25 厘米（纵向）")
            case .a4Landscape: L("A4 横向")
            }
        }

        /// The page in points.
        var points: CGSize {
            let cm = 72 / 2.54
            switch self {
            case .square: return CGSize(width: 20 * cm, height: 20 * cm)
            case .landscape: return CGSize(width: 25 * cm, height: 20 * cm)
            case .portrait: return CGSize(width: 20 * cm, height: 25 * cm)
            case .a4Landscape: return CGSize(width: 29.7 * cm, height: 21 * cm)
            }
        }
    }

    enum Layout: String, Codable, CaseIterable, Sendable {
        /// A photo of the page's shape alone, two of the other shape side by side or stacked.
        case auto, one, two, four

        var title: String {
            switch self {
            case .auto: L("自动")
            case .one: L("每页一张")
            case .two: L("每页两张")
            case .four: L("每页四张")
            }
        }
    }

    enum Margin: String, Codable, CaseIterable, Sendable {
        /// None: a photo alone on its page fills it to the edges.
        case none, small, large

        var title: String {
            switch self {
            case .none: L("无（满版）")
            case .small: L("窄")
            case .large: L("宽")
            }
        }

        /// Of the page's short side.
        var share: Double {
            switch self {
            case .none: 0
            case .small: 0.06
            case .large: 0.11
            }
        }
    }

    enum Caption: String, Codable, CaseIterable, Sendable, PhotoCaption {
        case none, title, caption, filename

        var title: String {
            switch self {
            case .none: L("无")
            case .title: L("标题")
            case .caption: L("说明")
            case .filename: L("文件名")
            }
        }
    }

    enum Background: String, Codable, CaseIterable, Sendable {
        case white, black

        var title: String {
            switch self {
            case .white: L("白色")
            case .black: L("黑色")
            }
        }
    }

    var size: Size = .square
    var layout: Layout = .auto
    var margin: Margin = .small
    var caption: Caption = .none
    var background: Background = .white
    /// A cover page: the first photo, with the title and subtitle.
    var cover = true
    var title = ""
    var subtitle = ""
    var pageNumbers = true

    init() {}
}

extension BookSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        size = try c.decodeIfPresent(Size.self, forKey: .size) ?? .square
        layout = try c.decodeIfPresent(Layout.self, forKey: .layout) ?? .auto
        margin = try c.decodeIfPresent(Margin.self, forKey: .margin) ?? .small
        caption = try c.decodeIfPresent(Caption.self, forKey: .caption) ?? .none
        background = try c.decodeIfPresent(Background.self, forKey: .background) ?? .white
        cover = try c.decodeIfPresent(Bool.self, forKey: .cover) ?? true
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        pageNumbers = try c.decodeIfPresent(Bool.self, forKey: .pageNumbers) ?? true
    }
}

/// One page of a book, in points from its top-left corner.
struct BookPage: Equatable, Sendable {
    struct Cell: Equatable, Sendable {
        /// Which photo (an index into the book's photos).
        let photo: Int
        /// Where the photo goes: fitted inside, or filling it when `fill`.
        let frame: CGRect
        let fill: Bool
        /// Where its caption goes, when there is one.
        let caption: CGRect?
    }

    let isCover: Bool
    let cells: [Cell]
    /// The title's place on the cover.
    let title: CGRect?
    /// The printed page number and where it goes.
    let number: Int?
    let numberFrame: CGRect?
}

enum BookLayout {
    /// The photos (by width over height) grouped onto pages as `layout` asks. Auto puts a
    /// photo of the page's shape alone, and two photos of the other shape that come together on
    /// one page: portraits side by side on a wide or square page, landscapes stacked on a tall one.
    static func groups(_ aspects: [Double], layout: BookSettings.Layout, page: CGSize) -> [[Int]] {
        let count = aspects.count
        switch layout {
        case .one: return (0..<count).map { [$0] }
        case .two: return stride(from: 0, to: count, by: 2).map { Array($0..<min($0 + 2, count)) }
        case .four: return stride(from: 0, to: count, by: 4).map { Array($0..<min($0 + 4, count)) }
        case .auto:
            let wide = page.width >= page.height
            var groups: [[Int]] = []
            var index = 0
            while index < count {
                let pairs = index + 1 < count && (wide ? aspects[index] < 1 && aspects[index + 1] < 1
                                                        : aspects[index] >= 1 && aspects[index + 1] >= 1)
                groups.append(pairs ? [index, index + 1] : [index])
                index += pairs ? 2 : 1
            }
            return groups
        }
    }

    static func pages(_ aspects: [Double], settings: BookSettings) -> [BookPage] {
        guard !aspects.isEmpty else { return [] }
        let page = settings.size.points
        let short = min(page.width, page.height)
        let inset = short * settings.margin.share
        let gutter = settings.margin == .none ? short * 0.015 : max(inset * 0.5, short * 0.02)
        let captionHeight = settings.caption == .none ? 0 : short * 0.05
        let numberHeight = settings.pageNumbers && settings.margin != .none ? inset * 0.6 : 0
        let area = CGRect(origin: .zero, size: page).insetBy(dx: inset, dy: inset)
        var pages: [BookPage] = []
        if settings.cover {
            // the first photo over most of the page, the title in a band beneath
            let titleHeight = page.height * 0.2
            let photo = CGRect(x: area.minX, y: area.minY, width: area.width, height: area.height - titleHeight)
            pages.append(BookPage(isCover: true, cells: [BookPage.Cell(photo: 0, frame: photo, fill: settings.margin == .none, caption: nil)],
                                  title: CGRect(x: area.minX, y: photo.maxY, width: area.width, height: titleHeight),
                                  number: nil, numberFrame: nil))
        }
        for (number, group) in groups(aspects, layout: settings.layout, page: page).enumerated() {
            let places = settings.layout == .four && group.count > 1
                ? grid(area, count: 4, gutter: gutter).prefix(group.count).map { $0 }
                : split(area, count: group.count, gutter: gutter, wide: page.width >= page.height)
            let bleed = group.count == 1 && settings.margin == .none && captionHeight == 0
            let cells = zip(group, places).map { photo, place -> BookPage.Cell in
                guard captionHeight > 0 else { return BookPage.Cell(photo: photo, frame: bleed ? CGRect(origin: .zero, size: page) : place,
                                                                    fill: bleed, caption: nil) }
                let frame = CGRect(x: place.minX, y: place.minY, width: place.width, height: place.height - captionHeight)
                return BookPage.Cell(photo: photo, frame: frame, fill: false,
                                     caption: CGRect(x: place.minX, y: frame.maxY, width: place.width, height: captionHeight))
            }
            pages.append(BookPage(isCover: false, cells: cells, title: nil,
                                  number: settings.pageNumbers ? number + 1 : nil,
                                  numberFrame: numberHeight > 0
                                      ? CGRect(x: 0, y: page.height - inset / 2 - numberHeight / 2, width: page.width, height: numberHeight) : nil))
        }
        return pages
    }

    /// `area` split into `count` places: side by side on a wide page, stacked on a tall one.
    private static func split(_ area: CGRect, count: Int, gutter: Double, wide: Bool) -> [CGRect] {
        guard count > 1 else { return [area] }
        let total = (wide ? area.width : area.height) - gutter * Double(count - 1)
        let each = total / Double(count)
        return (0..<count).map { index in
            let offset = Double(index) * (each + gutter)
            return wide ? CGRect(x: area.minX + offset, y: area.minY, width: each, height: area.height)
                : CGRect(x: area.minX, y: area.minY + offset, width: area.width, height: each)
        }
    }

    /// `area` as a 2 × 2 grid, left to right, top to bottom.
    private static func grid(_ area: CGRect, count: Int, gutter: Double) -> [CGRect] {
        let width = (area.width - gutter) / 2, height = (area.height - gutter) / 2
        return (0..<count).map { index in
            CGRect(x: area.minX + Double(index % 2) * (width + gutter), y: area.minY + Double(index / 2) * (height + gutter),
                   width: width, height: height)
        }
    }

    /// Where a photo of `aspect` goes in `frame`: fitted and centered, or covering it.
    static func placement(aspect: Double, in frame: CGRect, fill: Bool) -> CGRect {
        guard aspect > 0, frame.width > 0, frame.height > 0 else { return frame }
        let frameAspect = frame.width / frame.height
        let wider = aspect > frameAspect
        let size = (wider != fill)
            ? CGSize(width: frame.width, height: frame.width / aspect)
            : CGSize(width: frame.height * aspect, height: frame.height)
        return CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
    }
}
