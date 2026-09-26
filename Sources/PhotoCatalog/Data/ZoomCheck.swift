import AppKit

/// The zoom view reports only what the user does: resizing it (window, inspector, stage)
/// must never produce a zoom, or the loupe feeds layout back into its own state.
enum ZoomCheck {
    static func run() {
        MainActor.assumeIsolated { check() }
        print("--- zoom view assertions passed ---")
    }

    @MainActor
    private static func check() {
        let view = ZoomScrollView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        var reported: [ImageZoom?] = []
        view.onZoomChange = { reported.append($0) }
        view.update(image: nil, pixelSize: CGSize(width: 6000, height: 4000), zoom: nil)
        view.layoutSubtreeIfNeeded()
        for size in [NSSize(width: 900, height: 600), NSSize(width: 1400, height: 900), NSSize(width: 1000, height: 700)] {
            view.setFrameSize(size)
            view.layoutSubtreeIfNeeded()
        }
        assert(reported.isEmpty, "resizing a fitted photo never reports a zoom")
        assert(view.scrollerStyle == .overlay, "scrollers never take room from the fitted photo")

        let zoom = ImageZoom(scale: 1, center: CGPoint(x: 0.3, y: 0.6))
        view.update(image: nil, pixelSize: CGSize(width: 6000, height: 4000), zoom: zoom)
        view.layoutSubtreeIfNeeded()
        for size in [NSSize(width: 800, height: 500), NSSize(width: 1300, height: 850)] {
            view.setFrameSize(size)
            view.layoutSubtreeIfNeeded()
        }
        assert(reported.isEmpty, "resizing a zoomed photo keeps the zoom it was given")
        view.update(image: nil, pixelSize: CGSize(width: 6000, height: 4000), zoom: nil)
        view.setFrameSize(NSSize(width: 700, height: 450))
        view.layoutSubtreeIfNeeded()
        assert(reported.isEmpty, "returning to fit reports nothing either")
    }
}
