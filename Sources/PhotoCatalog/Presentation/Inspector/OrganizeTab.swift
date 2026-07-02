// ============================================================
//  Inspector — Organize tab (rating / flag / color / keywords / title / caption)
// ============================================================
import SwiftUI

struct OrganizeTab: View {
    @EnvironmentObject var app: AppState
    let asset: Asset

    private enum Field { case title, caption, project, client }
    @FocusState private var focusedField: Field?

    // Text edits are buffered locally and committed on focus loss / selection
    // change / disappear — every committed edit is a SQLite upsert + XMP
    // sidecar write + full list recompute, far too heavy to run per keystroke.
    private struct Drafts: Equatable {
        var title = "", caption = "", project = "", client = ""
    }
    @State private var drafts = Drafts()
    @State private var seeded = Drafts()
    /// Ids snapshotted when a field gains focus, so the commit can't land on
    /// a different photo the user clicked mid-edit.
    @State private var editTargets: Set<String> = []

    private var assetDrafts: Drafts {
        Drafts(title: asset.title, caption: asset.caption,
               project: asset.project, client: asset.client)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            // rating
            block("评分") {
                HStack(spacing: 12) {
                    StarsView(value: asset.rating, size: 22, gap: 3) { n in
                        app.setRating(asset.rating == n ? 0 : n)
                    }
                    if asset.rating > 0 {
                        Button { app.setRating(0) } label: {
                            Text("清除").font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                        }.buttonStyle(.plain)
                    }
                }
            }
            // flags
            block("旗标") {
                HStack(spacing: 7) {
                    FlagButton(flag: .pick, icon: "flag", label: "精选", on: asset.flag == .pick) {
                        app.setFlag(asset.flag == .pick ? .none : .pick)
                    }
                    FlagButton(flag: .reject, icon: "reject", label: "拒绝", on: asset.flag == .reject) {
                        app.setFlag(asset.flag == .reject ? .none : .reject)
                    }
                }
            }
            // color
            block("颜色标签") { ColorLabelPicker(value: asset.colorLabel) { app.setColor($0) } }
            // keywords
            block("关键词") {
                KeywordEditor(keywords: asset.keywords,
                              suggestions: app.keywordSuggestionPool,
                              onAdd: { app.addKeyword($0) }, onRemove: { app.removeKeyword($0) })
            }
            // title
            block("标题") {
                TextField("为这张照片添加标题…", text: $drafts.title)
                    .textFieldStyle(.plain).font(.system(size: 12.5))
                    .focused($focusedField, equals: .title)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Color.black.opacity(0.28))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .focusRing(focusedField == .title, radius: 6)
            }
            // caption
            block("说明") {
                ZStack(alignment: .topLeading) {
                    if drafts.caption.isEmpty {
                        Text("添加说明…").font(.system(size: 12.5)).foregroundStyle(Theme.text4)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                    }
                    TextEditor(text: $drafts.caption)
                        .font(.system(size: 12.5)).scrollContentBackground(.hidden)
                        .focused($focusedField, equals: .caption)
                        .frame(minHeight: 56)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                }
                .background(Color.black.opacity(0.28))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .focusRing(focusedField == .caption, radius: 6)
            }
            block("项目") {
                TextField("项目名称", text: $drafts.project)
                    .textFieldStyle(.plain).font(.system(size: 12.5))
                    .focused($focusedField, equals: .project)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Color.black.opacity(0.28))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .focusRing(focusedField == .project, radius: 6)
            }
            block("客户") {
                TextField("客户名称", text: $drafts.client)
                    .textFieldStyle(.plain).font(.system(size: 12.5))
                    .focused($focusedField, equals: .client)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Color.black.opacity(0.28))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .focusRing(focusedField == .client, radius: 6)
            }
        }
        .onChange(of: asset.id, initial: true) { commitDrafts(); seedDrafts() }
        .onChange(of: assetDrafts) {
            // adopt external changes, but never clobber an in-flight edit
            if focusedField == nil, drafts == seeded { seedDrafts() }
        }
        .onChange(of: focusedField) {
            if focusedField == nil {
                commitDrafts()
            } else if editTargets.isEmpty {
                editTargets = app.selectedIds.isEmpty ? [asset.id] : app.selectedIds
            }
        }
        .onDisappear { commitDrafts() }
    }

    private func seedDrafts() {
        drafts = assetDrafts
        seeded = drafts
        editTargets = []
    }

    private func commitDrafts() {
        defer { editTargets = []; seeded = drafts }
        guard !editTargets.isEmpty else { return }
        let project = drafts.project.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = drafts.client.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleChanged = drafts.title != seeded.title
        let captionChanged = drafts.caption != seeded.caption
        let projectChanged = project != seeded.project
        let clientChanged = client != seeded.client
        guard titleChanged || captionChanged || projectChanged || clientChanged else { return }
        let d = drafts
        app.mutate(editTargets) {
            if titleChanged { $0.title = d.title }
            if captionChanged { $0.caption = d.caption }
            if projectChanged { $0.project = project }
            if clientChanged { $0.client = client }
        }
    }

    private func block<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.system(size: 11, weight: .semibold)).tracking(0.3)
                .foregroundStyle(Theme.text3).textCase(.uppercase)
            content()
        }
    }

}

