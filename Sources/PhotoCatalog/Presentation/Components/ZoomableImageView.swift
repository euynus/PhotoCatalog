// ============================================================
//  Zoomable photo — fit ↔ 1:1 with pan, for Loupe and Compare
// ============================================================
import SwiftUI
import AppKit

/// Zoom state shared across photos: magnification (1 = one image pixel per screen
/// pixel) and the normalized image point shown at the view's center. `nil` means fit.
struct ImageZoom: Equatable {
    var scale: CGFloat
    var center: CGPoint

    static let actualSize = ImageZoom(scale: 1, center: CGPoint(x: 0.5, y: 0.5))
}

/// AppKit scroll view so pinch, inertial panning and bounds clamping behave natively.
struct ZoomableImageView: NSViewRepresentable {
    let image: CGImage?
    /// Full-resolution size in pixels, display orientation. 1:1 is measured against it
    /// even while a smaller preview is on screen.
    let pixelSize: CGSize
    let zoom: ImageZoom?
    let onZoomChange: (ImageZoom?) -> Void

    func makeNSView(context: Context) -> ZoomScrollView {
        let view = ZoomScrollView()
        view.onZoomChange = onZoomChange
        return view
    }

    func updateNSView(_ view: ZoomScrollView, context: Context) {
        view.onZoomChange = onZoomChange
        view.update(image: image, pixelSize: pixelSize, zoom: zoom)
    }
}

final class ZoomScrollView: NSScrollView {
    var onZoomChange: ((ImageZoom?) -> Void)?
    private let imageView = ZoomImageLayerView()
    private var pixelSize = CGSize(width: 1, height: 1)
    private var requestedZoom: ImageZoom?
    private var isApplying = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        contentView = CenteringClipView()
        documentView = imageView
        drawsBackground = false
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        allowsMagnification = true
        usesPredominantAxisScrolling = false
        contentView.postsBoundsChangedNotifications = true
        imageView.onDoubleClick = { [weak self] point in self?.toggleZoom(at: point) }
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged),
                                               name: NSView.boundsDidChangeNotification, object: contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged),
                                               name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Document size in points such that magnification 1 maps one image pixel to one device pixel.
    private var documentSize: CGSize {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return CGSize(width: max(1, pixelSize.width / scale), height: max(1, pixelSize.height / scale))
    }

    private var fitMagnification: CGFloat {
        let doc = documentSize
        let clip = contentView.frame.size
        guard doc.width > 0, doc.height > 0, clip.width > 0, clip.height > 0 else { return 1 }
        return min(clip.width / doc.width, clip.height / doc.height)
    }

    func update(image: CGImage?, pixelSize: CGSize, zoom: ImageZoom?) {
        imageView.image = image
        let sizeChanged = self.pixelSize != pixelSize
        self.pixelSize = pixelSize
        if sizeChanged { imageView.frame = CGRect(origin: .zero, size: documentSize) }
        requestedZoom = zoom
        apply()
    }

    override func layout() {
        super.layout()
        if imageView.frame.size != documentSize { imageView.frame = CGRect(origin: .zero, size: documentSize) }
        apply()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        imageView.frame = CGRect(origin: .zero, size: documentSize)
        apply()
    }

    private func apply() {
        guard bounds.width > 0 else { return }
        let fit = fitMagnification
        minMagnification = fit
        maxMagnification = max(4, fit)
        isApplying = true
        defer { isApplying = false }
        guard let zoom = requestedZoom else {
            if abs(magnification - fit) > 0.001 { magnification = fit }
            return
        }
        let target = max(fit, min(maxMagnification, zoom.scale))
        if abs(magnification - target) > 0.001 { magnification = target }
        if abs(currentCenter.x - zoom.center.x) > 0.002 || abs(currentCenter.y - zoom.center.y) > 0.002 {
            scroll(toNormalizedCenter: zoom.center)
        }
    }

    /// Normalized image point under the viewport center.
    private var currentCenter: CGPoint {
        let visible = contentView.bounds
        let doc = imageView.bounds.size
        guard doc.width > 0, doc.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: min(1, max(0, visible.midX / doc.width)),
                       y: min(1, max(0, visible.midY / doc.height)))
    }

    private func scroll(toNormalizedCenter center: CGPoint) {
        let doc = imageView.bounds.size
        let visible = contentView.bounds.size
        let origin = CGPoint(x: center.x * doc.width - visible.width / 2,
                             y: center.y * doc.height - visible.height / 2)
        contentView.scroll(to: contentView.constrainBoundsRect(CGRect(origin: origin, size: visible)).origin)
        reflectScrolledClipView(contentView)
    }

    private func toggleZoom(at documentPoint: CGPoint) {
        let doc = imageView.bounds.size
        if magnification > fitMagnification * 1.05 {
            requestedZoom = nil
        } else {
            let center = CGPoint(x: documentPoint.x / max(1, doc.width), y: documentPoint.y / max(1, doc.height))
            requestedZoom = ImageZoom(scale: 1, center: center)
        }
        apply()
        onZoomChange?(requestedZoom)
    }

    @objc private func viewportChanged() {
        guard !isApplying else { return }
        let zoom: ImageZoom? = magnification > fitMagnification * 1.01
            ? ImageZoom(scale: magnification, center: currentCenter)
            : nil
        guard zoom != requestedZoom else { return }
        requestedZoom = zoom
        onZoomChange?(zoom)
    }

    override func scrollWheel(with event: NSEvent) {
        // Fit mode has nothing to pan; let the event reach views behind (e.g. the filmstrip).
        if requestedZoom == nil && !event.modifierFlags.contains(.command) && event.phase == [] &&
            event.momentumPhase == [] { nextResponder?.scrollWheel(with: event); return }
        super.scrollWheel(with: event)
    }
}

/// Centers a document smaller than the viewport (NSClipView pins it to the corner).
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView?.frame else { return rect }
        if rect.width > doc.width { rect.origin.x = (doc.width - rect.width) / 2 }
        if rect.height > doc.height { rect.origin.y = (doc.height - rect.height) / 2 }
        return rect
    }
}

/// Draws the photo as layer contents scaled to the document size; drag pans, double-click zooms.
private final class ZoomImageLayerView: NSView {
    var onDoubleClick: ((CGPoint) -> Void)?
    var image: CGImage? {
        didSet { if image !== oldValue { layer?.contents = image } }
    }
    private var dragOrigin: CGPoint?
    private var pushedCursor = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resize
        layer?.minificationFilter = .trilinear
        layer?.magnificationFilter = .linear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?(convert(event.locationInWindow, from: nil))
            return
        }
        dragOrigin = event.locationInWindow
        if (enclosingScrollView?.magnification ?? 1) > (enclosingScrollView?.minMagnification ?? 1) + 0.001 {
            NSCursor.closedHand.push()
            pushedCursor = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin, let clip = enclosingScrollView?.contentView else { return }
        let delta = CGPoint(x: event.locationInWindow.x - origin.x, y: event.locationInWindow.y - origin.y)
        dragOrigin = event.locationInWindow
        let scale = enclosingScrollView?.magnification ?? 1
        var bounds = clip.bounds
        bounds.origin.x -= delta.x / scale
        bounds.origin.y += delta.y / scale   // window y grows upward; the document is flipped
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    override func mouseUp(with event: NSEvent) {
        if pushedCursor { NSCursor.pop() }
        pushedCursor = false
        dragOrigin = nil
    }
}
