// ============================================================
//  Develop sidebar — presets, snapshots and history, on the left as in Lightroom
// ============================================================
import SwiftUI

/// What the library sidebar gives way to in Develop: the photo's presets, snapshots and
/// history, which the adjustment panel on the right used to carry at its far end.
struct DevelopSidebar: View {
    @Environment(AppState.self) private var app
    @State private var renamingSnapshot: String?
    @State private var snapshotName = ""
    /// Typing a snapshot name must reach the field, not the photo shortcuts.
    @FocusState private var snapshotNameFocused: Bool
    @State private var showsFullHistory = false

    var body: some View {
        Group {
            if let asset = app.primary, app.canDevelop(asset) {
                content(asset)
            } else {
                ContentUnavailableView("未选择照片", systemImage: "slider.horizontal.3")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(Theme.text)
    }

    private func content(_ asset: Asset) -> some View {
        let settings = app.developSettings(for: asset.id)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DevelopSection(L("预设"), id: "presets", group: DevelopSections.sidebar, accessory: {
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
                DevelopSection(L("快照"), id: "snapshots", group: DevelopSections.sidebar, accessory: {
                    Button { app.createDevelopSnapshot(for: asset.id) } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("以当前设置新建快照")
                        .accessibilityLabel("新建快照")
                }) { snapshots(asset) }
                DevelopSection(L("历史记录"), id: "history", group: DevelopSections.sidebar, accessory: {
                    Button("清除") { app.confirmClearDevelopHistory(for: asset.id) }
                        .controlSize(.small)
                        .disabled(app.developHistory(for: asset.id).isEmpty)
                        .help("清除这张照片的历史记录（不改变当前设置）")
                }) { history(asset, settings) }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
        // as the adjustment panel's: a scroll view flush with the column's top runs on under the
        // toolbar, where SwiftUI hit-tests it the toolbar's height above where it's drawn
        .padding(.top, 1)
    }

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
}
