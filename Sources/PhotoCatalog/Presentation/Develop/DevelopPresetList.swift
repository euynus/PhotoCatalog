// ============================================================
//  Develop presets — Lightroom's Presets panel
// ============================================================
import SwiftUI

/// The presets by group. Resting the pointer on one shows its look on the photo; a click
/// applies it; the user's own are renamed, updated, regrouped and deleted from their menu.
struct DevelopPresetList: View {
    @Environment(AppState.self) private var app
    let asset: Asset
    @State private var hovered: String?
    /// Groups folded shut, one id per line.
    @AppStorage("pc_collapsedPresetGroups") private var collapsed = ""
    /// A preset being renamed, or given a new group, in place.
    private enum Editing: Equatable {
        case rename(String)
        case newGroup(String)
    }
    @State private var editing: Editing?
    @State private var text = ""
    /// Typing a name must reach the field, not the photo shortcuts.
    @FocusState private var fieldFocused: Bool

    private struct Group: Identifiable {
        let id: String
        let title: String
        let presets: [DevelopPreset]
    }

    private var groups: [Group] {
        var groups = [Group(id: "builtin", title: L("内置"), presets: DevelopPreset.builtIns)]
        let ungrouped = app.developPresets.filter { $0.group == nil }
        if !ungrouped.isEmpty { groups.append(Group(id: "mine", title: L("我的预设"), presets: ungrouped)) }
        for name in app.developPresetGroups {
            groups.append(Group(id: "group:" + name, title: name, presets: app.developPresets.filter { $0.group == name }))
        }
        return groups
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(groups) { group in
                header(group)
                if !isCollapsed(group.id) {
                    ForEach(group.presets) { preset in
                        if editing == .rename(preset.id) {
                            field(prompt: L("预设名称")) { app.renameDevelopPreset(preset.id, to: text) }
                        } else {
                            row(preset)
                        }
                        if editing == .newGroup(preset.id) {
                            field(prompt: L("新组名称")) { app.moveDevelopPreset(preset.id, toGroup: text); return true }
                        }
                    }
                }
            }
        }
        .onChange(of: asset.id) {
            hovered = nil
            app.endDevelopPresetPreview()
        }
        .onDisappear { app.endDevelopPresetPreview() }
    }

    private func header(_ group: Group) -> some View {
        Button {
            var ids = Set(collapsed.split(separator: "\n").map(String.init))
            if ids.contains(group.id) { ids.remove(group.id) } else { ids.insert(group.id) }
            collapsed = ids.sorted().joined(separator: "\n")
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isCollapsed(group.id) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 10)
                Text(group.title).font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.text3)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isCollapsed(group.id) ? L("已折叠") : L("已展开"))
    }

    private func row(_ preset: DevelopPreset) -> some View {
        Button { app.applyDevelopPreset(preset) } label: {
            Text(preset.name)
                .font(.system(size: 12))
                .lineLimit(1).truncationMode(.tail)
                .padding(.leading, 22).padding(.trailing, 8).padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hovered == preset.id ? Theme.accentFill.opacity(0.15) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("悬停预览，点按应用")
        .contextMenu { if !preset.isBuiltIn { menu(preset) } }
        .onHover { inside in
            if inside {
                hovered = preset.id
                app.previewDevelopPreset(preset, on: asset)
            } else if hovered == preset.id {
                hovered = nil
                app.endDevelopPresetPreview(preset.id)
            }
        }
    }

    @ViewBuilder
    private func menu(_ preset: DevelopPreset) -> some View {
        Button("重命名…") { begin(.rename(preset.id), text: preset.name) }
        Button("用当前设置更新") { app.updateDevelopPreset(preset.id) }
        Menu("移到组") {
            Button("我的预设") { app.moveDevelopPreset(preset.id, toGroup: nil) }
                .disabled(preset.group == nil)
            ForEach(app.developPresetGroups, id: \.self) { name in
                Button(name) { app.moveDevelopPreset(preset.id, toGroup: name) }
                    .disabled(preset.group == name)
            }
            Divider()
            Button("新建组…") { begin(.newGroup(preset.id), text: "") }
        }
        Divider()
        Button("删除…", role: .destructive) { app.confirmDeleteDevelopPreset(preset.id) }
    }

    private func begin(_ edit: Editing, text: String) {
        app.endDevelopPresetPreview()
        self.text = text
        editing = edit
    }

    /// A name typed in place: Return saves (when `save` accepts it), Esc or leaving cancels.
    private func field(prompt: String, save: @escaping () -> Bool) -> some View {
        TextField(prompt, text: $text)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .padding(.leading, 18)
            .focused($fieldFocused)
            .onAppear { fieldFocused = true }
            .onSubmit { if save() { editing = nil } }
            .onExitCommand { editing = nil }
            .onChange(of: fieldFocused) { if !fieldFocused { editing = nil } }
    }

    private func isCollapsed(_ id: String) -> Bool {
        collapsed.split(separator: "\n").contains { $0 == id }
    }
}
