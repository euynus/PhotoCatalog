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
    /// The last finished match and what it matched: the count and thumbnails stay up while the
    /// next one runs. Nil until the first one is in.
    @State private var shown: (input: PreviewInput, preview: SmartMatcher.Preview)?

    /// What a match depends on: the rule, and the photos (by their edit version). Not the name.
    private struct PreviewInput: Equatable {
        let rule: SmartRule
        let assets: Int
    }

    init(album: SmartAlbum? = nil) {
        self.album = album
        // a new album starts blank: no name, and one condition to fill in
        _name = State(initialValue: album?.name ?? "")
        _match = State(initialValue: album?.rule.match ?? "all")
        _conditions = State(initialValue: album?.rule.conditions ?? [
            SmartCondition(field: "keywords", op: "包含", value: ""),
        ])
    }

    /// A name, and a value in every text condition: an empty one would match nothing.
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !conditions.isEmpty
            && !conditions.contains {
                SmartFields.field($0.field).input == .text && $0.value.trimmingCharacters(in: .whitespaces).isEmpty
            }
    }

    private var rule: SmartRule { SmartRule(match: match, conditions: conditions) }

    var body: some View {
        // Matching a large library takes a while, so it runs off the main thread and never in
        // body: typing the name doesn't match at all, and typing a value matches once it pauses.
        let input = PreviewInput(rule: rule, assets: app.assetRenderVersion)
        VStack(spacing: 0) {
            head
            body_(shown?.preview, pending: shown?.input != input)
            foot
        }
        .frame(width: 620)
        .font(.system(size: 13))
        .foregroundStyle(Theme.text)
        .background(Theme.bgPanel)
        .task(id: input) { await refreshPreview(input) }
    }

    private func refreshPreview(_ input: PreviewInput) async {
        if shown != nil {
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
        }
        // trashed photos are left out, as the sidebar and grid leave them out
        let assets = app.assets
        let worker = Task.detached(priority: .userInitiated) {
            SmartMatcher.preview(assets, input.rule, limit: 14)
        }
        let preview = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard let preview, !Task.isCancelled else { return }
        shown = (input, preview)
    }

    private var head: some View {
        HStack {
            HStack(spacing: 9) {
                Icon("sparkles", size: 17).foregroundStyle(Theme.accent)
                Text(album == nil ? "智能相册" : "编辑智能相册")
                    .font(.system(size: 17, weight: .semibold))
            }
            Spacer()
        }
        .sheetHeaderBar()
    }

    private func body_(_ preview: SmartMatcher.Preview?, pending: Bool) -> some View {
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
                    SegOption(value: "all", label: L("满足全部条件")),
                    SegOption(value: "any", label: L("满足任一条件")),
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
                    if let preview {
                        // the last count stays, dimmed, until the new one is in
                        Text("\(preview.count) 张照片符合规则")
                            .monospacedDigit().foregroundStyle(Theme.text2)
                            .opacity(pending ? 0.5 : 1)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                if let preview, !preview.first.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                        ForEach(preview.first) { a in
                            Thumb(asset: a, radius: 2, contentMode: .fit, maxDecodePixel: 160)
                                .frame(height: 40)
                                .help(a.filename)
                        }
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
                    .background(Theme.canvas)
                    .opacity(pending ? 0.5 : 1)
                } else if preview != nil, !pending {
                    Text("没有照片符合当前规则")
                        .foregroundStyle(Theme.canvasText3)
                        .frame(maxWidth: .infinity, minHeight: 104)
                        .background(Theme.canvas)
                } else {
                    // no match yet isn't "no photos match": the rule is still being matched
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 104)
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
            SASelect(value: conditions[i].op, options: field.ops.map { ($0, SmartField.opLabel($0, field: field.key)) }, width: 96) {
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
            SASelect(value: conditions[i].value, options: (0...5).map { ("\($0)", L("\($0) 星")) }) { conditions[i].value = $0 }
        case .flag:
            SASelect(value: conditions[i].value, options: [("pick", L("精选", table: "Context")), ("reject", L("拒绝", table: "Context")), ("none", L("无"))]) { conditions[i].value = $0 }
        case .color:
            SASelect(value: conditions[i].value, options: [("", L("无"))] + ColorLabel.allCases.map { ($0.rawValue, $0.name) }) { conditions[i].value = $0 }
        case .type:
            SASelect(value: conditions[i].value, options: ["RAW", "HEIC", "ARW", "CR3", "NEF", "RAF", "DNG"].map { ($0, $0) } + [("VIDEO", L("视频"))]) { conditions[i].value = $0 }
        case .status:
            SASelect(value: conditions[i].value, options: [("ready", L("可访问")), ("offline", L("离线")), ("missing", L("缺失"))]) { conditions[i].value = $0 }
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
            SASelect(value: conditions[i].value, options: [("yes", L("有 GPS")), ("no", L("无 GPS"))]) { conditions[i].value = $0 }
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

    private var foot: some View {
        HStack(spacing: 9) {
            Spacer()
            ghostButton(nil, L("取消")) { app.dismissSmartAlbumBuilder() }
            // saving doesn't wait for a match: the sidebar counts the album itself
            Button { app.saveSmart(name: name, rule: rule, count: shown?.preview.count ?? 0) } label: {
                Label(album == nil ? "创建智能相册" : "保存更改", systemImage: "checkmark")
                    .fixedSize()
                    .sheetPrimaryLabel()
            }.buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.5)
        }
        .sheetFooterBar()
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
