import SwiftUI
import AppKit

/// RGB histogram of the current render, drawn additively so overlapping channels read as
/// white, with Lightroom-style clipping triangles in the top corners.
struct DevelopHistogramView: View {
    let histogram: DevelopHistogram?

    var body: some View {
        Canvas { context, size in
            guard let histogram else { return }
            // scale to the tallest interior bin so a clipped end spike doesn't flatten the rest
            let interior = [histogram.red, histogram.green, histogram.blue].flatMap { $0.dropFirst().dropLast() }
            let peak = max(interior.max() ?? 0, 1e-6)
            context.blendMode = .plusLighter
            let channels: [([Double], Color)] = [
                (histogram.red, Color(red: 0.9, green: 0.2, blue: 0.2)),
                (histogram.green, Color(red: 0.2, green: 0.8, blue: 0.3)),
                (histogram.blue, Color(red: 0.25, green: 0.4, blue: 0.95)),
            ]
            for (bins, color) in channels where bins.count > 1 {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height))
                for (index, value) in bins.enumerated() {
                    path.addLine(to: CGPoint(x: size.width * CGFloat(index) / CGFloat(bins.count - 1),
                                             y: size.height * (1 - min(1, value / peak * 0.92))))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
                context.fill(path, with: .color(color.opacity(0.75)))
            }
        }
        .frame(height: 88)
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(alignment: .topLeading) {
            clipIndicator(histogram?.shadowClipping, label: L("阴影剪切"))
        }
        .overlay(alignment: .topTrailing) {
            clipIndicator(histogram?.highlightClipping, label: L("高光剪切"))
        }
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
        .accessibilityElement()
        .accessibilityLabel("直方图")
    }

    private func clipIndicator(_ share: Double?, label: String) -> some View {
        let clipped = (share ?? 0) > DevelopHistogram.clippingWarning
        return Image(systemName: "triangle.fill")
            .font(.system(size: 7))
            .foregroundStyle(clipped ? Theme.canvasText : Theme.canvasText3.opacity(0.5))
            .padding(6)
            .help(share.map { String(format: "\(label) %.1f%%", $0 * 100) } ?? label)
    }
}