private struct FlagButton: View {
    let flag: Flag
    let icon: String
    let label: String
    let on: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let tint: Color = flag == .pick ? Theme.accent : Theme.redSoft
        let bg: Color = flag == .pick ? Theme.accentSoft : Theme.red.opacity(0.16)
        let borderTint: Color = flag == .pick ? Theme.accent : Theme.red
        Button(action: action) {
            HStack(spacing: 6) { Icon(icon, size: 15); Text(label).font(.system(size: 12.5)) }
                .frame(maxWidth: .infinity).frame(height: 32)
                .foregroundStyle(on ? tint : Theme.text2)
                .background(on ? bg : (hover ? Theme.surfaceHi : Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(on ? borderTint.opacity(0.4) : .clear, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain).onHover { hover = $0 }
    }
}

// ---------- Color picker ----------
struct ColorLabelPicker: View {
    let value: ColorLabel?
    let onPick: (ColorLabel?) -> Void

    /// Double ring (CSS: box-shadow 0 0 0 2px bg-panel, 0 0 0 4px <color>).
    @ViewBuilder private func ring(_ color: Color) -> some View {
        ZStack {
            Circle().strokeBorder(Theme.bgPanel, lineWidth: 2).padding(-2)
            Circle().strokeBorder(color, lineWidth: 2).padding(-4)
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Button { onPick(nil) } label: {
                Icon("close", size: 11, weight: .bold).foregroundStyle(Theme.text3)
                    .frame(width: 26, height: 26).background(Theme.surface).clipShape(Circle())
                    .overlay { if value == nil { ring(Theme.text3) } }
            }.buttonStyle(.plain).help("无")

            ForEach(ColorLabel.allCases) { c in
                Button { onPick(value == c ? nil : c) } label: {
                    Circle().fill(c.hex).frame(width: 26, height: 26)
                        .overlay { if value == c { ring(c.hex) } }
                }.buttonStyle(.plain).help(c.name)
            }
        }
    }
}

// ---------- Keyword editor ----------
struct KeywordEditor: View {
    let keywords: [String]
    let suggestions: [String]
    let onAdd: (String) -> Void
    let onRemove: (String) -> Void
    @State private var input = ""
    @FocusState private var focused: Bool

    private var filteredSuggestions: [String] {
        KeywordService.suggestions(for: input, pool: suggestions, excluding: keywords)
    }

    private func commit(_ k: String? = nil) {
        let v = (k ?? input).trimmingCharacters(in: .whitespaces)
        if !v.isEmpty { onAdd(v) }
        input = ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // tags
            if keywords.isEmpty {
                Text("尚无关键词").font(.system(size: 12)).foregroundStyle(Theme.text4)
            } else {
                FlowRow(spacing: 6) {
                    ForEach(keywords, id: \.self) { k in
                        HStack(spacing: 5) {
                            Text(k).font(.system(size: 12))
                            Button { onRemove(k) } label: {
                                Icon("close", size: 10, weight: .bold).foregroundStyle(Theme.text3)
                                    .frame(width: 15, height: 15)
                            }.buttonStyle(.plain)
                        }
                        .padding(.leading, 9).padding(.trailing, 5).padding(.vertical, 3)
                        .background(Theme.surface)
                        .overlay(Capsule().strokeBorder(Theme.line2, lineWidth: 1))
                        .clipShape(Capsule())
                    }
                }
            }
            // input
            HStack(spacing: 7) {
                Icon("tag", size: 13).foregroundStyle(Theme.text3)
                TextField("添加关键词…", text: $input)
                    .textFieldStyle(.plain).font(.system(size: 12.5))
                    .focused($focused)
                    .onSubmit { commit() }
            }
            .padding(.horizontal, 9).frame(height: 30)
            .background(Color.black.opacity(0.28))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .focusRing(focused, radius: 6)
            .overlay(alignment: .topLeading) {
                if focused && !filteredSuggestions.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(filteredSuggestions, id: \.self) { s in
                            KWSuggestion(text: s) { commit(s) }
                        }
                    }
                    .padding(4)
                    .background(Color(hex: "#2c2c2e"))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line2, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .shadow(color: .black.opacity(0.5), radius: 15, y: 10)
                    .offset(y: 34)
                    .zIndex(10)
                }
            }
        }
    }
}

private struct KWSuggestion: View {
    let text: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(text).font(.system(size: 12.5))
                .foregroundStyle(hover ? Theme.onAccent : Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(hover ? Theme.accent : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain).onHover { hover = $0 }
    }
}
