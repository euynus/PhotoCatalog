// ============================================================
//  Thumb — async remote image with deterministic gradient fallback
//  Port of the `Thumb` / `gradientFor` helpers in components.jsx.
// ============================================================
import SwiftUI
import AppKit

/// HSL → Color (SwiftUI's Color(hue:…) is HSB, so we convert manually).
private func hsl(_ h: Double, _ s: Double, _ l: Double) -> Color {
    let c = (1 - abs(2 * l - 1)) * s
    let hp = h / 60
    let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
    var r = 0.0, g = 0.0, b = 0.0
    switch hp {
    case 0..<1: (r, g, b) = (c, x, 0)
    case 1..<2: (r, g, b) = (x, c, 0)
    case 2..<3: (r, g, b) = (0, c, x)
    case 3..<4: (r, g, b) = (0, x, c)
    case 4..<5: (r, g, b) = (x, 0, c)
    default: (r, g, b) = (c, 0, x)
    }
    let m = l - c / 2
    return Color(.sRGB, red: r + m, green: g + m, blue: b + m)
}

/// Deterministic placeholder gradient behind every photo.
func gradientFor(_ pid: Int) -> LinearGradient {
    let h0 = Double((pid * 47) % 360)
    let h1 = Double((pid * 47 + 40) % 360)
    return LinearGradient(
        colors: [hsl(h0, 0.32, 0.26), hsl(h1, 0.38, 0.16)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Shared in-memory image cache so grid scrolling doesn't refetch.
final class ThumbLoader: ObservableObject {
    @Published var image: NSImage?
    @Published var failed = false
    private static let cache = NSCache<NSString, NSImage>()
    private var task: URLSessionDataTask?
    private var loadedURL: String?

    func load(_ urlString: String) {
        // already showing / fetching this exact source
        if urlString == loadedURL { return }
        loadedURL = urlString
        task?.cancel()
        task = nil
        failed = false

        if let cached = Self.cache.object(forKey: urlString as NSString) {
            image = cached
            return
        }
        image = nil
        guard let url = URL(string: urlString) else { return }
        task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self else { return }
            if let data, let img = NSImage(data: data) {
                Self.cache.setObject(img, forKey: urlString as NSString)
                DispatchQueue.main.async {
                    guard self.loadedURL == urlString else { return }   // source changed mid-flight
                    withAnimation(.easeOut(duration: 0.35)) { self.image = img }
                }
            } else {
                DispatchQueue.main.async {
                    guard self.loadedURL == urlString else { return }
                    self.failed = true
                }
            }
        }
        task?.resume()
    }
}

/// A photo tile that fills the frame it is given (caller controls sizing).
struct Thumb: View {
    let asset: Asset
    var urlString: String?
    var radius: CGFloat = 4
    var dim: Bool = false

    @StateObject private var loader = ThumbLoader()

    private var source: String { urlString ?? asset.thumb }

    var body: some View {
        ZStack {
            gradientFor(asset.pid)
            if let img = loader.image {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
            } else if loader.failed {
                Icon("photos", size: 22).foregroundStyle(.white.opacity(0.35))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .opacity(dim ? 0.4 : 1)
        .onAppear { loader.load(source) }
        .onChange(of: source) { _, newSource in loader.load(newSource) }
    }
}
