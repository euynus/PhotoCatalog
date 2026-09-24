// ============================================================
//  Smart album rule builder — port of SmartAlbumBuilder()
// ============================================================
import SwiftUI

struct SmartAlbumBuilder: View {
    @Environment(AppState.self) var app

    private let album: SmartAlbum?
    @State private var name: String
    @State private var match: String
    @State private var conditions: [SmartCondition]

    init(album: SmartAlbum? = nil) {
        self.album = album
        _name = State(initialValue: album?.name ?? "五星精选 · 旅行")
        _match = State(initialValue: album?.rule.match ?? "all")
        _conditions = State(initialValue: album?.rule.conditions ?? [
            SmartCondition(field: "rating", op: ">=", value: "4"),
            SmartCondition(field: "keywords", op: "包含", value: "旅行"),
        ])
    }

    private var rule: SmartRule { SmartRule(match: match, conditions: conditions) }
    // exclude trashed assets so the preview count matches the sidebar/grid (all other
    // SmartMatcher call sites filter !deleted)
    private var matched: [Asset] { SmartMatcher.match(app.assets.filter { !$0.deleted }, rule) }

    var body: some View {
        // one match pass per render — the preview count, empty state, thumbs
        // and save button all share it, and it re-runs on every keystroke
        let matched = self.matched
        VStack(spacing: 0) {
            head
            body_(matched)
            foot(matchedCount: matched.count)
        }
        .frame(width: 620)
        .font(.system(size: 13))
        .foregroundStyle(Theme.text)
        .background(Theme.bgPanel)
    }

