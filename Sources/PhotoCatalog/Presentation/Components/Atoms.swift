// ============================================================
//  Shared UI atoms — port of components.jsx
// ============================================================
import SwiftUI

// ---------- Star rating ----------
struct StarsView: View {
    var value: Int
    var size: CGFloat = 12
    var gap: CGFloat = 1
    var dim: Bool = false
    var onRate: ((Int) -> Void)?

    var body: some View {
        HStack(spacing: gap) {
            ForEach(1...5, id: \.self) { n in
                if let onRate {
                    Button { onRate(n) } label: { star(n) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(n) 星")
                } else {
                    star(n).allowsHitTesting(false)   // passive stars let taps reach the cell
                }
            }
        }
        // passive: one readable 评分 element; interactive: keep the 5 buttons
        .accessibilityElement(children: onRate == nil ? .ignore : .contain)
        .accessibilityLabel("评分")
        .accessibilityValue("\(value) 星")
    }

    private func star(_ n: Int) -> some View {
        let on = n <= value
        return Image(systemName: on ? "star.fill" : "star")
            .font(.system(size: size))
            .foregroundStyle(on ? Theme.accent
                : (dim ? Color.white(0.16) : Color.white(0.26)))
            .contentShape(Rectangle())
    }
}

// ---------- Flag pill ----------
struct FlagPill: View {
    var flag: Flag
    var size: CGFloat = 13
    var body: some View {
        switch flag {
        case .pick:
            Image(systemName: "flag.fill").font(.system(size: size))
                .foregroundStyle(Theme.accent).help("精选")
        case .reject:
            Image(systemName: "xmark.circle.fill").font(.system(size: size))
                .foregroundStyle(Theme.red).help("拒绝")
        case .none:
            EmptyView()
        }
    }
}

// ---------- Color dot ----------
struct ColorDot: View {
    var label: ColorLabel?
    var size: CGFloat = 9
    var body: some View {
        if let label {
            Circle().fill(label.hex)
                .frame(width: size, height: size)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 1.5))
        }
    }
}

