// ============================================================
//  Develop panel — Lightroom's Basic adjustments
// ============================================================
import SwiftUI

struct DevelopPanel: View {
    @Environment(AppState.self) private var app
    let asset: Asset?
    @State private var mixerProperty: ColorMixer.Property = .hue
    @State private var gradingRegion: ColorGrading.Region = .shadows
    @State private var renamingSnapshot: String?
    @State private var snapshotName = ""
    /// Typing a snapshot name must reach the field, not the photo shortcuts.
    @FocusState private var snapshotNameFocused: Bool
    @State private var showsFullHistory = false

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
                section(L("预设"), accessory: {
                    HStack(spacing: 8) {
                        Menu {
                            Button("导入预设…") { app.chooseAndImportDevelopPresets() }
                            Button("导出我的预设…") { app.exportDevelopPresets(app.developPresets.map(\.id)) }
                                .disabled(app.developPresets.isEmpty)
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("导入或导出预设（.xmp，可与 Lightroom 互通）")
                        Button { app.showDevelopTransfer(.preset) } label: { Image(systemName: "plus") }
                            .buttonStyle(.borderless)
                            .help("以当前设置存储为预设")
                            .accessibilityLabel("存储为预设…")
                    }
                }) {
                    if let applied = app.developPresetAmount(for: asset.id) {
                        let amount = app.developPresetAmountDraft ?? applied.amount
                        DevelopSlider(title: L("强度 · \(applied.presetName)"), value: amount * 100, range: 0...200, step: 1,
                                      format: { String(format: "%.0f%%", $0) }, isNeutral: amount == 1,
                                      onChange: { app.setDevelopPresetAmount($0 / 100) },
                                      onReset: { app.commitDevelopPresetAmount(1) },
                                      onCommit: { app.commitDevelopPresetAmount() })
                    }
                    DevelopPresetList(asset: asset)
                }
                section(L("裁剪与旋转")) { geometry(asset, settings) }
                section(L("变换")) { transform(asset, settings) }
                section(L("蒙版")) { masks(asset, settings) }
                section(L("污点去除")) { spots(asset, settings) }
                section(L("白平衡"), accessory: {
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
                section(L("色调"), accessory: {
                    Button("自动") { app.autoTone() }
                        .controlSize(.small)
                        .help("自动设置曝光、高光、阴影、白色和黑色色阶 (⌘U)")
                }) {
                    ForEach(DevelopControl.tone) { control in slider(control, asset, settings) }
                }
                section(L("偏好")) {
                    ForEach(DevelopControl.presence) { control in slider(control, asset, settings) }
                }
                section(L("色调曲线")) {
                    ToneCurveEditor(curve: settings.curve,
                                    histogram: app.developHistogram?.assetId == asset.id
                                        ? app.developHistogram?.histogram : nil,
                                    onChange: { curve in
                                        var next = app.developSettings(for: asset.id)
                                        next.curve = curve
                                        app.updateDevelopDraft(next, for: asset.id)
                                    },
                                    onCommit: { undoName in
                                        guard let draft = app.developDraft, draft.assetId == asset.id else { return }
                                        app.commitDevelop([asset.id: draft.settings], undoName: undoName)
                                    })
                }
                section(L("混色器")) {
                    Picker("混色器属性", selection: $mixerProperty) {
                        ForEach(ColorMixer.Property.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    ForEach(DevelopControl.mixer(mixerProperty)) { control in slider(control, asset, settings) }
                }
                section(L("颜色分级"), accessory: { gradingSwatch(settings) }) {
                    Picker("颜色分级区域", selection: $gradingRegion) {
                        ForEach(ColorGrading.Region.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    ForEach(DevelopControl.grading(gradingRegion)) { control in slider(control, asset, settings) }
                    ForEach(DevelopControl.gradingShape) { control in slider(control, asset, settings) }
                }
                section(L("LUT"), accessory: {
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
                }) { lut(asset, settings) }
                section(L("细节")) {
                    ForEach(DevelopControl.detail) { control in slider(control, asset, settings) }
                    Text("锐化与降噪在 1:1 视图中看得最准")
                        .font(.system(size: 11)).foregroundStyle(Theme.text3)
                }
                section(L("镜头校正")) {
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
                section(L("效果")) {
                    ForEach(DevelopControl.effects) { control in slider(control, asset, settings) }
                }
                section(L("快照"), accessory: {
                    Button { app.createDevelopSnapshot(for: asset.id) } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("以当前设置新建快照")
                        .accessibilityLabel("新建快照")
                }) { snapshots(asset) }
                section(L("历史记录"), accessory: {
                    Button("清除") { app.confirmClearDevelopHistory(for: asset.id) }
                        .controlSize(.small)
                        .disabled(app.developHistory(for: asset.id).isEmpty)
                        .help("清除这张照片的历史记录（不改变当前设置）")
                }) { history(asset, settings) }
            }
            .padding(14)
        }
    }

    private func header(_ asset: Asset, settings: DevelopSettings) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DevelopHistogramView(histogram: app.developHistogram?.assetId == asset.id
                                 ? app.developHistogram?.histogram : nil)
            ExposureStrip(asset: asset)
            Text(asset.filename).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 8) {
                Toggle(isOn: Binding(get: { app.developShowsOriginal }, set: { app.developShowsOriginal = $0 })) {
                    Label("修改前", systemImage: "circle.righthalf.filled")
                }
                .toggleStyle(.button)
                .help("修改前 / 修改后 (\\)")
                Toggle(isOn: Binding(get: { app.developComparing }, set: { app.developComparing = $0 })) {
                    Label("对比", systemImage: "rectangle.split.2x1")
                }
                .toggleStyle(.button)
                .help("修改前与修改后并排 (Y)")
                Spacer(minLength: 0)
                Button("复位") { app.resetDevelop(asset) }
                .disabled(settings == app.defaultDevelopSettings(for: asset))
                .help("恢复为默认设置：相机的 RAW 默认设置，或原照设置")
            }
            .controlSize(.small)
            HStack(spacing: 8) {
                presetMenu
                Spacer(minLength: 0)
                Button("拷贝…") { app.showDevelopTransfer(.copy) }
                    .help("拷贝修图设置 (⇧⌘C)")
                Button("粘贴") { app.pasteDevelopSettings() }
                    .disabled(app.developClipboard == nil)
                    .help("粘贴修图设置 (⇧⌘V)")
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func whiteBalance(_ asset: Asset, _ settings: DevelopSettings) -> some View {
        if asset.isRaw {
            let asShot = app.developAsShot[asset.id]
            DevelopSlider(title: L("色温"), value: settings.temperature ?? asShot?.temperature ?? 5500,
                          range: 2000...12000, step: 50,
                          format: { String(format: "%.0f K", $0) },
                          isNeutral: settings.temperature == nil,
                          onChange: { draft(asset, settings) { $0.temperature = $1 }($0) },
                          onReset: { commit(asset, settings, L("色温")) { $0.temperature = nil } },
                          onCommit: { commitDraft(asset, L("色温")) })
            DevelopSlider(title: L("色调", table: "Context"), value: settings.tint ?? asShot?.tint ?? 0,
                          range: -150...150, step: 1,
                          format: { String(format: "%+.0f", $0) },
                          isNeutral: settings.tint == nil,
                          onChange: { draft(asset, settings) { $0.tint = $1 }($0) },
                          onReset: { commit(asset, settings, L("色调", table: "Context")) { $0.tint = nil } },
                          onCommit: { commitDraft(asset, L("色调", table: "Context")) })
            if settings.temperature != nil || settings.tint != nil {
                Button("原照设置") {
                    commit(asset, settings, L("白平衡")) { $0.temperature = nil; $0.tint = nil }
                }
                .controlSize(.small)
            }
        } else {
            DevelopSlider(title: L("色温"), value: settings.temperature ?? 0, range: -100...100, step: 1,
                          format: { $0 == 0 ? "0" : String(format: "%+.0f", $0) },
                          isNeutral: (settings.temperature ?? 0) == 0,
                          onChange: { draft(asset, settings) { $0.temperature = $1 }($0) },
                          onReset: { commit(asset, settings, L("色温")) { $0.temperature = nil } },
                          onCommit: { commitDraft(asset, L("色温")) })
            DevelopSlider(title: L("色调", table: "Context"), value: settings.tint ?? 0, range: -100...100, step: 1,
                          format: { $0 == 0 ? "0" : String(format: "%+.0f", $0) },
                          isNeutral: (settings.tint ?? 0) == 0,
                          onChange: { draft(asset, settings) { $0.tint = $1 }($0) },
                          onReset: { commit(asset, settings, L("色调", table: "Context")) { $0.tint = nil } },
                          onCommit: { commitDraft(asset, L("色调", table: "Context")) })
        }
    }

    /// The chosen region's tint, so the hue slider's number reads as a color.
    private func gradingSwatch(_ settings: DevelopSettings) -> some View {
        let controls = DevelopControl.grading(gradingRegion)   // hue, saturation, luminance
        let hue = settings[keyPath: controls[0].id], saturation = settings[keyPath: controls[1].id]
        return Circle()
            .fill(Color(hue: hue / 360, saturation: max(0.15, saturation / 100), brightness: 0.95))
            .frame(width: 12, height: 12)
            .overlay(Circle().strokeBorder(Theme.line2, lineWidth: 1))
            .accessibilityHidden(true)
    }

    private var presetMenu: some View {
        Menu {
            Section("内置") {
                ForEach(DevelopPreset.builtIns) { preset in
                    Button(preset.name) { app.applyDevelopPreset(preset) }
                }
            }
            if !app.developPresets.isEmpty {
                Section("我的预设") {
                    ForEach(app.developPresets) { preset in
                        Button(preset.name) { app.applyDevelopPreset(preset) }
                    }
                }
            }
            Divider()
            Button("存储为预设…") { app.showDevelopTransfer(.preset) }
            Button("导入预设…") { app.chooseAndImportDevelopPresets() }
            if !app.developPresets.isEmpty {
                Menu("删除预设") {
                    ForEach(app.developPresets) { preset in
                        Button(preset.name, role: .destructive) { app.confirmDeleteDevelopPreset(preset.id) }
                    }
                }
            }
        } label: {
            Label("预设", systemImage: "wand.and.stars")
        }
        .fixedSize()
        .help("应用或存储修图预设")
    }

    @ViewBuilder
    private func geometry(_ asset: Asset, _ settings: DevelopSettings) -> some View {
        HStack(spacing: 6) {
            Toggle(isOn: Binding(get: { app.developCropping }, set: { app.developCropping = $0 })) {
                Label("裁剪", systemImage: "crop")
            }
            .toggleStyle(.button)
            .help("裁剪与拉直 (R)")
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
                                                set: { applyAspect($0, asset, settings) })) {
                    ForEach(CropAspect.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                Button { swapCropOrientation(asset, settings) } label: {
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
                      onChange: { straightenDraft(asset, $0) },
                      onReset: { commitStraighten(asset, 0) },
                      onCommit: { commitDraft(asset, L("角度")) })
        HStack(spacing: 8) {
            Button("自动拉直") { app.autoStraighten(asset) }
                .help("按画面中的地平线自动拉直")
            Spacer(minLength: 0)
            Button("复位裁剪") {
                var next = app.developSettings[asset.id] ?? .neutral
                next.crop = nil
                next.straighten = 0
                app.commitDevelop([asset.id: next], undoName: L("复位裁剪"))
            }
            .disabled(settings.crop == nil && settings.straighten == 0)
        }
        .controlSize(.small)
    }

    // ---- snapshots and history ----
    @ViewBuilder
    private func snapshots(_ asset: Asset) -> some View {
        let snapshots = app.developSnapshots(for: asset.id)
        if snapshots.isEmpty {
            Text("快照保存照片此刻的修图设置，之后随时可以回到这个状态")
                .font(.system(size: 11)).foregroundStyle(Theme.text3)
        }
        ForEach(snapshots) { snapshot in
            if renamingSnapshot == snapshot.id {
                TextField("快照名称", text: $snapshotName)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focused($snapshotNameFocused)
                    .onAppear { snapshotNameFocused = true }
                    .onSubmit {
                        app.renameDevelopSnapshot(snapshot.id, to: snapshotName, for: asset.id)
                        renamingSnapshot = nil
                    }
                    .onExitCommand { renamingSnapshot = nil }
            } else {
                recordRow(snapshot.name, detail: Self.recordTime(snapshot.date),
                          current: snapshot.settings == app.developSettings(for: asset.id)) {
                    app.applyDevelopSnapshot(snapshot, to: asset.id)
                }
                .contextMenu {
                    Button("重命名…") { snapshotName = snapshot.name; renamingSnapshot = snapshot.id }
                    Button("用当前设置更新") { app.updateDevelopSnapshot(snapshot.id, for: asset.id) }
                    Divider()
                    Button("删除快照", role: .destructive) { app.deleteDevelopSnapshot(snapshot.id, for: asset.id) }
                }
            }
        }
    }

    @ViewBuilder
    private func history(_ asset: Asset, _ settings: DevelopSettings) -> some View {
        let steps = app.developHistory(for: asset.id).reversed()
        let shown = showsFullHistory ? Array(steps) : Array(steps.prefix(12))
        // the newest step that matches the photo now is where it stands (compared as stored text)
        let current = DevelopHistoryStep.json(settings)
        let currentSeq = steps.first { $0.json == current }?.seq
        ForEach(shown) { step in
            recordRow(step.name, detail: Self.recordTime(step.date), current: step.seq == currentSeq) {
                app.applyDevelopHistoryStep(step, to: asset.id)
            }
        }
        if steps.count > shown.count || showsFullHistory && steps.count > 12 {
            Button(showsFullHistory ? L("只显示最近的步骤") : L("显示全部 \(steps.count) 步")) { showsFullHistory.toggle() }
                .buttonStyle(.link)
                .controlSize(.small)
        }
        recordRow(L("原照设置"), detail: "", current: settings.isNeutral && currentSeq == nil) {
            app.commitDevelop([asset.id: .neutral], undoName: L("历史记录：原照设置"))
        }
    }

    private func recordRow(_ title: String, detail: String, current: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text(detail).font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.text3)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(current ? Theme.accentFill.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(current ? .isSelected : [])
    }

    /// Time of day for today's records, the date for older ones.
    private static func recordTime(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .numeric, time: .omitted)
    }

    // ---- spot removal: specks healed or cloned over ----
    @ViewBuilder
    private func spots(_ asset: Asset, _ settings: DevelopSettings) -> some View {
        HStack(spacing: 6) {
            Toggle(isOn: Binding(get: { app.developSpotting }, set: { _ in app.toggleSpotTool() })) {
                Label("污点去除", systemImage: "bandage")
            }
            .toggleStyle(.button)
            .help("点按照片上的污点修复 (Q)")
            Spacer(minLength: 0)
            if !settings.spots.isEmpty {
                Text("\(settings.spots.count) 处").font(.system(size: 11)).foregroundStyle(Theme.text3)
                Button("全部清除") {
                    var next = app.developSettings[asset.id] ?? .neutral
                    next.spots = []
                    app.commitDevelop([asset.id: next], undoName: L("清除污点去除"))
                }
            }
        }
        .controlSize(.small)
        if app.developSpotting {
            let index = settings.spots.firstIndex { $0.id == app.developSelectedSpotId }
            Picker("污点模式", selection: Binding(
                get: { index.map { settings.spots[$0].mode } ?? app.developSpotBrush.mode },
                set: { mode in
                    app.developSpotBrush.mode = mode
                    // heal and clone trade places; a remove spot is made by painting, not by switching
                    guard let index, mode != .remove, settings.spots[index].mode != .remove else {
                        if mode == .remove || index.map({ settings.spots[$0].mode == .remove }) == true {
                            app.developSelectedSpotId = nil
                        }
                        return
                    }
                    var next = app.developSettings[asset.id] ?? .neutral
                    guard next.spots.indices.contains(index) else { return }
                    next.spots[index].mode = mode
                    app.commitDevelop([asset.id: next], undoName: L("污点模式"))
                })) {
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

    // ---- masks: gradients with their own adjustments ----
    @ViewBuilder
    private func masks(_ asset: Asset, _ settings: DevelopSettings) -> some View {
        HStack(spacing: 6) {
            ForEach(LocalAdjustment.Kind.drawn, id: \.self) { kind in
                Toggle(isOn: Binding(get: { app.developMaskCreation == kind }, set: { _ in app.armMask(kind) })) {
                    Label(kind.title, systemImage: kind.symbol)
                }
                .toggleStyle(.button)
                .help(Self.maskHelp(kind))
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        HStack(spacing: 6) {
            ForEach(LocalAdjustment.Kind.automatic, id: \.self) { kind in
                Button { app.addAutomaticMask(kind) } label: {
                    Label(kind == .subject ? L("选择主体") : L("选择天空"), systemImage: kind.symbol)
                }
                .disabled(app.developDetectingMask != nil)
                .help(Self.maskHelp(kind))
            }
            Menu {
                ForEach(PersonPart.allCases, id: \.self) { part in
                    Button(part.title) { app.addPeopleMask(part) }
                }
            } label: {
                Label("选择人物", systemImage: LocalAdjustment.Kind.person.symbol)
            }
            .fixedSize()
            .disabled(app.developDetectingMask != nil)
            .help("找出照片中的人物，为整个人物或面部皮肤、眼睛、嘴唇等部位建立蒙版")
            if app.developDetectingMask != nil { ProgressView().controlSize(.small) }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        HStack(spacing: 6) {
            ForEach(LocalAdjustment.Kind.ranges, id: \.self) { kind in
                Button { app.addRangeMask(kind) } label: { Label(kind.title, systemImage: kind.symbol) }
                    .help(Self.maskHelp(kind))
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        if settings.masks.isEmpty {
            Text("用渐变、画笔或自动选择只调整照片的一部分，例如压暗天空或提亮主体")
                .font(.system(size: 11)).foregroundStyle(Theme.text3)
        } else {
            VStack(spacing: 2) {
                ForEach(settings.masks) { mask in maskRow(mask, in: settings.masks) }
            }
            Toggle("显示叠加", isOn: Binding(get: { app.developShowsMaskOverlay },
                                         set: { app.developShowsMaskOverlay = $0 }))
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .help("用红色标出所选蒙版覆盖的范围 (O)")
        }
        // the selected mask's controls belong to the open tool, where Delete removes the mask
        if app.developMasking, let index = settings.masks.firstIndex(where: { $0.id == app.developSelectedMaskId }) {
            let mask = settings.masks[index]
            Toggle("反相", isOn: Binding(get: { mask.inverted }, set: { inverted in
                var next = app.developSettings[asset.id] ?? .neutral
                guard next.masks.indices.contains(index) else { return }
                next.masks[index].inverted = inverted
                app.commitDevelop([asset.id: next], undoName: L("反相蒙版"))
            }))
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .help("让调整作用于渐变之外")
            if mask.kind == .radial { slider(DevelopControl.localFeather(index), asset, settings) }
            if mask.kind == .person { peopleControls(mask, asset) }
            rangeControls(mask, asset)
            if mask.kind == .brush {
                brushControls
            } else if !mask.kind.isRange {
                HStack(spacing: 8) {
                    Toggle("用画笔增减", isOn: Binding(get: { app.developRefiningMask },
                                                   set: { app.developRefiningMask = $0 }))
                        .toggleStyle(.checkbox)
                        .help("在照片上涂抹扩大这个蒙版，按住 ⌥ 或选“擦除”从中去掉")
                    Spacer(minLength: 0)
                    if !mask.strokes.isEmpty {
                        Button("清除修整") {
                            var next = app.developSettings[asset.id] ?? .neutral
                            guard next.masks.indices.contains(index) else { return }
                            next.masks[index].strokes = []
                            app.commitDevelop([asset.id: next], undoName: L("清除蒙版修整"))
                        }
                    }
                }
                .controlSize(.small)
                if app.developRefiningMask { brushControls }
            }
            ForEach(DevelopControl.local(index)) { control in slider(control, asset, settings) }
            HStack(spacing: 8) {
                Button("复位滑块") {
                    var next = app.developSettings[asset.id] ?? .neutral
                    guard next.masks.indices.contains(index) else { return }
                    next.masks[index] = mask.withoutAdjustments
                    app.commitDevelop([asset.id: next], undoName: L("复位蒙版调整"))
                }
                .disabled(!mask.hasEffect)
                Spacer(minLength: 0)
                Button("删除蒙版", role: .destructive) { app.deleteMask(mask.id, from: asset.id) }
                    .help("删除所选蒙版 (Delete)")
            }
            .controlSize(.small)
        }
    }

    /// A people mask's part, and whose it is when the photo shows more than one person.
    @ViewBuilder
    private func peopleControls(_ mask: LocalAdjustment, _ asset: Asset) -> some View {
        Picker("部位", selection: Binding(get: { mask.part }, set: { part in
            app.setPeopleMask(mask.id, part: part, person: mask.person)
        })) {
            ForEach(PersonPart.allCases, id: \.self) { part in Text(part.title).tag(part) }
        }
        .controlSize(.small)
        let count = app.developPeopleCounts[asset.id] ?? 0
        if count > 1 {
            Picker("人物", selection: Binding(get: { mask.person ?? -1 }, set: { person in
                app.setPeopleMask(mask.id, part: mask.part, person: person < 0 ? nil : person)
            })) {
                Text("所有人").tag(-1)
                ForEach(0..<count, id: \.self) { person in Text("人物 \(person + 1)").tag(person) }
            }
            .controlSize(.small)
            .help("人物按从左到右的顺序编号")
        }
        Color.clear.frame(height: 0).task(id: asset.id) { app.loadPeopleCount(for: asset) }
    }

    private static func maskHelp(_ kind: LocalAdjustment.Kind) -> String {
        switch kind {
        case .linear: L("新建线性渐变，在照片上拖动绘制 (M)")
        case .radial: L("新建径向渐变，在照片上拖动绘制 (⇧M)")
        case .brush: L("新建画笔蒙版，在照片上涂抹 (K)")
        case .subject: L("自动找出照片的主体（人物、动物或物体）并建立蒙版")
        case .sky: L("自动找出照片中的天空并建立蒙版")
        case .person: L("找出照片中的人物，为整个人物或面部皮肤、眼睛、嘴唇等部位建立蒙版")
        case .colorRange: L("选中照片中某些颜色的部分，在照片上点按取样")
        case .luminanceRange: L("选中照片中某个明暗范围的部分")
        }
    }

    /// A mask's tone or color range: for a range mask, what it is; for the others, what
    /// narrows them.
    @ViewBuilder
    private func rangeControls(_ mask: LocalAdjustment, _ asset: Asset) -> some View {
        if !mask.kind.isRange {
            Picker("范围", selection: Binding(get: { mask.range?.kind }, set: { kind in
                app.setMaskRange(kind, maskId: mask.id, assetId: asset.id)
            })) {
                Text("整个蒙版").tag(MaskRange.Kind?.none)
                Text("明亮度范围").tag(MaskRange.Kind?.some(.luminance))
                Text("颜色范围").tag(MaskRange.Kind?.some(.color))
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .help("只在一定明暗或颜色范围内应用这个蒙版")
        }
        if let range = mask.range {
            switch range.kind {
            case .luminance:
                rangeSlider(L("范围下限"), range.low, mask, asset) { $0.low = min($1, $0.high) }
                rangeSlider(L("范围上限"), range.high, mask, asset) { $0.high = max($1, $0.low) }
                rangeSlider(L("平滑度"), range.smoothness, mask, asset) { $0.smoothness = $1 }
            case .color:
                HStack(spacing: 8) {
                    Toggle(isOn: Binding(get: { app.developPickingRangeColor }, set: { app.developPickingRangeColor = $0 })) {
                        Label("取样", systemImage: "eyedropper")
                    }
                    .toggleStyle(.button)
                    .help("在照片上点按，选取要包含的颜色（最多 5 处）")
                    Text(range.samples.isEmpty ? L("尚未取样") : L("已取样 \(range.samples.count) 处"))
                        .font(.system(size: 11)).foregroundStyle(Theme.text3)
                    Spacer(minLength: 0)
                    if !range.samples.isEmpty {
                        Button("清除取样") {
                            app.changeMaskRange(maskId: mask.id, assetId: asset.id, commit: true,
                                                undoName: L("清除颜色取样")) { $0.samples = [] }
                        }
                    }
                }
                .controlSize(.small)
                rangeSlider(L("数量"), range.amount, mask, asset) { $0.amount = $1 }
            }
        }
    }

    private func rangeSlider(_ title: String, _ value: Double, _ mask: LocalAdjustment, _ asset: Asset,
                             _ set: @escaping (inout MaskRange, Double) -> Void) -> some View {
        DevelopSlider(title: title, value: value, range: 0...100, step: 1, format: { String(format: "%.0f", $0) },
                      isNeutral: false,
                      onChange: { new in
                          app.changeMaskRange(maskId: mask.id, assetId: asset.id, commit: false, undoName: title) { set(&$0, new) }
                      },
                      onReset: {},
                      onCommit: { commitDraft(asset, title) })
    }

    /// The brush's settings for new strokes: tool settings, not part of the photo's edit.
    @ViewBuilder
    private var brushControls: some View {
        Picker("画笔模式", selection: Binding(get: { app.developBrush.erase }, set: { app.developBrush.erase = $0 })) {
            Text("画笔").tag(false)
            Text("擦除").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .help("按住 ⌥ 临时切换画笔与擦除")
        DevelopSlider(title: L("大小"), value: app.developBrush.size, range: 1...100, step: 1,
                      format: { String(format: "%.0f", $0) }, isNeutral: app.developBrush.size == 25,
                      onChange: { app.developBrush.size = $0 }, onReset: { app.developBrush.size = 25 }, onCommit: {})
        DevelopSlider(title: L("画笔羽化"), value: app.developBrush.feather, range: 0...100, step: 1,
                      format: { String(format: "%.0f", $0) }, isNeutral: app.developBrush.feather == 50,
                      onChange: { app.developBrush.feather = $0 }, onReset: { app.developBrush.feather = 50 }, onCommit: {})
        DevelopSlider(title: L("密度"), value: app.developBrush.density, range: 1...100, step: 1,
                      format: { String(format: "%.0f", $0) }, isNeutral: app.developBrush.density == 100,
                      onChange: { app.developBrush.density = $0 }, onReset: { app.developBrush.density = 100 }, onCommit: {})
    }

    private func maskRow(_ mask: LocalAdjustment, in masks: [LocalAdjustment]) -> some View {
        let selected = mask.id == app.developSelectedMaskId
        let ordinal = masks.filter { $0.title == mask.title }.firstIndex { $0.id == mask.id }.map { $0 + 1 } ?? 1
        return Button {
            app.developSelectedMaskId = mask.id
            app.developMasking = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: mask.kind.symbol).frame(width: 16)
                Text("\(mask.title) \(ordinal)").lineLimit(1)
                Spacer(minLength: 4)
                if !mask.hasEffect {
                    Text("无调整").font(.system(size: 11)).foregroundStyle(Theme.text3)
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.accentFill.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // ---- LUT: a creative look from the library ----
    @ViewBuilder
    private func lut(_ asset: Asset, _ settings: DevelopSettings) -> some View {
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
    private func transform(_ asset: Asset, _ settings: DevelopSettings) -> some View {
        HStack(spacing: 6) {
            Button("自动") { app.autoUpright(asset, mode: .auto) }
                .help("让竖直线条竖直，水平线条也尽量平行")
            Button("垂直") { app.autoUpright(asset, mode: .vertical) }
                .help("只让竖直线条竖直、平行")
            Spacer(minLength: 0)
            Button("复位变换") {
                var next = app.developSettings[asset.id] ?? .neutral
                next.perspectiveVertical = 0
                next.perspectiveHorizontal = 0
                app.commitDevelop([asset.id: next], undoName: L("复位变换"))
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
                          onReset: { commit(asset, settings, control.title) { $0[keyPath: control.id] = control.neutral } },
                          onCommit: { commitDraft(asset, control.title) })
        }
    }

    // ---- crop: fractions of the rotated frame, kept inside the straightened photo ----
    private func straightenDraft(_ asset: Asset, _ angle: Double) {
        // shrink from the saved crop, so dragging back toward level grows it again
        var next = app.developSettings[asset.id] ?? .neutral
        let frame = app.developFrame(for: asset, settings: next)
        next.straighten = angle
        next.crop = DevelopGeometry.refit(next, frame: frame)
        app.updateDevelopDraft(next, for: asset.id)
    }

    private func commitStraighten(_ asset: Asset, _ angle: Double) {
        straightenDraft(asset, angle)
        commitDraft(asset, L("角度"))
    }

    /// Picks a crop shape and reshapes the crop to the largest of it around the same center.
    private func applyAspect(_ aspect: CropAspect, _ asset: Asset, _ settings: DevelopSettings) {
        app.developCropAspect = aspect
        let frame = app.developFrame(for: asset, settings: settings)
        guard let ratio = aspect.ratio(frame: frame) else { return }
        let current = DevelopGeometry.effectiveCrop(settings, frame: frame)
        let landscape = current.width * frame.width >= current.height * frame.height
        reshapeCrop(asset, aspect: landscape ? ratio : 1 / ratio, around: current, frame: frame, undoName: L("裁剪比例"))
    }

    private func swapCropOrientation(_ asset: Asset, _ settings: DevelopSettings) {
        let frame = app.developFrame(for: asset, settings: settings)
        let current = DevelopGeometry.effectiveCrop(settings, frame: frame)
        let aspect = current.height * frame.height / max(current.width * frame.width, 1e-9)
        reshapeCrop(asset, aspect: aspect, around: current, frame: frame, undoName: L("切换裁剪框横竖"))
    }

    private func reshapeCrop(_ asset: Asset, aspect: Double, around current: DevelopCrop, frame: CGSize,
                             undoName: String) {
        var next = app.developSettings[asset.id] ?? .neutral
        let perspective = DevelopGeometry.perspective(next, frame: frame)
        let largest = DevelopGeometry.inscribed(aspect: aspect, angle: next.straighten, perspective: perspective,
                                                frame: frame)
        let crop = DevelopGeometry.move(largest, dx: current.midX - largest.midX, dy: current.midY - largest.midY,
                                        angle: next.straighten, perspective: perspective, frame: frame)
        // the whole photo's own shape is what "no crop" already means
        let isWhole = crop == DevelopGeometry.inscribed(aspect: frame.width / max(frame.height, 1),
                                                        angle: next.straighten, perspective: perspective, frame: frame)
        next.crop = isWhole ? nil : crop
        app.commitDevelop([asset.id: next], undoName: undoName)
    }

    private func slider(_ control: DevelopControl, _ asset: Asset, _ settings: DevelopSettings) -> some View {
        DevelopSlider(title: control.title, value: settings[keyPath: control.id], range: control.range,
                      step: control.step, format: control.format,
                      isNeutral: settings[keyPath: control.id] == control.neutral,
                      onChange: { draft(asset, settings) { $0[keyPath: control.id] = $1 }($0) },
                      onReset: { commit(asset, settings, control.title) { $0[keyPath: control.id] = control.neutral } },
                      onCommit: { commitDraft(asset, control.title) })
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        section(title, accessory: { EmptyView() }, content: content)
    }

    /// A panel section; `accessory` sits at the end of the title row, as Lightroom's Auto does.
    private func section<Accessory: View, Content: View>(_ title: String, @ViewBuilder accessory: () -> Accessory,
                                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text2)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                accessory()
            }
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
        app.commitDevelop([asset.id: draft.settings], undoName: L("调整\(title)"))
    }

    private func commit(_ asset: Asset, _ settings: DevelopSettings, _ title: String,
                        _ apply: (inout DevelopSettings) -> Void) {
        var next = app.developSettings[asset.id] ?? .neutral
        apply(&next)
        app.commitDevelop([asset.id: next], undoName: L("复位\(title)"))
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

/// RGB histogram of the current render, drawn additively so overlapping channels read as
/// white, with Lightroom-style clipping triangles in the top corners.
private struct DevelopHistogramView: View {
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