    private var head: some View {
        HStack {
            HStack(spacing: 9) {
                Icon("sparkles", size: 17).foregroundStyle(Theme.accent)
                Text(album == nil ? "智能相册" : "编辑智能相册")
                    .font(.system(size: 17, weight: .semibold))
            }
            Spacer()
            sheetClose { app.dismissSmartAlbumBuilder() }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func body_(_ matched: [Asset]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("名称").foregroundStyle(Theme.text2).frame(width: 40, alignment: .leading)
                TextField("名称", text: $name)
                    .textFieldStyle(.plain).font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Theme.surface)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line2, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack(spacing: 9) {
                Text("规则").font(.system(size: 15, weight: .semibold))
                Spacer()
                Segmented(options: [
                    SegOption(value: "all", label: "全部 (AND)"),
                    SegOption(value: "any", label: "任一 (OR)"),
                ], value: match, onChange: { match = $0 })
                Button { conditions.append(SmartCondition(field: "camera", op: "包含", value: "")) } label: {
                    Label("添加条件", systemImage: "plus")
                        .labelStyle(.iconOnly)
                        .frame(width: 30, height: 30)
                        .foregroundStyle(Theme.accent)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
                }
                .buttonStyle(.plain)
                .help("添加条件")
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(conditions.enumerated()), id: \.element.id) { i, _ in
                        conditionRow(i)
                            .frame(height: 32)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: min(160, CGFloat(conditions.count) * 40))

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("预览").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text("\(matched.count) 张照片符合规则")
                        .monospacedDigit().foregroundStyle(Theme.text2)
                }
                if matched.isEmpty {
                    Text("没有照片符合当前规则")
                        .foregroundStyle(Theme.canvasText3)
                        .frame(maxWidth: .infinity, minHeight: 104)
                        .background(Theme.canvas)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                        ForEach(matched.prefix(14)) { a in
                            Thumb(asset: a, radius: 2, contentMode: .fit, maxDecodePixel: 160)
                                .frame(height: 40)
                                .help(a.filename)
                        }
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
                    .background(Theme.canvas)
                }
            }
            .padding(.top, 12)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        }
        .padding(18)
    }

    private func conditionRow(_ i: Int) -> some View {
        let field = SmartFields.field(conditions[i].field)
        return HStack(spacing: 7) {
            SASelect(value: conditions[i].field,
                     options: SmartFields.all.map { ($0.key, $0.label) }, width: 110) { newField in
                updateField(i, newField)
            }
            SASelect(value: conditions[i].op, options: field.ops.map { ($0, $0) }, width: 78) {
                conditions[i].op = $0
            }
            valueControl(i, field)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { conditions.remove(at: i) } label: {
                Icon("minus", size: 14, weight: .bold).foregroundStyle(Theme.text3)
                    .frame(width: 30, height: 30).background(Theme.surface)
                    .overlay(RoundedRectangle(cornerRadius: Theme.rSm).strokeBorder(Theme.line2, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.rSm))
            }
            .buttonStyle(.plain)
            .disabled(conditions.count == 1)
            .opacity(conditions.count == 1 ? 0.3 : 1)
            .help("移除条件")
            .accessibilityLabel("移除条件")
        }
    }

    private func updateField(_ i: Int, _ newField: String) {
        let conf = SmartFields.field(newField)
        conditions[i].field = newField
        conditions[i].op = conf.ops[0]
        switch conf.input {
        case .rating: conditions[i].value = "4"
        case .flag: conditions[i].value = "pick"
        case .type: conditions[i].value = "RAW"
        case .status: conditions[i].value = "ready"
        case .datePreset: conditions[i].value = "thisYear"
        case .date: conditions[i].value = CaptureDates.key(.now)
        case .gps: conditions[i].value = "yes"
        case .year: conditions[i].value = "2026"
        case .color: conditions[i].value = "red"
        case .text: conditions[i].value = ""
        }
    }

    @ViewBuilder
    private func valueControl(_ i: Int, _ field: SmartField) -> some View {
        switch field.input {
        case .rating:
            SASelect(value: conditions[i].value, options: (0...5).map { ("\($0)", "\($0) 星") }) { conditions[i].value = $0 }
        case .flag:
            SASelect(value: conditions[i].value, options: [("pick", "精选"), ("reject", "拒绝"), ("none", "无")]) { conditions[i].value = $0 }
        case .color:
            SASelect(value: conditions[i].value, options: [("", "无")] + ColorLabel.allCases.map { ($0.rawValue, $0.name) }) { conditions[i].value = $0 }
        case .type:
            SASelect(value: conditions[i].value, options: ["RAW", "HEIC", "ARW", "CR3", "NEF", "RAF", "DNG"].map { ($0, $0) }) { conditions[i].value = $0 }
        case .status:
            SASelect(value: conditions[i].value, options: [("ready", "可访问"), ("offline", "离线"), ("missing", "缺失")]) { conditions[i].value = $0 }
        case .datePreset:
            SASelect(value: conditions[i].value, options: CaptureDates.presets) { conditions[i].value = $0 }
        case .date:
            DatePicker("拍摄日期", selection: Binding(
                get: { CaptureDates.interval(for: conditions[i].value)?.start ?? .now },
                set: { conditions[i].value = CaptureDates.key($0) }
            ), displayedComponents: .date)
            .labelsHidden()
            .environment(\.calendar, Calendar.captureWallClock)
            .environment(\.timeZone, TimeZone.captureWallClock)
        case .gps:
            SASelect(value: conditions[i].value, options: [("yes", "有 GPS"), ("no", "无 GPS")]) { conditions[i].value = $0 }
        case .year:
            TextField("", text: Binding(get: { conditions[i].value }, set: { conditions[i].value = $0 }))
                .textFieldStyle(.plain).font(.system(size: 13))
                .padding(.horizontal, 9).padding(.vertical, 7)
                .background(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line2, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        case .text:
            TextField("输入…", text: Binding(get: { conditions[i].value }, set: { conditions[i].value = $0 }))
                .textFieldStyle(.plain).font(.system(size: 13))
                .padding(.horizontal, 9).padding(.vertical, 7)
                .background(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line2, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func foot(matchedCount: Int) -> some View {
        HStack(spacing: 9) {
            Spacer()
            ghostButton(nil, "取消") { app.dismissSmartAlbumBuilder() }
            Button { app.saveSmart(name: name, rule: rule, count: matchedCount) } label: {
                Label(album == nil ? "创建智能相册" : "保存更改", systemImage: "checkmark")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.onAccent)
                    .fixedSize()
                    .padding(.horizontal, 17).padding(.vertical, 8)
                    .background(Theme.accent).clipShape(RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || conditions.isEmpty)
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(Theme.bgSidebar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

// styled select used inside the rule builder
struct SASelect: View {
    let value: String
    let options: [(String, String)]
    var width: CGFloat?
    let onChange: (String) -> Void

    private var label: String { options.first { $0.0 == value }?.1 ?? value }

    var body: some View {
        Menu {
            ForEach(options, id: \.0) { opt in
                Button(opt.1) { onChange(opt.0) }
            }
        } label: {
            HStack(spacing: 6) {
                Text(label).font(.system(size: 13)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 2)
                Icon("chevronD", size: 10).foregroundStyle(Theme.text3)
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .frame(width: width)
            .background(Theme.surface)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line2, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: width == nil, vertical: true)
    }
}
