// ============================================================
//  Develop presets — Lightroom's Presets panel
// ============================================================
import SwiftUI

/// The presets by group. Resting the pointer on one shows its look on the photo; a click
/// applies it.
struct DevelopPresetList: View {
    @Environment(AppState.self) private var app
    let asset: Asset
    @State private var hovered: String?
    /// Groups folded shut, one id per line.
    @AppStorage("pc_collapsedPresetGroups") private var collapsed = ""

    private struct Group: Identifiable {
        let id: String
        let title: String
        let presets: [DevelopPreset]
    }

    private var groups: [Group] {
        var groups = [Group(id: "builtin", title: L("内置"), presets: DevelopPreset.builtIns)]
        if !app.developPresets.isEmpty {
            groups.append(Group(id: "mine", title: L("我的预设"), presets: app.developPresets))
        }
        return groups
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(groups) { group in
                header(group)
                if !isCollapsed(group.id) {
                    ForEach(group.presets) { preset in row(preset) }
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

    private func isCollapsed(_ id: String) -> Bool {
        collapsed.split(separator: "\n").contains { $0 == id }
    }
}
