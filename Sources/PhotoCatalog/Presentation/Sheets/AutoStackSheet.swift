// ============================================================
//  Auto-stack by capture time — Lightroom's Auto-Stack dialog
// ============================================================
import SwiftUI

/// The time between stacks, with how many stacks it makes as the slider moves.
struct AutoStackSheet: View {
    @Environment(AppState.self) private var app
    @State private var step: Double

    /// The intervals the slider stops at, in seconds.
    static let intervals: [Double] = [1, 2, 3, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600]

    init(seconds: Double) {
        _step = State(initialValue: Double(Self.intervals.firstIndex { $0 >= seconds } ?? 3))
    }

    private var seconds: Double { Self.intervals[max(0, min(Self.intervals.count - 1, Int(step.rounded())))] }

    private var label: String {
        seconds < 60 ? L("\(Int(seconds)) 秒") : L("\(Int(seconds / 60)) 分钟")
    }

    var body: some View {
        let preview = app.autoStackPreview(seconds: seconds)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("按拍摄时间自动叠放").font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            Text("同一台相机在这段时间内接连拍下的照片（连拍、包围曝光）叠放为一组，之后导入的照片也一样。")
                .font(.system(size: 12)).foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("间隔不超过")
                Slider(value: $step, in: 0...Double(Self.intervals.count - 1), step: 1)
                Text(label).monospacedDigit().frame(width: 64, alignment: .trailing)
            }
            Text("将生成 \(preview.stacks) 个堆栈，共 \(preview.photos) 张照片")
                .font(.system(size: 12)).foregroundStyle(Theme.text2)
            HStack {
                Spacer()
                ghostButton(nil, L("取消")) { app.sheet = nil }
                Button {
                    app.sheet = nil
                    app.setAutoStack(seconds: seconds)
                } label: {
                    Text("叠放").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 17).padding(.vertical, 8)
                        .background(Theme.accentFill).clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 440)
        .font(.system(size: 13))
        .foregroundStyle(Theme.text)
        .background(Theme.bgPanel)
    }
}
