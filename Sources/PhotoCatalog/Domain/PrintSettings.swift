// ============================================================
//  Print settings — Lightroom's Print module: paper, layout, sharpening, color
// ============================================================
import CoreGraphics
import Foundation

/// How photos go onto paper: the paper and its orientation, one photo per page or a contact
/// sheet, margins and spacing, captions, print sharpening, color management and resolution.
/// Sizes are in points (1/72 inch).
struct PrintSettings: Codable, Equatable, Sendable {
    enum Paper: String, Codable, CaseIterable, Identifiable, Sendable {
        case a4, a3, a5, letter, legal, tabloid, photo4x6, photo5x7, photo8x10

        var id: Self { self }
        var title: String {
            switch self {
            case .a4: "A4"
            case .a3: "A3"
            case .a5: "A5"
            case .letter: "Letter"
            case .legal: "Legal"
            case .tabloid: "Tabloid"
            case .photo4x6: L("4 × 6 英寸")
            case .photo5x7: L("5 × 7 英寸")
            case .photo8x10: L("8 × 10 英寸")
            }
        }
        /// Portrait size in points.
        var size: CGSize {
            let mm = 72 / 25.4
            switch self {
            case .a4: return CGSize(width: 210 * mm, height: 297 * mm)
            case .a3: return CGSize(width: 297 * mm, height: 420 * mm)
            case .a5: return CGSize(width: 148 * mm, height: 210 * mm)
            case .letter: return CGSize(width: 612, height: 792)
            case .legal: return CGSize(width: 612, height: 1008)
            case .tabloid: return CGSize(width: 792, height: 1224)
            case .photo4x6: return CGSize(width: 288, height: 432)
            case .photo5x7: return CGSize(width: 360, height: 504)
            case .photo8x10: return CGSize(width: 576, height: 720)
            }
        }
    }

    enum Orientation: String, Codable, CaseIterable, Identifiable, Sendable {
        case portrait, landscape

        var id: Self { self }
        var title: String {
            switch self {
            case .portrait: L("纵向")
            case .landscape: L("横向")
            }
        }
    }

    enum Layout: String, Codable, CaseIterable, Identifiable, Sendable {
        case single, contactSheet

        var id: Self { self }
        var title: String {
            switch self {
            case .single: L("每页一张")
            case .contactSheet: L("联系表")
            }
        }
    }

    enum Caption: String, Codable, CaseIterable, Identifiable, Sendable {
        case none, filename, title

        var id: Self { self }
        var title: String {
            switch self {
            case .none: L("无")
            case .filename: L("文件名")
            case .title: L("标题")
            }
        }
    }

    var paper = Paper.a4
    var orientation = Orientation.portrait
    /// Turn a photo a quarter when that fills its place better, as Lightroom's Rotate to Fit.
    var rotateToFit = true
    var layout = Layout.single
    /// One photo per page: fill the printable area, cropping the photo, instead of fitting it whole.
    var fill = false
    var rows = 4
    var columns = 3
    var margin: Double = 36
    /// The gap between a contact sheet's cells.
    var spacing: Double = 12
    var caption = Caption.none
    /// Print sharpening for the paper (matte or glossy), at the print's resolution.
    var sharpenFor = ExportSettings.SharpenFor.none
    var sharpenAmount = ExportSettings.SharpenAmount.standard
    /// The printer profile to convert to (nil: the printer manages colors), and how.
    var profile: String?
    var intent = SoftProof.Intent.perceptual
    /// Pixels per inch the photos are rendered at.
    var resolution: Double = 300

