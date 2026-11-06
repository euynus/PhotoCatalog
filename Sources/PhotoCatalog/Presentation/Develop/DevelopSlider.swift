import SwiftUI
import AppKit

/// Label + value + slider. Double-clicking the label resets to neutral, as in Lightroom.
struct DevelopSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    let isNeutral: Bool
    let onChange: (Double) -> Void
    let onReset: () -> Void
    let onCommit: () -> Void

    /// Name, slider and value on one row, as in Lightroom: half the height of a name above its
    /// slider, so twice the controls fit on screen. Long names (English) take a second line.
    static let titleWidth: CGFloat = 92
    static let valueWidth: CGFloat = 46

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(isNeutral ? Theme.text2 : Theme.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: Self.titleWidth, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: onReset)
                .help("双击复位")
            Slider(value: Binding(get: { value }, set: { onChange(($0 / step).rounded() * step) }),
                   in: range) { editing in
                if !editing { onCommit() }
            }
            .controlSize(.small)
            .tint(Theme.text4)   // no accent fill: most controls are bipolar around zero
            .accessibilityLabel(title)
            .accessibilityValue(format(value))
            // a fixed column, so the slider doesn't shift as the digits change
            Text(format(value))
                .font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(isNeutral ? Theme.text3 : Theme.accent)
                .lineLimit(1)
                .frame(width: Self.valueWidth, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }
}
