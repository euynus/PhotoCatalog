import SwiftUI
import AppKit

extension DevelopPanel {
    @ViewBuilder
    func whiteBalance(_ asset: Asset, _ settings: DevelopSettings) -> some View {
        if asset.isRaw {
            let asShot = app.developAsShot[asset.id]
            DevelopSlider(title: L("色温"), value: settings.temperature ?? asShot?.temperature ?? 5500,
                          range: 2000...12000, step: 50,
                          format: { String(format: "%.0f K", $0) },
                          isNeutral: settings.temperature == nil,
                          onChange: draft(asset) { $0.temperature = $1 },
                          onReset: { commit(asset, L("色温")) { $0.temperature = nil } },
                          onCommit: { commitDraft(asset, L("色温")) })
            DevelopSlider(title: L("色调", table: "Context"), value: settings.tint ?? asShot?.tint ?? 0,
                          range: -150...150, step: 1,
                          format: { String(format: "%+.0f", $0) },
                          isNeutral: settings.tint == nil,
                          onChange: draft(asset) { $0.tint = $1 },
                          onReset: { commit(asset, L("色调", table: "Context")) { $0.tint = nil } },
                          onCommit: { commitDraft(asset, L("色调", table: "Context")) })
            if settings.temperature != nil || settings.tint != nil {
                Button("原照设置") {
                    commit(asset, L("白平衡")) { $0.temperature = nil; $0.tint = nil }
                }
                .controlSize(.small)
            }
        } else {
            DevelopSlider(title: L("色温"), value: settings.temperature ?? 0, range: -100...100, step: 1,
                          format: { $0 == 0 ? "0" : String(format: "%+.0f", $0) },
                          isNeutral: (settings.temperature ?? 0) == 0,
                          onChange: draft(asset) { $0.temperature = $1 },
                          onReset: { commit(asset, L("色温")) { $0.temperature = nil } },
                          onCommit: { commitDraft(asset, L("色温")) })
            DevelopSlider(title: L("色调", table: "Context"), value: settings.tint ?? 0, range: -100...100, step: 1,
                          format: { $0 == 0 ? "0" : String(format: "%+.0f", $0) },
                          isNeutral: (settings.tint ?? 0) == 0,
                          onChange: draft(asset) { $0.tint = $1 },
                          onReset: { commit(asset, L("色调", table: "Context")) { $0.tint = nil } },
                          onCommit: { commitDraft(asset, L("色调", table: "Context")) })
        }
    }

    /// The chosen region's tint, so the hue slider's number reads as a color.
    func gradingSwatch(_ settings: DevelopSettings) -> some View {
        let controls = DevelopControl.grading(gradingRegion)   // hue, saturation, luminance
        let hue = settings[keyPath: controls[0].id], saturation = settings[keyPath: controls[1].id]
        return Circle()
            .fill(Color(hue: hue / 360, saturation: max(0.15, saturation / 100), brightness: 0.95))
            .frame(width: 12, height: 12)
            .overlay(Circle().strokeBorder(Theme.line2, lineWidth: 1))
            .accessibilityHidden(true)
    }

    // ---- lens blur: depth-of-field from the photo's estimated depth ----
    @ViewBuilder
    func lensBlur(_ asset: Asset, _ settings: DevelopSettings) -> some View {
        if settings.lensBlur.enabled {
            ForEach(DevelopControl.lensBlur) { control in slider(control, asset, settings) }
            HStack(spacing: 6) {
                Toggle(isOn: Binding(get: { app.developPickingFocus }, set: { app.developPickingFocus = $0 })) {
                    Label("点选焦点", systemImage: "scope")
                }
                .toggleStyle(.button)
                .help("点选照片中要保持清晰的地方")
                Toggle(isOn: Binding(get: { app.developShowsDepth }, set: { app.developShowsDepth = $0 })) {
                    Label("显示深度", systemImage: "square.3.layers.3d.down.backward")
                }
                .toggleStyle(.button)
                .help("用颜色显示照片中的远近：暖色近，冷色远")
            }
            .controlSize(.small)
        } else {
            Text("按照片中的远近虚化背景或前景，深度由本机模型估计")
                .font(.system(size: 11)).foregroundStyle(Theme.text3)
        }
    }

