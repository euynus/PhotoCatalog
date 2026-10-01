// ============================================================
//  Web gallery — a folder of photos with a page to show them (Lightroom's Web module)
// ============================================================
import Foundation

struct WebGallerySettings: Codable, Equatable, Sendable {
    enum Theme: String, Codable, CaseIterable, Sendable {
        case dark, light

        var title: String {
            switch self {
            case .dark: L("深色")
            case .light: L("浅色")
            }
        }
    }

    enum Caption: String, Codable, CaseIterable, Sendable {
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

    var title = ""
    var subtitle = ""
    var theme: Theme = .dark
    /// The long edge of each photo as it opens, in pixels (smaller photos aren't enlarged).
    var largeSize = 2048
    /// The short edge of each grid thumbnail, in pixels: enough for the square tiles at 2×.
    var thumbnailSize = 480
    var caption: Caption = .title
    /// Camera, lens and exposure under each opened photo.
    var showDetails = true

    static let largeSizes = [1600, 2048, 3000]
    static let thumbnailSizes = [320, 480, 640]

    init() {}
}

extension WebGallerySettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = WebGallerySettings()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        theme = try c.decodeIfPresent(Theme.self, forKey: .theme) ?? .dark
        largeSize = try c.decodeIfPresent(Int.self, forKey: .largeSize) ?? defaults.largeSize
        thumbnailSize = try c.decodeIfPresent(Int.self, forKey: .thumbnailSize) ?? defaults.thumbnailSize
        caption = try c.decodeIfPresent(Caption.self, forKey: .caption) ?? .title
        showDetails = try c.decodeIfPresent(Bool.self, forKey: .showDetails) ?? true
    }
}

/// The gallery's page: a grid of thumbnails, each opening its photo in a viewer with arrows
/// (keys and swipes too). The page is one file with no outside code, and without scripts each
/// thumbnail still links to its photo.
enum WebGalleryPage {
    struct Photo: Equatable, Sendable {
        /// Paths from the page: the photo as it opens, and its thumbnail.
        let large: String
        let thumbnail: String
        let width: Int
        let height: Int
        let thumbnailWidth: Int
        let thumbnailHeight: Int
        let caption: String
        let details: String
    }

