// ============================================================
//  App command menus and system keyboard shortcuts
// ============================================================
import SwiftUI

@MainActor
struct PhotoCatalogCommands: Commands {
    let app: AppState

    var body: some Commands {
        // Drop the default File ▸ New Window item: its ⌘N wins over
        // 目录库 ▸ 新建目录库 whenever a text field has focus (the key
        // monitor passes typing through), opening a stray duplicate window.
        CommandGroup(replacing: .newItem) {}

        CommandMenu("目录库") {
            Button("新建目录库…") { app.createCatalog() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(app.importing || app.sheet != nil)
            Button("打开目录库…") { app.openCatalog() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(app.importing || app.sheet != nil)
            Button("关闭目录库") { app.closeCatalog() }
                .disabled(app.importing || app.sheet != nil || !app.hasOpenCatalog)
            Button("导入照片文件夹…") {
                if app.onboarded { app.addFolder() } else { app.enterApp("import") }
            }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(app.sheet != nil)
            Divider()
            Button("设置…") { app.showSettings() }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(app.sheet != nil || !app.onboarded)
        }

        CommandMenu("照片") {
            Section("评分") {
                Button("设置 1 星") { app.applyRatingShortcut(1) }
                    .disabled(app.sheet != nil || !app.hasSelection)
                Button("设置 2 星") { app.applyRatingShortcut(2) }
                    .disabled(app.sheet != nil || !app.hasSelection)
                Button("设置 3 星") { app.applyRatingShortcut(3) }
                    .disabled(app.sheet != nil || !app.hasSelection)
                Button("设置 4 星") { app.applyRatingShortcut(4) }
                    .disabled(app.sheet != nil || !app.hasSelection)
                Button("设置 5 星") { app.applyRatingShortcut(5) }
                    .disabled(app.sheet != nil || !app.hasSelection)
                Button("清除评分") { app.applyRatingShortcut(0) }
                    .disabled(app.sheet != nil || !app.hasSelection)
            }
            Divider()
            Button("导出选中原件…") { app.exportSelection() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(app.sheet != nil || !app.canExportOriginalSelection)
            Button("导出选中预览图…") { app.exportSelectionPreviews() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(app.sheet != nil || !app.canExportPreviewSelection)
            Divider()
            Button("加入相册…") { app.addSelectionToAlbum() }
                .disabled(app.sheet != nil || !app.canApplySelectionToAlbum)
            Button("从当前相册移除") { app.removeSelectionFromCurrentAlbum() }
                .disabled(app.sheet != nil || !app.canRemoveSelectionFromCurrentAlbum)
            Button("保存筛选为智能相册…") { app.saveCurrentFilterAsSmartAlbum() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(app.sheet != nil || !app.canSaveCurrentFilter)
            Divider()
            Button("从目录库移除…") { app.confirmDeleteSelected() }
                .disabled(app.sheet != nil || !app.hasSelection)
            Button("将原件移到废纸篓…") { app.trashSelectedOriginals() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(app.sheet != nil || !app.canOperateOnSelectedOriginals)
        }

        CommandMenu("视图") {
            Button("网格视图") { app.switchView(.grid) }
                .disabled(app.sheet != nil || !app.onboarded)
            Button("单张查看") { app.switchView(.loupe) }
                .disabled(app.sheet != nil || !app.onboarded)
            Button("比较视图") { app.enterCompare() }
                .disabled(app.sheet != nil || !app.onboarded)
            Divider()
            Button("搜索") { app.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(app.sheet != nil || !app.onboarded)
            Button("显示/隐藏筛选栏") { app.toggleFilterBar() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(app.sheet != nil || !app.onboarded)
            Button("显示/隐藏 Inspector") { app.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(app.sheet != nil || !app.onboarded)
            Button("显示/隐藏缩略图信息") { app.toggleGridInfo() }
                .disabled(app.sheet != nil || !app.onboarded)
            Divider()
            Button("放大缩略图") { app.adjustThumbnailSize(by: 16) }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(app.sheet != nil || !app.onboarded)
            Button("缩小缩略图") { app.adjustThumbnailSize(by: -16) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(app.sheet != nil || !app.onboarded)
            Button("重置缩略图大小") { app.resetThumbnailSize() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(app.sheet != nil || !app.onboarded)
        }

        CommandMenu("维护") {
            Button("重新扫描当前源") { app.rescanCurrentSource() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(app.sheet != nil || !app.canRunCatalogMaintenance)
            Button("立即备份目录库") { app.runBackup() }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(app.sheet != nil || !app.canRunCatalogMaintenance)
            Button("恢复备份…") { app.restoreBackup() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(app.sheet != nil || !app.canRunCatalogMaintenance)
            Button("运行健康检查") { app.runHealthCheck() }
                .disabled(app.sheet != nil || !app.canRunCatalogMaintenance)
        }
    }
}
