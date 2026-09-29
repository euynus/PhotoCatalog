// ============================================================
//  Develop panel — Lightroom's Basic adjustments
// ============================================================
import SwiftUI

struct DevelopPanel: View {
    @Environment(AppState.self) private var app
    let asset: Asset?
    @State private var mixerProperty: ColorMixer.Property = .hue
    @State private var gradingRegion: ColorGrading.Region = .shadows

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
                section(L("裁剪与旋转")) { geometry(asset, settings) }
                section(L("蒙版")) { masks(asset, settings) }
                section(L("白平衡")) {
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
                section(L("细节")) {
                    ForEach(DevelopControl.detail) { control in slider(control, asset, settings) }
                    Text("锐化与降噪在 1:1 视图中看得最准")
                        .font(.system(size: 11)).foregroundStyle(Theme.text3)
                }
                section(L("镜头校正")) {
                    ForEach(DevelopControl.lens) { control in slider(control, asset, settings) }
                }
                section(L("效果")) {
                    ForEach(DevelopControl.effects) { control in slider(control, asset, settings) }
                }
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
                    Label("修改前", systemImage: "rectangle.split.2x1")
                }
                .toggleStyle(.button)
                .help("修改前 / 修改后 (\\)")
                Spacer(minLength: 0)
                Button("复位") {
                    app.commitDevelop([asset.id: .neutral], undoName: L("复位调整"))
                }
                .disabled(settings.isNeutral)
                .help("恢复为原照设置")
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
            if !app.developPresets.isEmpty {
                Menu("删除预设") {
                    ForEach(app.developPresets) { preset in
                        Button(preset.name, role: .destructive) { app.deleteDevelopPreset(preset.id) }
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
            if app.developDetectingMask != nil { ProgressView().controlSize(.small) }
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
        if let index = settings.masks.firstIndex(where: { $0.id == app.developSelectedMaskId }) {
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
            if mask.kind == .brush { brushControls }
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

    private static func maskHelp(_ kind: LocalAdjustment.Kind) -> String {
        switch kind {
        case .linear: L("新建线性渐变，在照片上拖动绘制 (M)")
        case .radial: L("新建径向渐变，在照片上拖动绘制 (⇧M)")
        case .brush: L("新建画笔蒙版，在照片上涂抹 (K)")
        case .subject: L("自动找出照片的主体（人物、动物或物体）并建立蒙版")
        case .sky: L("自动找出照片中的天空并建立蒙版")
        }
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
        let ordinal = masks.filter { $0.kind == mask.kind }.firstIndex { $0.id == mask.id }.map { $0 + 1 } ?? 1
        return Button {
            app.developSelectedMaskId = mask.id
            app.developMasking = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: mask.kind.symbol).frame(width: 16)
                Text("\(mask.kind.title) \(ordinal)").lineLimit(1)
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

    // ---- crop: fractions of the rotated frame, kept inside the straightened photo ----
    private func straightenDraft(_ asset: Asset, _ angle: Double) {
        // shrink from the saved crop, so dragging back toward level grows it again
        var next = app.developSettings[asset.id] ?? .neutral
        let frame = app.developFrame(for: asset, settings: next)
        next.straighten = angle
        next.crop = next.crop.map { DevelopGeometry.fit($0, angle: angle, frame: frame) }
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
        let largest = DevelopGeometry.inscribed(aspect: aspect, angle: next.straighten, frame: frame)
        let crop = DevelopGeometry.move(largest, dx: current.midX - largest.midX, dy: current.midY - largest.midY,
                                        angle: next.straighten, frame: frame)
        // the whole photo's own shape is what "no crop" already means
        let isWhole = crop == DevelopGeometry.inscribed(aspect: frame.width / max(frame.height, 1),
                                                        angle: next.straighten, frame: frame)
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