    /// `name` safe as a file name on any web server: letters, digits, dashes and underscores,
    /// numbered so photos never share one.
    static func fileName(_ name: String, index: Int) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let cleaned = String(name.map { allowed.contains($0) ? $0 : "-" })
            .split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return String(format: "%03d", index + 1) + (cleaned.isEmpty ? "" : "-" + cleaned) + ".jpg"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// The photos as the viewer's data: JSON with every "<" written as an escape, so no caption
    /// can end, or confuse, the script it sits in.
    static func data(_ photos: [Photo]) -> String {
        let objects = photos.map { photo -> [String: Any] in
            ["src": photo.large, "w": photo.width, "h": photo.height, "caption": photo.caption, "details": photo.details]
        }
        let json = (try? JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return json.replacingOccurrences(of: "<", with: "\\u003c")
    }

    static func html(title: String, subtitle: String, theme: WebGallerySettings.Theme, photos: [Photo]) -> String {
        let tiles = photos.enumerated().map { index, photo in
            """
              <a class="tile" href="\(escape(photo.large))" data-index="\(index)"><img src="\(escape(photo.thumbnail))" \
            width="\(photo.thumbnailWidth)" height="\(photo.thumbnailHeight)" alt="\(escape(photo.caption))" loading="lazy">\
            \(photo.caption.isEmpty ? "" : "<span class=\"caption\">\(escape(photo.caption))</span>")</a>
            """
        }.joined(separator: "\n")
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>
        :root { --bg: #111; --fg: #eee; --muted: #999; --tile: #222; }
        body.light { --bg: #f6f6f4; --fg: #1d1d1f; --muted: #6e6e73; --tile: #e8e8e6; }
        * { box-sizing: border-box; }
        body { margin: 0; background: var(--bg); color: var(--fg); font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Helvetica Neue", "PingFang SC", sans-serif; }
        header { padding: 40px 24px 16px; max-width: 1400px; margin: 0 auto; }
        h1 { margin: 0; font-size: 28px; font-weight: 600; }
        header p { margin: 6px 0 0; color: var(--muted); }
        main { display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 8px; padding: 16px 24px 48px; max-width: 1400px; margin: 0 auto; }
        .tile { position: relative; display: block; aspect-ratio: 1; overflow: hidden; background: var(--tile); }
        .tile img { width: 100%; height: 100%; object-fit: cover; display: block; transition: transform .3s; }
        .tile:hover img { transform: scale(1.03); }
        .tile .caption { position: absolute; left: 0; right: 0; bottom: 0; padding: 18px 10px 8px; font-size: 13px; color: #fff; background: linear-gradient(transparent, rgba(0,0,0,.6)); opacity: 0; transition: opacity .2s; }
        .tile:hover .caption, .tile:focus .caption { opacity: 1; }
        #viewer { position: fixed; inset: 0; background: rgba(0,0,0,.94); display: flex; align-items: center; justify-content: center; z-index: 10; }
        #viewer[hidden] { display: none; }
        #viewer figure { margin: 0; max-width: 92vw; max-height: 92vh; display: flex; flex-direction: column; align-items: center; }
        #viewer img { max-width: 92vw; max-height: 84vh; object-fit: contain; }
        #viewer figcaption { color: #ddd; text-align: center; padding-top: 10px; font-size: 14px; }
        #viewer figcaption .details { display: block; color: #999; font-size: 12px; }
        #viewer button { position: absolute; background: none; border: 0; color: #fff; font-size: 40px; cursor: pointer; padding: 16px; opacity: .7; }
        #viewer button:hover { opacity: 1; }
        #viewer .close { top: 8px; right: 12px; font-size: 32px; }
        #viewer .prev { left: 8px; }
        #viewer .next { right: 8px; }
        </style>
        </head>
        <body class="\(theme.rawValue)">
        <header>
          <h1>\(escape(title))</h1>\(subtitle.isEmpty ? "" : "\n  <p>\(escape(subtitle))</p>")
        </header>
        <main>
        \(tiles)
        </main>
        <div id="viewer" hidden>
          <button class="close" aria-label="Close">&#x2715;</button>
          <button class="prev" aria-label="Previous">&#x2039;</button>
          <figure><img alt=""><figcaption><span class="caption"></span><span class="details"></span></figcaption></figure>
          <button class="next" aria-label="Next">&#x203A;</button>
        </div>
        <script>
        const photos = \(data(photos));
        const viewer = document.getElementById("viewer"), image = viewer.querySelector("img");
        let current = 0;
        function show(index) {
          current = (index + photos.length) % photos.length;
          const photo = photos[current];
          image.src = photo.src;
          image.alt = photo.caption;
          viewer.querySelector(".caption").textContent = photo.caption;
          viewer.querySelector(".details").textContent = photo.details;
          viewer.hidden = false;
          for (const next of [current + 1, current - 1]) new Image().src = photos[(next + photos.length) % photos.length].src;
        }
        function close() { viewer.hidden = true; image.removeAttribute("src"); }
        document.querySelectorAll(".tile").forEach(tile => tile.addEventListener("click", event => {
          event.preventDefault();
          show(Number(tile.dataset.index));
        }));
        viewer.querySelector(".close").onclick = close;
        viewer.querySelector(".prev").onclick = event => { event.stopPropagation(); show(current - 1); };
        viewer.querySelector(".next").onclick = event => { event.stopPropagation(); show(current + 1); };
        viewer.addEventListener("click", event => { if (event.target === viewer) close(); });
        document.addEventListener("keydown", event => {
          if (viewer.hidden) return;
          if (event.key === "Escape") close();
          if (event.key === "ArrowLeft") show(current - 1);
          if (event.key === "ArrowRight") show(current + 1);
        });
        let touchX = null;
        viewer.addEventListener("touchstart", event => { touchX = event.touches[0].clientX; }, { passive: true });
        viewer.addEventListener("touchend", event => {
          if (touchX === null) return;
          const dx = event.changedTouches[0].clientX - touchX;
          if (Math.abs(dx) > 50) show(current + (dx < 0 ? 1 : -1));
          touchX = null;
        });
        </script>
        </body>
        </html>

        """
    }
}
