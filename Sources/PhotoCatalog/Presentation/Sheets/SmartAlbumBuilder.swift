// ============================================================
//  Smart album rule builder — port of SmartAlbumBuilder()
// ============================================================
import SwiftUI

struct SmartAlbumBuilder: View {
    @EnvironmentObject var app: AppState

    @State private var name = "五星精选 · 旅行"
    @State private var match = "all"
    @State private var conditions: [SmartCondition] = [
        SmartCondition(field: "rating", op: ">=", value: "4"),
        SmartCondition(field: "keywords", op: "包含", value: "旅行"),
    ]

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
            ScrollView { body_(matched) }
            foot(matchedCount: matched.count)
        }
        .frame(width: 580)
        .background(Color(hex: "#232325"))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line2, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.7), radius: 60, y: 40)
    }

    private var head: some View {
        HStack {
            HStack(spacing: 9) {
                Icon("sparkles", size: 17).foregroundStyle(Theme.accent)
                Text("智能相册").font(.system(size: 14.5, weight: .semibold))
            }
            Spacer()
            sheetClose { app.sheet = nil }
        }
        .padding(.horizontal, 18).padding(.vertical, 15)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func body_(_ matched: [Asset]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // name
            HStack(spacing: 12) {
                Text("名称").font(.system(size: 12)).foregroundStyle(Theme.text3).frame(width: 40, alignment: .leading)
                TextField("", text: $name)
                    .textFieldStyle(.plain).font(.system(size: 13.5, weight: .medium))
                    .padding(.horizontal, 11).padding(.vertical, 9)
                    .background(Color.black.opacity(0.28))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line2, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }.padding(.bottom, 16)

            // match
            HStack(spacing: 9) {
                Text("满足以下").font(.system(size: 12.5)).foregroundStyle(Theme.text2)
                Segmented(options: [
                    SegOption(value: "all", label: "全部 (AND)"),
                    SegOption(value: "any", label: "任一 (OR)"),
                ], value: match, onChange: { match = $0 }, size: "sm")
                Text("条件：").font(.system(size: 12.5)).foregroundStyle(Theme.text2)
            }.padding(.bottom, 13)

            // conditions
            VStack(spacing: 8) {
                ForEach(Array(conditions.enumerated()), id: \.element.id) { i, _ in
                    conditionRow(i)
                }
                Button { conditions.append(SmartCondition(field: "camera", op: "包含", value: "")) } label: {
                    HStack(spacing: 6) { Icon("plus", size: 13, weight: .bold); Text("添加条件").font(.system(size: 12.5)) }
                        .foregroundStyle(Theme.accent).padding(.horizontal, 11).padding(.vertical, 7)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // preview
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 0) {
                    Text("\(matched.count)").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.accent)
                    Text(" 张照片符合规则").font(.system(size: 12.5)).foregroundStyle(Theme.text2)
                }
                if matched.isEmpty {
                    Text("没有照片符合当前规则").font(.system(size: 12)).foregroundStyle(Theme.text4).padding(.vertical, 14)
                } else {
                    FlowRow(spacing: 5, lineSpacing: 5) {
                        ForEach(matched.prefix(14)) { a in
                            Thumb(asset: a, radius: 3).frame(width: 60, height: 42)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
            }
            .padding(.top, 15)
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
                .frame(maxWidth: .infinity)
            Button { conditions.remove(at: i) } label: {
                Icon("minus", size: 14, weight: .bold).foregroundStyle(Theme.text3)
                    .frame(width: 30, height: 30).background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(conditions.count == 1)
            .opacity(conditions.count == 1 ? 0.3 : 1)
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
            SASelect(value: conditions[i].value, options: [("thisMonth", "本月"), ("thisYear", "今年")]) { conditions[i].value = $0 }
        case .gps:
            SASelect(value: conditions[i].value, options: [("yes", "有 GPS"), ("no", "无 GPS")]) { conditions[i].value = $0 }
        case .year:
            TextField("", text: Binding(get: { conditions[i].value }, set: { conditions[i].value = $0 }))
                .textFieldStyle(.plain).font(.system(size: 12.5))
                .padding(.horizontal, 9).padding(.vertical, 7)
                .background(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line2, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        case .text:
            TextField("输入…", text: Binding(get: { conditions[i].value }, set: { conditions[i].value = $0 }))
                .textFieldStyle(.plain).font(.system(size: 12.5))
                .padding(.horizontal, 9).padding(.vertical, 7)
                .background(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line2, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func foot(matchedCount: Int) -> some View {
        HStack(spacing: 9) {
            Text("动态集合 · 新导入照片若符合规则会自动加入")
                .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                .frame(maxWidth: .infinity, alignment: .leading)
            ghostButton(nil, "取消") { app.sheet = nil }
            Button { app.saveSmart(name: name, rule: rule, count: matchedCount) } label: {
                Text("创建智能相册").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 17).padding(.vertical, 8)
                    .background(Theme.accent).clipShape(RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
        .background(Color.black.opacity(0.18))
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
                Text(label).font(.system(size: 12.5)).foregroundStyle(Theme.text).lineLimit(1)
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
