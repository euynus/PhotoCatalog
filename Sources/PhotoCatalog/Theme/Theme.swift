// ============================================================
//  Light workspace chrome and a neutral, dark photographic canvas.
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

/// Shared workspace and photographic-canvas colors.
enum Theme {
    // Accent
    static let accent = Color(hex: "#2764D6")
    static let accent2 = Color(hex: "#3E77E1")
    static let accentPress = Color(hex: "#184FAE")
    static let accentSoft = accent.opacity(0.10)
    static let onAccent = Color.white

    // Surfaces
    static let bgDesktop = Color(hex: "#E8E9EB")
    static let bgContent = Color(hex: "#F4F5F6")
    static let bgSidebar = Color(hex: "#E8EAED")
    static let bgPanel = Color(hex: "#F6F7F8")
    static let bgTitlebar = Color(hex: "#ECEEF0")
    static let surface = Color.white
    static let surfaceHi = Color(hex: "#E4E7EB")
    static let surfacePress = Color(hex: "#D7DCE2")

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
    static let line = Color.black.opacity(0.08)
    static let line2 = Color.black.opacity(0.15)

    // Text ramp
    static let text = Color(hex: "#212328")
    static let text2 = Color(hex: "#545B64")
    static let text3 = Color(hex: "#5D6570")
    static let text4 = Color(hex: "#9198A1")

    // Semantic status colors
    static let red = Color(hex: "#C83D3D")
    static let redSoft = Color(hex: "#B93939")
    static let yellow = Color(hex: "#A87112")
    static let green = Color(hex: "#23804F")
    static let blue = accent
    static let purple = Color(hex: "#8653BC")
    static let folderGray = Color(hex: "#6B737E")
    static let albumBlue = Color(hex: "#35709D")
    static let rating = Color(hex: "#B98116")
    static let starInactive = Color(hex: "#899099")

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
    static let titlebarH: CGFloat = 54
    static let contentHeadH: CGFloat = 86
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
