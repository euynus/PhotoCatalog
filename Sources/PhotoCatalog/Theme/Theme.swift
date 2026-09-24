// ============================================================
//  Workspace chrome (light or dark) around a neutral, dark photographic canvas.
// ============================================================
import SwiftUI
import AppKit

extension Color {
    /// Hex initializer supporting "#rrggbb" and "#rrggbbaa".
    init(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r, g, b, a: Double
        if s.count == 8 {
            r = Double((v >> 24) & 0xFF) / 255
            g = Double((v >> 16) & 0xFF) / 255
            b = Double((v >> 8) & 0xFF) / 255
            a = Double(v & 0xFF) / 255
        } else {
            r = Double((v >> 16) & 0xFF) / 255
            g = Double((v >> 8) & 0xFF) / 255
            b = Double(v & 0xFF) / 255
            a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// White at a given opacity — mirrors the many `rgba(255,255,255,a)` tokens.
    static func white(_ opacity: Double) -> Color { .white.opacity(opacity) }
    /// macOS label-on-dark tint `rgba(235,235,245,a)`.
    static func label(_ opacity: Double) -> Color {
        Color(.sRGB, red: 235.0 / 255, green: 235.0 / 255, blue: 245.0 / 255, opacity: opacity)
    }
}

extension NSColor {
    /// sRGB color from "#rrggbb".
    convenience init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex.hasPrefix("#") ? String(hex.dropFirst()) : hex).scanHexInt64(&v)
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

/// Shared workspace and photographic-canvas colors. Workspace tokens follow the
/// effective appearance (light / dark); the photo canvas is always dark.
enum Theme {
    /// A token that resolves per appearance — SwiftUI resolves it against the
    /// view's color scheme, so canvas views pinned to `.dark` get the dark value.
    static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    static func dynamic(_ light: String, _ dark: String) -> Color {
        dynamic(NSColor(hex: light), NSColor(hex: dark))
    }

    // Accent: `accent` for text, icons, rings; `accentFill` behind white labels.
    // Dark mode needs them apart — no single blue is readable on a dark panel
    // and dark enough to carry white text.
    static let accent = dynamic("#2764D6", "#5A98F8")
    static let accentFill = dynamic("#2764D6", "#2F6FE0")
    static let accentFillHover = dynamic("#1F5BC9", "#2A63CF")
    static let accentSoft = accent.opacity(0.10)
    static let onAccent = Color.white

    // Surfaces
    static let bgDesktop = dynamic("#E8E9EB", "#1B1C1E")
    static let bgContent = dynamic("#F4F5F6", "#222326")
    static let bgSidebar = dynamic("#E8EAED", "#1F2023")
    static let bgPanel = dynamic("#F6F7F8", "#242528")
    static let bgTitlebar = dynamic("#ECEEF0", "#202124")
    static let surface = dynamic("#FFFFFF", "#2C2E31")
    static let surfaceHi = dynamic("#E4E7EB", "#37393D")

    // Photo surfaces stay neutral regardless of the workspace appearance.
    static let canvas = Color(hex: "#1C1D1F")
    static let canvasSurface = Color(hex: "#242628")
    static let canvasSurfaceHi = Color(hex: "#303336")
    static let canvasText = Color(hex: "#F4F5F6")
    static let canvasText2 = Color(hex: "#BCC0C5")
    static let canvasText3 = Color(hex: "#8C9299")
    static let canvasLine = Color.white.opacity(0.12)
    static let canvasSelection = accent.opacity(0.18)

    // Lines
    static let line = dynamic(NSColor.black.withAlphaComponent(0.08), NSColor.white.withAlphaComponent(0.09))
    static let line2 = dynamic(NSColor.black.withAlphaComponent(0.15), NSColor.white.withAlphaComponent(0.16))

    // Text ramp
    static let text = dynamic("#212328", "#ECEDEF")
    static let text2 = dynamic("#545B64", "#B9BDC3")
    static let text3 = dynamic("#5D6570", "#A2A7AE")
    static let text4 = dynamic("#9198A1", "#767C84")

    // Semantic status colors
    static let red = dynamic("#C83D3D", "#FF6B63")
    static let redSoft = dynamic("#B93939", "#F05A52")
    static let yellow = dynamic("#A87112", "#E3A53A")
    static let green = dynamic("#23804F", "#3CC47C")
    static let blue = accent
    static let rating = dynamic("#B98116", "#E0A83A")
    static let starInactive = dynamic("#899099", "#7A8089")

    // Radii
    static let r: CGFloat = 8
    static let rSm: CGFloat = 6

    // Layout
    static let sidebarMinW: CGFloat = 184
    static let sidebarW: CGFloat = 228
    static let sidebarMaxW: CGFloat = 300
    static let contentMinW: CGFloat = 480
    static let inspectorMinW: CGFloat = 268
    static let inspectorW: CGFloat = 320
    static let inspectorMaxW: CGFloat = 400
    static let statusbarH: CGFloat = 26

    static let font = Font.system(size: 13)
    static let mono = Font.system(size: 11, design: .monospaced)
}

/// Color-label palette — port of `COLOR_LABELS` in data.jsx.
enum ColorLabel: String, CaseIterable, Identifiable, Hashable, Sendable {
    case red, orange, yellow, green, blue, purple
    var id: String { rawValue }
    var hex: Color {
        switch self {
        case .red: return Color(hex: "#ff453a")
        case .orange: return Color(hex: "#ff9f0a")
        case .yellow: return Color(hex: "#ffd60a")
        case .green: return Color(hex: "#30d158")
        case .blue: return Color(hex: "#0a84ff")
        case .purple: return Color(hex: "#bf5af2")
        }
    }
    var name: String {
        switch self {
        case .red: return "红"
        case .orange: return "橙"
        case .yellow: return "黄"
        case .green: return "绿"
        case .blue: return "蓝"
        case .purple: return "紫"
        }
    }
}