    // ---- soft proofing: the photo through an output profile ----
    @ViewBuilder
    func softProof() -> some View {
        if app.softProofing {
            Picker("配置文件", selection: Binding(get: { app.softProof.profile }, set: { app.softProof.profile = $0 })) {
                ForEach(app.softProofProfiles) { Text($0.name).tag($0.id) }
            }
            .controlSize(.small)
            Picker("方法", selection: Binding(get: { app.softProof.intent }, set: { app.softProof.intent = $0 })) {
                ForEach(SoftProof.Intent.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .disabled(app.softProof.simulatePaper)
            .help("可感知：压缩所有颜色以容纳超出色域的颜色；相对比色：保留色域内的颜色，超出的剪切")
            Toggle("模拟纸张与墨水", isOn: Binding(get: { app.softProof.simulatePaper }, set: { app.softProof.simulatePaper = $0 }))
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .help("显示纸张的白色与墨水的黑色")
            Toggle("色域警告", isOn: Binding(get: { app.softProof.gamutWarning }, set: { app.softProof.gamutWarning = $0 }))
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .help("以红色标出这个配置文件无法表现的颜色")
        } else {
            Text("预览照片在其他色彩空间或打印出来的样子 (S)")
                .font(.system(size: 11)).foregroundStyle(Theme.text3)
        }
    }

    // ---- LUT: a creative look from the library ----
    @ViewBuilder
    func lut(_ asset: Asset, _ settings: DevelopSettings) -> some View {
        if app.developLUTs.isEmpty && settings.lutId == nil {
            HStack {
                Text("导入 .cube 文件，为照片套用电影感等风格").font(.system(size: 11)).foregroundStyle(Theme.text3)
                Spacer(minLength: 4)
                Button("导入 LUT…") { app.chooseAndImportLUTs() }.controlSize(.small)
            }
        } else {
            Picker("LUT", selection: Binding(get: { settings.lutId ?? "" }, set: { id in
                app.setDevelopLUT(id.isEmpty ? nil : id, for: asset)
            })) {
                Text("无").tag("")
                ForEach(app.developLUTs) { lut in Text(lut.name).tag(lut.id) }
                if let id = settings.lutId, !app.developLUTs.contains(where: { $0.id == id }) {
                    Text("已删除的 LUT").tag(id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            if settings.lutId != nil { slider(DevelopControl.lutAmount, asset, settings) }
        }
    }

    // ---- transform: perspective, the crop kept inside the corrected photo ----
    @ViewBuilder
    func transform(_ asset: Asset, _ settings: DevelopSettings) -> some View {
        HStack(spacing: 6) {
            Button("自动") { app.autoUpright(asset, mode: .auto) }
                .help("让竖直线条竖直，水平线条也尽量平行")
            Button("垂直") { app.autoUpright(asset, mode: .vertical) }
                .help("只让竖直线条竖直、平行")
            Spacer(minLength: 0)
            Button("复位变换") {
                app.commitDevelop(asset.id, undoName: L("复位变换")) {
                    $0.perspectiveVertical = 0
                    $0.perspectiveHorizontal = 0
                }
            }
            .disabled(!settings.hasPerspective)
        }
        .controlSize(.small)
        ForEach(DevelopControl.transform) { control in
            DevelopSlider(title: control.title, value: settings[keyPath: control.id], range: control.range,
                          step: control.step, format: control.format,
                          isNeutral: settings[keyPath: control.id] == control.neutral,
                          onChange: { value in
                              // the crop shrinks from the saved one, so moving back grows it again
                              var next = app.developSettings[asset.id] ?? .neutral
                              next[keyPath: control.id] = value
                              next.crop = DevelopGeometry.refit(next, frame: app.developFrame(for: asset, settings: next))
                              app.updateDevelopDraft(next, for: asset.id)
                          },
                          onReset: { commit(asset, control.title) { $0[keyPath: control.id] = control.neutral } },
                          onCommit: { commitDraft(asset, control.title) })
        }
    }
}
