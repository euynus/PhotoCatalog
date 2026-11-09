import SwiftUI
import AppKit

extension DevelopPanel {
    // ---- masks: gradients with their own adjustments ----
    @ViewBuilder
    func masks(_ asset: Asset, _ settings: DevelopSettings) -> some View {
        // the tool rows wrap rather than truncate (English labels are much longer)
        FlowRow {
            ForEach(LocalAdjustment.Kind.drawn, id: \.self) { kind in
                Toggle(isOn: Binding(get: { app.developMaskCreation == kind }, set: { _ in app.armMask(kind) })) {
                    Label(kind.title, systemImage: kind.symbol)
                }
                .toggleStyle(.button)
                .help(Self.maskHelp(kind))
            }
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        FlowRow {
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
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        FlowRow {
            Toggle(isOn: Binding(get: { app.developMaskCreation == .object }, set: { _ in app.armMask(.object) })) {
                Label("选择物体", systemImage: LocalAdjustment.Kind.object.symbol)
            }
            .toggleStyle(.button)
            .disabled(app.developDetectingMask != nil)
            .help(Self.maskHelp(.object))
            Menu {
                ForEach(LandscapeCategory.allCases, id: \.self) { category in
                    Button { app.addLandscapeMask(category) } label: { Label(category.title, systemImage: category.symbol) }
                }
            } label: {
                Label("选择景观", systemImage: LocalAdjustment.Kind.landscape.symbol)
            }
            .fixedSize()
            .disabled(app.developDetectingMask != nil)
            .help(Self.maskHelp(.landscape))
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        FlowRow {
            ForEach(LocalAdjustment.Kind.ranges, id: \.self) { kind in
                Button { app.addRangeMask(kind) } label: { Label(kind.title, systemImage: kind.symbol) }
                    .help(Self.maskHelp(kind))
            }
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                commitMask(asset, index, L("反相蒙版")) { $0.inverted = inverted }
            }))
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .help("让调整作用于渐变之外")
            if mask.kind == .radial { slider(DevelopControl.localFeather(index), asset, settings) }
            if mask.kind == .person { peopleControls(mask, asset) }
            if mask.kind == .landscape {
                Picker("类别", selection: Binding(get: { mask.landscape }, set: { app.setLandscapeMask(mask.id, category: $0) })) {
                    ForEach(LandscapeCategory.allCases, id: \.self) { category in Text(category.title).tag(category) }
                }
                .controlSize(.small)
            }
            if mask.kind == .object {
                Text("点按补上物体漏选的部分，按住 ⌥ 点按去掉多选的部分，拖动重新框选；要选另一个物体，再点“选择物体”")
                    .font(.system(size: 11)).foregroundStyle(Theme.text3)
            }
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
                            commitMask(asset, index, L("清除蒙版修整")) { $0.strokes = [] }
                        }
                    }
                }
                .controlSize(.small)
                if app.developRefiningMask { brushControls }
            }
            ForEach(DevelopControl.local(index)) { control in slider(control, asset, settings) }
            HStack(spacing: 8) {
                Button("复位滑块") {
                    commitMask(asset, index, L("复位蒙版调整")) { $0 = mask.withoutAdjustments }
                }
                .disabled(!mask.hasEffect)
                Spacer(minLength: 0)
                Button("删除蒙版", role: .destructive) { app.deleteMask(mask.id, from: asset.id) }
                    .help("删除所选蒙版 (Delete)")
            }
            .controlSize(.small)
        }
    }

    /// Changes the saved settings' mask at `index` as one undo step; nothing once it's gone.
    private func commitMask(_ asset: Asset, _ index: Int, _ undoName: String,
                            _ change: (inout LocalAdjustment) -> Void) {
        guard (app.developSettings[asset.id] ?? .neutral).masks.indices.contains(index) else { return }
        app.commitDevelop(asset.id, undoName: undoName) { change(&$0.masks[index]) }
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
        case .object: L("在照片上框选或点按一个物体，为它建立蒙版")
        case .landscape: L("找出照片中的水面、植被、山体、建筑或地面并建立蒙版")
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
}