// ---------- Type badge ----------
struct TypeBadge: View {
    var asset: Asset
    var small: Bool = false
    var body: some View {
        Text(asset.type)
            .font(.system(size: small ? 8.5 : 9.5, weight: .bold))
            .tracking(0.4)
            .padding(.horizontal, small ? 3 : 4)
            .padding(.vertical, small ? 1 : 1.5)
            .foregroundStyle(asset.isRaw ? Theme.onAccent : Color.white(0.92))
            .background(asset.isRaw ? Theme.accent.opacity(0.92) : Color.black.opacity(0.55))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(asset.isRaw ? .clear : Color.white(0.18), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

// ---------- Status badge ----------
struct StatusBadge: View {
    var status: AssetStatus
    var body: some View {
        switch status {
        case .offline:
            Image(systemName: "wifi.slash").font(.system(size: 13))
                .foregroundStyle(Theme.yellow)
                .shadow(color: .black.opacity(0.7), radius: 1, y: 1).help("离线")
        case .missing:
            Image(systemName: "questionmark.square.dashed").font(.system(size: 13))
                .foregroundStyle(Theme.red)
                .shadow(color: .black.opacity(0.7), radius: 1, y: 1).help("文件缺失")
        case .ready:
            EmptyView()
        }
    }
}

// ---------- Segmented control ----------
struct SegOption: Identifiable {
    var id: String { value }
    let value: String
    var icon: String?
    var label: String?
    var title: String?
}

struct Segmented: View {
    let options: [SegOption]
    let value: String
    let onChange: (String) -> Void
    var size: String = "md"  // md / sm

    private var height: CGFloat { size == "sm" ? 21 : 24 }
    private var hpad: CGFloat { size == "sm" ? 9 : 10 }
    private var fontSize: CGFloat { size == "sm" ? 11.5 : 12.5 }
    private var iconSize: CGFloat { size == "sm" ? 14 : 15 }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { o in
                // a real Button, not a tap gesture — otherwise the segment is
                // invisible to VoiceOver and Full Keyboard Access
                Button { onChange(o.value) } label: {
                    SegItem(option: o, active: value == o.value, height: height, hpad: hpad,
                            fontSize: fontSize, iconSize: iconSize, fontWeight: size == "sm" ? .medium : .regular)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(o.label ?? o.title ?? o.value)
                .accessibilityAddTraits(value == o.value ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.black.opacity(0.28))
        .overlay(RoundedRectangle(cornerRadius: Theme.rSm).strokeBorder(Theme.line2, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
    }
}

private struct SegItem: View {
    let option: SegOption
    let active: Bool
    let height: CGFloat
    let hpad: CGFloat
    let fontSize: CGFloat
    let iconSize: CGFloat
    let fontWeight: Font.Weight
    @State private var hover = false

    var body: some View {
        HStack(spacing: 5) {
            if let icon = option.icon { Icon(icon, size: iconSize) }
            if let label = option.label { Text(label).font(.system(size: fontSize, weight: fontWeight)) }
        }
        .frame(height: height)
        .padding(.horizontal, hpad)
        .foregroundStyle(active ? Theme.text : (hover ? Theme.text : Theme.text2))
        .background(active ? Theme.surfaceHi : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .shadow(color: active ? .black.opacity(0.35) : .clear, radius: 1, y: 1)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .help(option.title ?? option.label ?? "")
    }
}

// ---------- Toolbar button ----------
struct ToolButton<Trailing: View>: View {
    var icon: String?
    var label: String
    var active: Bool = false
    var danger: Bool = false
    var disabled: Bool = false
    var horizontalPadding: CGFloat = 0
    let action: () -> Void
    @ViewBuilder var trailing: () -> Trailing
    @State private var hover = false

    init(icon: String? = nil, label: String, active: Bool = false, danger: Bool = false,
         disabled: Bool = false, horizontalPadding: CGFloat = 0,
         action: @escaping () -> Void,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.icon = icon
        self.label = label
        self.active = active
        self.danger = danger
        self.disabled = disabled
        self.horizontalPadding = horizontalPadding
        self.action = action
        self.trailing = trailing
    }

    private var background: Color {
        if active { return Theme.surfaceHi }
        if hover { return danger ? Theme.red.opacity(0.18) : Theme.surface }
        return .clear
    }
    private var foreground: Color {
        if active { return Theme.text }
        if hover { return danger ? Theme.redSoft : Theme.text }
        return Theme.text2
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Icon(icon, size: 16) }
                trailing()
            }
            .frame(minWidth: 30, minHeight: 30)
            .padding(.horizontal, horizontalPadding)
            .foregroundStyle(foreground)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
            .overlay(alignment: .topTrailing) { Color.clear }  // anchor for badges by caller
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .onHover { hover = $0 }
        .help(label)
        .accessibilityLabel(label)   // otherwise VoiceOver reads the SF Symbol name
    }
}

// ---------- Hover tracking ----------
/// Wraps inline controls that need hover feedback without a dedicated struct
/// (SwiftUI @State can't live in a ForEach row built by a plain function).
struct Hover<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content
    @State private var hover = false

    var body: some View {
        content(hover).onHover { hover = $0 }
    }
}

// ---------- Focus ring ----------
extension View {
    /// Accent border + 3px accent-soft glow when focused (CSS :focus / :focus-within).
    func focusRing(_ focused: Bool, radius: CGFloat, base: Color = Theme.line2) -> some View {
        self
            .overlay(RoundedRectangle(cornerRadius: radius)
                .strokeBorder(focused ? Theme.accent : base, lineWidth: 1))
            .overlay {
                if focused {
                    RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(Theme.accentSoft, lineWidth: 3).padding(-1.5)
                }
            }
    }
}

// ---------- Media size helpers ----------
func fileSizeText(megabytes: Double) -> String {
    let bytes = Int64((max(0, megabytes) * 1_024 * 1_024).rounded())
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func megapixelText(_ megapixels: Double) -> String {
    guard megapixels > 0 else { return "0 MP" }
    return megapixels < 0.1 ? "<0.1 MP" : String(format: "%.1f MP", megapixels)
}

// ---------- Date helpers ----------
enum DateFmt {
    private static let weekdays = ["日", "一", "二", "三", "四", "五", "六"]

    static func long(_ d: Date, withTime: Bool = true, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: d)
        let wk = weekdays[(c.weekday ?? 1) - 1]
        let base = "\(c.year ?? 0)年\(c.month ?? 0)月\(c.day ?? 0)日 周\(wk)"
        if !withTime { return base }
        return base + String(format: " %02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    static func short(_ d: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Capture dates are fixed wall-clock (UTC-anchored) — display them in that frame so the
    /// time shown always matches what the camera recorded, regardless of the viewer's timezone.
    static func longCapture(_ d: Date, withTime: Bool = true) -> String {
        long(d, withTime: withTime, calendar: .captureWallClock)
    }
    static func shortCapture(_ d: Date) -> String { short(d, calendar: .captureWallClock) }
}
