// ============================================================
//  PhotoCatalog Mac — macOS dark visual system
//  Ported 1:1 from app/styles.css :root design tokens.
// ============================================================
import SwiftUI

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

/// Design tokens. Each value maps to a CSS custom property of the same intent.
enum Theme {
    // Accent
    static let accent = Color(hex: "#ff9f0a")
    static let accent2 = Color(hex: "#ffb340")
    static let accentPress = Color(hex: "#e88f06")
    static let accentSoft = Color(hex: "#ff9f0a").opacity(0.16)
    /// Foreground used on top of the accent fill (`#1a1206`).
    static let onAccent = Color(hex: "#1a1206")

    // Surfaces
    static let bgDesktop = Color(hex: "#0a0a0b")
    static let bgContent = Color(hex: "#1b1b1d")
    static let bgSidebar = Color(hex: "#232325")
    static let bgPanel = Color(hex: "#1f1f21")
    static let bgTitlebar = Color(hex: "#2b2b2e")
    static let surface = Color(hex: "#313134")
    static let surfaceHi = Color(hex: "#3c3c40")
    static let surfacePress = Color(hex: "#474749")

    // Lines
    static let line = Color.white(0.075)
    static let line2 = Color.white(0.13)

    // Text ramp
    static let text = Color(hex: "#f3f3f5")
    static let text2 = Color.label(0.62)
    static let text3 = Color.label(0.40)
    static let text4 = Color.label(0.28)

    // Semantic status colors
    static let red = Color(hex: "#ff453a")
    static let redSoft = Color(hex: "#ff6b62")
    static let yellow = Color(hex: "#ffd60a")
    static let green = Color(hex: "#30d158")
    static let blue = Color(hex: "#0a84ff")
    static let purple = Color(hex: "#bf5af2")
    static let folderGray = Color(hex: "#9aa0a6")
    static let albumBlue = Color(hex: "#5ac8fa")

    // Radii
    static let r: CGFloat = 7
    static let rSm: CGFloat = 5

    // Layout
    static let sidebarW: CGFloat = 222
    static let inspectorW: CGFloat = 304
    static let titlebarH: CGFloat = 52
    static let filterbarH: CGFloat = 44
    static let contentHeadH: CGFloat = 40
    static let statusbarH: CGFloat = 26

    // Titlebar gradient (linear 180deg #313134 -> #29292c)
    static let titlebarGradient = LinearGradient(
        colors: [Color(hex: "#313134"), Color(hex: "#29292c")],
        startPoint: .top, endPoint: .bottom
    )
    static let glyphGradient = LinearGradient(
        colors: [accent, Color(hex: "#ff7a00")],
        startPoint: UnitPoint(x: 0.25, y: 0), endPoint: UnitPoint(x: 0.75, y: 1)  // ~150°
    )
    static let importFill = LinearGradient(
        colors: [accent, accent2], startPoint: .leading, endPoint: .trailing
    )

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
