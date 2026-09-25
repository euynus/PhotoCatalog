// ============================================================
//  Develop panel — Lightroom's Basic adjustments
// ============================================================
import SwiftUI

struct DevelopPanel: View {
    @Environment(AppState.self) private var app
    let asset: Asset?

    var body: some View {
        Group {
            if let asset {
                content(asset)
            } else {
                ContentUnavailableView("未选择照片", systemImage: "slider.horizontal.3")
            }
        }
        .frame(minWidth: Theme.inspectorMinW, idealWidth: Theme.inspectorW, maxWidth: Theme.inspectorMaxW,
               maxHeight: .infinity)
        .background(Theme.bgPanel)
        .foregroundStyle(Theme.text)
    }

    private func content(_ asset: Asset) -> some View {
        let settings = app.developSettings(for: asset.id)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(asset, settings: settings)
                section("白平衡") { whiteBalance(asset, settings) }
                section("色调") {
                    ForEach(DevelopControl.tone) { control in slider(control, asset, settings) }
                }
                section("偏好") {
                    ForEach(DevelopControl.presence) { control in slider(control, asset, settings) }
                }
            }
            .padding(14)
        }
    }

    private func header(_ asset: Asset, settings: DevelopSettings) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(asset.filename).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 8) {
                Toggle(isOn: Binding(get: { app.developShowsOriginal }, set: { app.developShowsOriginal = $0 })) {
                    Label("修改前", systemImage: "rectangle.split.2x1")
                }
                .toggleStyle(.button)
                .help("修改前 / 修改后 (\\)")
                Spacer(minLength: 0)
                Button("复位") {
                    app.commitDevelop([asset.id: .neutral], undoName: "复位调整")
                }
                .disabled(settings.isNeutral)
                .help("恢复为原照设置")
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func whiteBalance(_ asset: Asset, _ settings: DevelopSettings) -> some View {
        if asset.isRaw {
            let asShot = app.developAsShot[asset.id]
            DevelopSlider(title: "色温", value: settings.temperature ?? asShot?.temperature ?? 5500,
                          range: 2000...12000, step: 50,
                          format: { String(format: "%.0f K", $0) },
                          isNeutral: settings.temperature == nil,
                          onChange: { draft(asset, settings) { $0.temperature = $1 }($0) },
                          onReset: { commit(asset, settings, "色温") { $0.temperature = nil } },
                          onCommit: { commitDraft(asset, "色温") })
            DevelopSlider(title: "色调", value: settings.tint ?? asShot?.tint ?? 0,
                          range: -150...150, step: 1,
                          format: { String(format: "%+.0f", $0) },
                          isNeutral: settings.tint == nil,
                          onChange: { draft(asset, settings) { $0.tint = $1 }($0) },
                          onReset: { commit(asset, settings, "色调") { $0.tint = nil } },
                          onCommit: { commitDraft(asset, "色调") })
            if settings.temperature != nil || settings.tint != nil {
                Button("原照设置") {
                    commit(asset, settings, "白平衡") { $0.temperature = nil; $0.tint = nil }
                }
                .controlSize(.small)
            }
        } else {
            DevelopSlider(title: "色温", value: settings.temperature ?? 0, range: -100...100, step: 1,
                          format: { $0 == 0 ? "0" : String(format: "%+.0f", $0) },
                          isNeutral: (settings.temperature ?? 0) == 0,
                          onChange: { draft(asset, settings) { $0.temperature = $1 }($0) },
                          onReset: { commit(asset, settings, "色温") { $0.temperature = nil } },
                          onCommit: { commitDraft(asset, "色温") })
            DevelopSlider(title: "色调", value: settings.tint ?? 0, range: -100...100, step: 1,
                          format: { $0 == 0 ? "0" : String(format: "%+.0f", $0) },
                          isNeutral: (settings.tint ?? 0) == 0,
                          onChange: { draft(asset, settings) { $0.tint = $1 }($0) },
                          onReset: { commit(asset, settings, "色调") { $0.tint = nil } },
                          onCommit: { commitDraft(asset, "色调") })
        }
    }

    private func slider(_ control: DevelopControl, _ asset: Asset, _ settings: DevelopSettings) -> some View {
        DevelopSlider(title: control.title, value: settings[keyPath: control.id], range: control.range,
                      step: control.step, format: control.format,
                      isNeutral: settings[keyPath: control.id] == 0,
                      onChange: { draft(asset, settings) { $0[keyPath: control.id] = $1 }($0) },
                      onReset: { commit(asset, settings, control.title) { $0[keyPath: control.id] = 0 } },
                      onCommit: { commitDraft(asset, control.title) })
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text2)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    // ---- editing: drafts drive the live preview, a release saves one undoable step ----
    private func draft(_ asset: Asset, _ settings: DevelopSettings,
                       _ apply: @escaping (inout DevelopSettings, Double) -> Void) -> (Double) -> Void {
        { value in
            var next = app.developSettings(for: asset.id)
            apply(&next, value)
            app.updateDevelopDraft(next, for: asset.id)
        }
    }

    private func commitDraft(_ asset: Asset, _ title: String) {
        guard let draft = app.developDraft, draft.assetId == asset.id else { return }
        app.commitDevelop([asset.id: draft.settings], undoName: "调整\(title)")
    }

    private func commit(_ asset: Asset, _ settings: DevelopSettings, _ title: String,
                        _ apply: (inout DevelopSettings) -> Void) {
        var next = app.developSettings[asset.id] ?? .neutral
        apply(&next)
        app.commitDevelop([asset.id: next], undoName: "复位\(title)")
    }
}

/// Label + value + slider. Double-clicking the label resets to neutral, as in Lightroom.
private struct DevelopSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    let isNeutral: Bool
    let onChange: (Double) -> Void
    let onReset: () -> Void
    let onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(isNeutral ? Theme.text2 : Theme.text)
                    .onTapGesture(count: 2, perform: onReset)
                    .help("双击复位")
                Spacer(minLength: 4)
                Text(format(value))
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(isNeutral ? Theme.text3 : Theme.accent)
            }
            Slider(value: Binding(get: { value }, set: { onChange(($0 / step).rounded() * step) }),
                   in: range) { editing in
                if !editing { onCommit() }
            }
            .controlSize(.small)
            .tint(Theme.text4)   // no accent fill: most controls are bipolar around zero
            .accessibilityLabel(title)
            .accessibilityValue(format(value))
        }
    }
}
