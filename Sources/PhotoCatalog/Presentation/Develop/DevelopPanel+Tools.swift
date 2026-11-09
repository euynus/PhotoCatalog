import SwiftUI
import AppKit

extension DevelopPanel {
    // ---- tools: Lightroom's tool strip under the histogram; the open tool's controls below it ----
    @ViewBuilder
    func tools(_ asset: Asset, _ settings: DevelopSettings) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                tool(L("裁剪"), "crop", shortcut: "R", count: settings.crop != nil || settings.straighten != 0 ? 1 : 0,
                     isOn: app.developCropping) { app.developCropping.toggle() }
                tool(L("修复"), "bandage", shortcut: "Q", count: settings.spots.count, isOn: app.developSpotting) {
                    app.toggleSpotTool()
                }
                tool(L("蒙版"), "circle.dashed.inset.filled", shortcut: "M", count: settings.masks.count,
                     isOn: app.developMasking) { app.developMasking.toggle() }
            }
            if app.developCropping {
                geometry(asset, settings)
            } else if app.developSpotting {
                spots(asset, settings)
            } else if app.developMasking {
                masks(asset, settings)
            }
        }
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    /// One tool of the strip, with how many of its edits the photo has (masks, spots).
    private func tool(_ title: String, _ symbol: String, shortcut: String, count: Int, isOn: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 15))
                Text(title).font(.system(size: 11))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .foregroundStyle(isOn ? Theme.onAccent : Theme.text)
            .background(isOn ? AnyShapeStyle(Theme.accentFill) : AnyShapeStyle(Theme.surface),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(isOn ? .clear : Theme.line))
            .overlay(alignment: .topTrailing) {
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .bold)).monospacedDigit()
                        .foregroundStyle(isOn ? Theme.accentFill : Theme.onAccent)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(isOn ? AnyShapeStyle(Theme.onAccent) : AnyShapeStyle(Theme.accentFill), in: Capsule())
                        .padding(4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(title) (\(shortcut))")
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    @ViewBuilder
    private func geometry(_ asset: Asset, _ settings: DevelopSettings) -> some View {
        HStack(spacing: 6) {
            Text("旋转与翻转").font(.system(size: 12)).foregroundStyle(Theme.text2)
            Spacer(minLength: 0)
            Button { app.rotateSelection(clockwise: false) } label: { Image(systemName: "rotate.left") }
                .help("向左旋转 (⌘[)")
                .accessibilityLabel("向左旋转")
            Button { app.rotateSelection(clockwise: true) } label: { Image(systemName: "rotate.right") }
                .help("向右旋转 (⌘])")
                .accessibilityLabel("向右旋转")
            Button { app.flipSelection() } label: {
                Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
            }
            .help("水平翻转")
            .accessibilityLabel("水平翻转")
        }
        .controlSize(.small)
        if app.developCropping {
            HStack(spacing: 6) {
                Text("比例").font(.system(size: 12)).foregroundStyle(Theme.text2)
                Picker("比例", selection: Binding(get: { app.developCropAspect },
                                                set: { app.setCropAspect($0, for: asset) })) {
                    ForEach(CropAspect.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                Button { app.swapCropOrientation(for: asset) } label: {
                    Image(systemName: "rectangle.portrait.rotate")
                }
                .help("切换裁剪框横竖")
                .accessibilityLabel("切换裁剪框横竖")
            }
            .controlSize(.small)
        }
        DevelopSlider(title: L("角度"), value: settings.straighten,
                      range: -DevelopGeometry.maxStraighten...DevelopGeometry.maxStraighten, step: 0.1,
                      format: { $0 == 0 ? "0°" : String(format: "%+.1f°", $0) },
                      isNeutral: settings.straighten == 0,
                      onChange: { app.draftStraighten($0, for: asset) },
                      onReset: {
                          app.draftStraighten(0, for: asset)
                          commitDraft(asset, L("角度"))
                      },
                      onCommit: { commitDraft(asset, L("角度")) })
        HStack(spacing: 8) {
            Button("自动拉直") { app.autoStraighten(asset) }
                .help("按画面中的地平线自动拉直")
            Spacer(minLength: 0)
            Button("复位裁剪") {
                app.commitDevelop(asset.id, undoName: L("复位裁剪")) {
                    $0.crop = nil
                    $0.straighten = 0
                }
            }
            .disabled(settings.crop == nil && settings.straighten == 0)
        }
        .controlSize(.small)
    }

    // ---- spot removal: specks healed or cloned over ----
    @ViewBuilder
    private func spots(_ asset: Asset, _ settings: DevelopSettings) -> some View {
        HStack(spacing: 6) {
            Text("点按照片上的污点修复").font(.system(size: 12)).foregroundStyle(Theme.text2)
            Spacer(minLength: 0)
            if !settings.spots.isEmpty {
                Text("\(settings.spots.count) 处").font(.system(size: 11)).foregroundStyle(Theme.text3)
                Button("全部清除") {
                    app.commitDevelop(asset.id, undoName: L("清除污点去除")) { $0.spots = [] }
                }
            }
        }
        .controlSize(.small)
        if app.developSpotting {
            let index = settings.spots.firstIndex { $0.id == app.developSelectedSpotId }
            Picker("污点模式", selection: Binding(
                get: { index.map { settings.spots[$0].mode } ?? app.developSpotBrush.mode },
                set: { app.setSpotMode($0, for: asset) })) {
                ForEach(SpotRemoval.Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .help("修复：取用纹理并匹配周围的颜色与亮度；仿制：原样复制；移除：涂抹物体，由本机的 AI 模型按周围的内容补全")
            if app.developRemoving {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在移除…").font(.system(size: 11)).foregroundStyle(Theme.text3)
                }
            }
            // with a spot selected the sliders edit it; otherwise they set up the next spot
            if let index, settings.spots[index].mode == .remove {
                slider(DevelopControl(id: \DevelopSettings.spots[index].opacity, title: L("不透明度"), range: 0...100,
                                      step: 1, neutral: 100) { String(format: "%.0f", $0) }, asset, settings)
            } else if let index {
                let spot = settings.spots[index]
                DevelopSlider(title: L("大小"), value: SpotBrush.size(forRadius: spot.radius), range: 1...100, step: 1,
                              format: { String(format: "%.0f", $0) }, isNeutral: true,
                              onChange: { value in editSpot(asset, index) { $0.radius = value / 100 * 0.08 } },
                              onReset: {}, onCommit: { commitDraft(asset, L("污点大小")) })
                slider(DevelopControl(id: \DevelopSettings.spots[index].feather, title: L("羽化"), range: 0...100, step: 1,
                                      neutral: 50) { String(format: "%.0f", $0) }, asset, settings)
                slider(DevelopControl(id: \DevelopSettings.spots[index].opacity, title: L("不透明度"), range: 0...100,
                                      step: 1, neutral: 100) { String(format: "%.0f", $0) }, asset, settings)
            } else {
                DevelopSlider(title: L("大小"), value: app.developSpotBrush.size, range: 1...100, step: 1,
                              format: { String(format: "%.0f", $0) }, isNeutral: app.developSpotBrush.size == 12,
                              onChange: { app.developSpotBrush.size = $0 }, onReset: { app.developSpotBrush.size = 12 },
                              onCommit: {})
                DevelopSlider(title: L("羽化"), value: app.developSpotBrush.feather, range: 0...100, step: 1,
                              format: { String(format: "%.0f", $0) }, isNeutral: app.developSpotBrush.feather == 50,
                              onChange: { app.developSpotBrush.feather = $0 }, onReset: { app.developSpotBrush.feather = 50 },
                              onCommit: {})
                DevelopSlider(title: L("不透明度"), value: app.developSpotBrush.opacity, range: 0...100, step: 1,
                              format: { String(format: "%.0f", $0) }, isNeutral: app.developSpotBrush.opacity == 100,
                              onChange: { app.developSpotBrush.opacity = $0 }, onReset: { app.developSpotBrush.opacity = 100 },
                              onCommit: {})
            }
            HStack(spacing: 8) {
                Toggle("显示污点", isOn: Binding(get: { app.developVisualizeSpots }, set: { app.developVisualizeSpots = $0 }))
                    .toggleStyle(.checkbox)
                    .help("只显示细节，传感器灰尘等污点会显出圆圈")
                Spacer(minLength: 0)
                if let id = app.developSelectedSpotId, settings.spots.contains(where: { $0.id == id }) {
                    Button("删除污点", role: .destructive) { app.deleteSpot(id, from: asset.id) }
                        .help("删除所选污点 (Delete)")
                }
            }
            .controlSize(.small)
        }
    }

    private func editSpot(_ asset: Asset, _ index: Int, _ apply: (inout SpotRemoval) -> Void) {
        var next = app.developSettings(for: asset.id)
        guard next.spots.indices.contains(index) else { return }
        apply(&next.spots[index])
        app.updateDevelopDraft(next, for: asset.id)
    }
}