    /// Room below a photo for its caption.
    static let captionHeight: Double = 14

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PrintSettings()
        paper = try c.decodeIfPresent(Paper.self, forKey: .paper) ?? d.paper
        orientation = try c.decodeIfPresent(Orientation.self, forKey: .orientation) ?? d.orientation
        rotateToFit = try c.decodeIfPresent(Bool.self, forKey: .rotateToFit) ?? d.rotateToFit
        layout = try c.decodeIfPresent(Layout.self, forKey: .layout) ?? d.layout
        fill = try c.decodeIfPresent(Bool.self, forKey: .fill) ?? d.fill
        rows = try c.decodeIfPresent(Int.self, forKey: .rows) ?? d.rows
        columns = try c.decodeIfPresent(Int.self, forKey: .columns) ?? d.columns
        margin = try c.decodeIfPresent(Double.self, forKey: .margin) ?? d.margin
        spacing = try c.decodeIfPresent(Double.self, forKey: .spacing) ?? d.spacing
        caption = try c.decodeIfPresent(Caption.self, forKey: .caption) ?? d.caption
        sharpenFor = try c.decodeIfPresent(ExportSettings.SharpenFor.self, forKey: .sharpenFor) ?? d.sharpenFor
        sharpenAmount = try c.decodeIfPresent(ExportSettings.SharpenAmount.self, forKey: .sharpenAmount) ?? d.sharpenAmount
        profile = try c.decodeIfPresent(String.self, forKey: .profile)
        intent = try c.decodeIfPresent(SoftProof.Intent.self, forKey: .intent) ?? d.intent
        resolution = try c.decodeIfPresent(Double.self, forKey: .resolution) ?? d.resolution
    }

    var photosPerPage: Int { layout == .single ? 1 : max(1, rows) * max(1, columns) }

    func pageCount(photos: Int) -> Int { photos <= 0 ? 0 : (photos + photosPerPage - 1) / photosPerPage }

    /// The photos (indexes into the whole list) on page `index`.
    func photos(onPage index: Int, of total: Int) -> Range<Int> {
        let start = min(total, index * photosPerPage)
        return start..<min(total, start + photosPerPage)
    }

    /// Every page's size: the paper, turned for landscape. (A print job has one page size, so
    /// photos turn to fit their place instead of pages turning.)
    var pageSize: CGSize {
        let upright = paper.size
        return orientation == .portrait ? upright : CGSize(width: upright.height, height: upright.width)
    }

    /// Whether a photo of `aspect` (width over height) turns a quarter in `rect`: with Rotate to
    /// Fit, when its shape and the place's disagree.
    func turns(_ aspect: Double, in rect: CGRect) -> Bool {
        rotateToFit && aspect != 1 && rect.width != rect.height && (aspect > 1) != (rect.width > rect.height)
    }

    /// A photo's place on the page and its caption's, in points from the page's top-left.
    struct Cell: Equatable {
        var photo: CGRect
        var caption: CGRect?
    }

    /// The cells of a page of `size`, in reading order: the printable area for one photo, or a
    /// grid with `spacing` between cells, each leaving room below for a caption when there is one.
    func cells(pageSize size: CGSize) -> [Cell] {
        let inset = max(0, min(margin, Double(min(size.width, size.height)) / 2 - 10))
        let area = CGRect(x: inset, y: inset, width: size.width - 2 * inset, height: size.height - 2 * inset)
        let captionHeight = caption == .none ? 0 : Self.captionHeight
        func cell(_ rect: CGRect) -> Cell {
            guard captionHeight > 0 else { return Cell(photo: rect, caption: nil) }
            return Cell(photo: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(1, rect.height - captionHeight)),
                        caption: CGRect(x: rect.minX, y: rect.maxY - captionHeight, width: rect.width, height: captionHeight))
        }
        guard layout == .contactSheet else { return [cell(area)] }
        let rows = max(1, self.rows), columns = max(1, self.columns)
        let gap = max(0, spacing)
        let width = max(1, (area.width - gap * Double(columns - 1)) / Double(columns))
        let height = max(1, (area.height - gap * Double(rows - 1)) / Double(rows))
        return (0..<rows).flatMap { row in
            (0..<columns).map { column in
                cell(CGRect(x: area.minX + Double(column) * (width + gap), y: area.minY + Double(row) * (height + gap),
                            width: width, height: height))
            }
        }
    }

    /// Where a photo of `size` goes in `rect`: whole and centered, or (`fill`) covering it, to be
    /// clipped to it.
    static func placement(of size: CGSize, in rect: CGRect, fill: Bool) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = fill ? max(rect.width / size.width, rect.height / size.height)
            : min(rect.width / size.width, rect.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }

    /// The pixels a photo drawn at `placement` (points) needs at this resolution.
    func pixelSize(for placement: CGRect) -> CGSize {
        CGSize(width: max(1, (placement.width / 72 * resolution).rounded()),
               height: max(1, (placement.height / 72 * resolution).rounded()))
    }
}
