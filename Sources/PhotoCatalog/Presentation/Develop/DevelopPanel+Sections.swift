import SwiftUI
import AppKit

extension DevelopPanel {
    func content(_ asset: Asset) -> some View {
        let settings = app.developSettings(for: asset.id)
        return ScrollViewReader { proxy in ScrollView {
            // lazy: of some sixty sliders, only the sections on screen are built and laid out,
            // when Develop opens and on every slider move
            LazyVStack(alignment: .leading, spacing: 18) {
                header(asset, settings: settings)
                tools(asset, settings)
                    .id("tools")
                section(L("配置文件"), id: "profile") { DevelopProfilePicker(asset: asset, settings: settings) }
                section(L("白平衡"), id: "whiteBalance", accessory: {
                    Button("自动") { app.autoWhiteBalance() }
                        .controlSize(.small)
                        .help("按照片中的中性色自动设置色温与色调")
                }) {
                    Toggle(isOn: Binding(get: { app.developPickingWhiteBalance },
                                         set: { app.developPickingWhiteBalance = $0 })) {
                        Label("白平衡吸管", systemImage: "eyedropper")
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("点选照片中的中性灰色区域 (W)")
                    whiteBalance(asset, settings)
                }
                section(L("色调"), id: "tone", accessory: {
                    Button("自动") { app.autoTone() }
                        .controlSize(.small)
                        .help("自动设置曝光、高光、阴影、白色和黑色色阶 (⌘U)")
                }) {
                    ForEach(DevelopControl.tone) { control in slider(control, asset, settings) }
                }
                section(L("偏好"), id: "presence") {
                    ForEach(DevelopControl.presence) { control in slider(control, asset, settings) }
                }
                section(L("色调曲线"), id: "curve") {
                    ToneCurveEditor(curve: settings.curve,
                                    histogram: app.developHistogram?.assetId == asset.id
                                        ? app.developHistogram?.histogram : nil,
                                    onChange: { curve in
                                        var next = app.developSettings(for: asset.id)
                                        next.curve = curve
                                        app.updateDevelopDraft(next, for: asset.id)
                                    },
                                    onCommit: { undoName in app.commitDevelopDraft(for: asset.id, undoName: undoName) },
                                    onCancel: { app.discardDevelopDraft(for: asset.id) },
                                    channel: $curveChannel)
                        .id(asset.id)   // a new photo starts with no drag in progress
                }
                if DevelopProfile(stored: settings.profile) == .monochrome {
                    section(L("黑白混合"), id: "mixer", accessory: {
                        Button("自动") { app.autoGrayMix() }
                            .controlSize(.small)
                            .help("按照片中各颜色的明暗把它们在黑白中分开")
                    }) {
                        ForEach(DevelopControl.grayMixer) { control in slider(control, asset, settings) }
                    }
                } else {
                    section(L("混色器"), id: "mixer") {
                        Picker("混色器属性", selection: $mixerProperty) {
                            ForEach(ColorMixer.Property.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.small)
                        ForEach(DevelopControl.mixer(mixerProperty)) { control in slider(control, asset, settings) }
                    }
                }
                section(L("颜色分级"), id: "grading", accessory: { gradingSwatch(settings) }) {
                    Picker("颜色分级区域", selection: $gradingRegion) {
                        ForEach(ColorGrading.Region.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    ForEach(DevelopControl.grading(gradingRegion)) { control in slider(control, asset, settings) }
                    ForEach(DevelopControl.gradingShape) { control in slider(control, asset, settings) }
                }
                section(L("细节"), id: "detail") {
                    ForEach(DevelopControl.detail) { control in slider(control, asset, settings) }
                    Text("锐化与降噪在 1:1 视图中看得最准")
                        .font(.system(size: 11)).foregroundStyle(Theme.text3)
                }
                section(L("镜头校正"), id: "lens") {
                    ForEach(DevelopControl.lens) { control in slider(control, asset, settings) }
                    Toggle("删除色差", isOn: Binding(get: { settings.removeChromaticAberration }, set: { on in
                        var next = app.developSettings[asset.id] ?? .neutral
                        next.removeChromaticAberration = on
                        app.commitDevelop([asset.id: next], undoName: L("删除色差"))
                    }))
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("测量并校正镜头的横向色差：朝画面四角，边缘两侧出现的红、蓝或紫、绿色边")
                    ForEach(DevelopControl.defringe) { control in slider(control, asset, settings) }
                }
                section(L("变换"), id: "transform") { transform(asset, settings) }
                section(L("效果"), id: "effects") {
                    ForEach(DevelopControl.effects) { control in slider(control, asset, settings) }
                }
                section(L("镜头模糊"), id: "lensBlur", accessory: {
                    Toggle("镜头模糊", isOn: Binding(get: { settings.lensBlur.enabled }, set: { app.setLensBlur($0, for: asset) }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .help("按照片中的远近模糊焦点以外的部分")
                }) { lensBlur(asset, settings) }
                section(L("校准"), id: "calibration") {
                    ForEach(DevelopControl.calibration) { control in slider(control, asset, settings) }
                }
                section(L("LUT"), id: "lut", accessory: {
                    Menu {
                        Button("导入 LUT…") { app.chooseAndImportLUTs() }
                        if !app.developLUTs.isEmpty {
                            Menu("删除 LUT") {
                                ForEach(app.developLUTs) { lut in
                                    Button(lut.name, role: .destructive) { app.confirmDeleteLUT(lut.id) }
                                }
                            }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("导入或删除 LUT（.cube）")
                    .accessibilityLabel("导入或删除 LUT")
                }) { lut(asset, settings) }
                section(L("AI 调整"), id: "ai") { DevelopByTextField() }
                section(L("软打样"), id: "softProof", accessory: {
                    Toggle("软打样", isOn: Binding(get: { app.softProofing }, set: { _ in app.toggleSoftProofing() }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .help("用输出色彩空间或打印机配置文件预览照片 (S)")
                }) { softProof() }
            }
            .padding(14)
        }
        // a tool opened (a mask added, R, Q) brings its controls into view, wherever the panel was
        .onChange(of: app.developMasking || app.developCropping || app.developSpotting) { _, open in
            if open { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("tools", anchor: .top) } }
        }
        }
        // flush with the inspector's top, the scroll view runs on under the toolbar, and SwiftUI
        // then hit-tests its content the toolbar's height (52 points) above where it's drawn: the
        // pointer on one preset hovered and applied the one two rows down. A point lower, it
        // stays below the toolbar, as the info inspector's does under its header.
        .padding(.top, 1)
    }

    private func section<Content: View>(_ title: String, id: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        DevelopSection(title, id: id, group: DevelopSections.panel, accessory: { EmptyView() }, content: content)
    }

    private func section<Accessory: View, Content: View>(_ title: String, id: String, @ViewBuilder accessory: @escaping () -> Accessory,
                                                         @ViewBuilder content: @escaping () -> Content) -> some View {
        DevelopSection(title, id: id, group: DevelopSections.panel, accessory: accessory, content: content)
    }
}
