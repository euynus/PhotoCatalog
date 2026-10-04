// ============================================================
//  Status bar — catalog health on the left, grid controls on the right
// ============================================================
import SwiftUI

/// Split into small views so each part re-renders only for what it shows —
/// a rating or a thumbnail-size drag no longer rebuilds the whole bar.
struct StatusBar: View {
    @Environment(AppState.self) var app

    var body: some View {
        HStack(spacing: 10) {
            CatalogStatusLabel()
            SelectionCountLabel()
            Spacer(minLength: 8)
            TaskCenterStatusButton()
            DescribeProgressLabel()
            OriginalsCheckLabel()
            MaintenanceLabels()
            if app.view == .grid && !app.isDuplicates && !app.isPlaces && !app.isPeople {
                StatusSeparator()
                GridControls()
            }
            StatusSeparator()
            PanelsToggle()
        }
        .font(.system(size: 11))
        .labelStyle(StatusLabelStyle())
        .lineLimit(1)
        .foregroundStyle(Theme.text2)
        .padding(.horizontal, 12)
        .frame(height: Theme.statusbarH)
        .background(Theme.bgTitlebar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

/// Tab's both-panels toggle where it can be seen: until now only the key, and a menu item, knew it.
private struct PanelsToggle: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let hidden = app.panelsHidden
        Button { app.togglePanels() } label: {
            Image(systemName: hidden ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11))
                .foregroundStyle(hidden ? Theme.accent : Theme.text3)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(hidden ? "显示两侧面板 (Tab)" : "隐藏两侧面板 (Tab)")
        .accessibilityLabel(hidden ? "显示两侧面板" : "隐藏两侧面板")
        .fixedSize()
    }
}

private struct StatusSeparator: View {
    var body: some View { Rectangle().fill(Theme.line2).frame(width: 1, height: 12) }
}

private struct CatalogStatusLabel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if app.hasCatalogPreview {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini).tint(Theme.accent)
                Text("正在载入完整目录…")
            }
            .fixedSize()
        } else {
            // how the catalog keeps its originals, and its cache, are details: on hover
            Text("\(app.statusAssetCount.formatted()) 张照片")
                .help(L("目录库就绪 · \(app.catalogManagementText) · \(app.statusCacheText)"))
                .fixedSize()
        }
    }
}

private struct SelectionCountLabel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let count = app.selectedIds.count
        if count > 0 {
            Text("已选 \(count.formatted())")
                .foregroundStyle(Theme.accent)
                .fixedSize()
        }
    }
}

private struct TaskCenterStatusButton: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let active = app.backgroundTasks.filter { $0.state.isActive }.count
        let attention = app.taskHistoryError != nil || app.backgroundTasks.contains { $0.needsAttention }
        Button(action: app.showTaskCenter) {
            HStack(spacing: 4) {
                Image(systemName: "list.bullet.rectangle")
                if active > 0 {
                    Text(active > 99 ? "99+" : String(active)).monospacedDigit()
                }
            }
            .frame(width: 44, height: 20)
            .contentShape(Rectangle())
            .foregroundStyle(attention ? Theme.yellow : active > 0 ? Theme.accent : Theme.text3)
        }
        .buttonStyle(.plain)
        .disabled(app.store == nil || app.sheet != nil)
        .help("任务中心")
        .accessibilityLabel("任务中心")
        .accessibilityValue(active > 0 ? L("\(active) 个进行中") : attention ? L("有任务需要关注") : L("没有进行中的任务"))
    }
}

private struct DescribeProgressLabel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if let progress = app.describeProgress {
            HStack(spacing: 5) {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .tint(Theme.accent)
                    .frame(width: 54)
                Text(L("AI 描述 \(progress.done)/\(progress.total)")).monospacedDigit()
                Button { app.cancelDescribePhotos() } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.text3)
                .help("取消 AI 描述")
                .accessibilityLabel("取消 AI 描述")
            }
            .foregroundStyle(Theme.accent)
            .fixedSize()
        }
    }
}

private struct OriginalsCheckLabel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if app.isCheckingOriginals {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("正在检查原件…")
            }
            .foregroundStyle(Theme.text3)
            .accessibilityElement(children: .combine)
            .fixedSize()
        }
    }
}

private struct MaintenanceLabels: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Button { app.runBackup() } label: {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(Theme.text3)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!app.canRunCatalogMaintenance)
        .help(L("\(app.statusBackupText) · 创建目录库快照（不含原件）(⌘B)"))
        .accessibilityLabel("创建目录库快照")
        .accessibilityValue(app.statusBackupText)
    }
}

private struct GridControls: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        return HStack(spacing: 6) {
            Button { app.toggleGridInfo() } label: {
                Image(systemName: app.showInfo ? "text.below.photo.fill" : "text.below.photo")
                    .font(.system(size: 12))
                    .foregroundStyle(app.showInfo ? Theme.accent : Theme.text3)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(app.showInfo ? "隐藏缩略图信息 (I)" : "显示缩略图信息 (I)")
            .accessibilityLabel(app.showInfo ? "隐藏缩略图信息" : "显示缩略图信息")
            Image(systemName: "photo").font(.system(size: 9)).foregroundStyle(Theme.text3)
                .accessibilityHidden(true)
            Slider(value: $app.thumbSize, in: 108...280)
                .controlSize(.mini)
                .frame(width: 96)
                .accessibilityLabel("缩略图大小")
                .help("调整缩略图大小 (⌘+ / ⌘−)")
            Image(systemName: "photo").font(.system(size: 13)).foregroundStyle(Theme.text3)
                .accessibilityHidden(true)
        }
        .fixedSize()
    }
}

private struct StatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 11))
            configuration.title
        }
    }
}
