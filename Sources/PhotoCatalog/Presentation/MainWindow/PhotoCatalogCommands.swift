// ============================================================
//  App command menus and system keyboard shortcuts
// ============================================================
import SwiftUI

@MainActor
struct PhotoCatalogCommands: Commands {
    let app: AppState

    var body: some Commands {
        CommandMenu("目录库") {
            Button("新建目录库…") { app.createCatalog() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(app.importing)
            Button("打开目录库…") { app.openCatalog() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(app.importing)
            Button("导入照片文件夹…") { app.addFolder() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Divider()
            Button("设置…") { app.showSettings() }
                .keyboardShortcut(",", modifiers: .command)
        }

        CommandMenu("照片") {
            Section("评分") {
                Button("设置 1 星") { app.applyRatingShortcut(1) }
                Button("设置 2 星") { app.applyRatingShortcut(2) }
                Button("设置 3 星") { app.applyRatingShortcut(3) }
                Button("设置 4 星") { app.applyRatingShortcut(4) }
                Button("设置 5 星") { app.applyRatingShortcut(5) }
                Button("清除评分") { app.applyRatingShortcut(0) }
            }
            Divider()
            Button("导出选中原件…") { app.exportSelection() }
                .keyboardShortcut("e", modifiers: .command)
            Button("导出选中预览图…") { app.exportSelectionPreviews() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Divider()
            Button("加入相册…") { app.addSelectionToAlbum() }
                .disabled(!app.canApplySelectionToAlbum)
            Button("从当前相册移除") { app.removeSelectionFromCurrentAlbum() }
                .disabled(!app.canRemoveSelectionFromCurrentAlbum)
            Button("保存筛选为智能相册…") { app.saveCurrentFilterAsSmartAlbum() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!app.canSaveCurrentFilter)
            Divider()
            Button("从目录库移除…") { app.confirmDeleteSelected() }
            Button("将原件移到废纸篓…") { app.trashSelectedOriginals() }
                .keyboardShortcut(.delete, modifiers: .command)
        }

        CommandMenu("视图") {
            Button("网格视图") { app.switchView(.grid) }
            Button("单张查看") { app.switchView(.loupe) }
            Button("比较视图") { app.enterCompare() }
            Divider()
            Button("搜索") { app.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
            Button("显示/隐藏筛选栏") { app.toggleFilterBar() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("显示/隐藏 Inspector") { app.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: .command)
            Button("显示/隐藏缩略图信息") { app.toggleGridInfo() }
            Divider()
            Button("放大缩略图") { app.adjustThumbnailSize(by: 16) }
                .keyboardShortcut("=", modifiers: .command)
            Button("缩小缩略图") { app.adjustThumbnailSize(by: -16) }
                .keyboardShortcut("-", modifiers: .command)
            Button("重置缩略图大小") { app.resetThumbnailSize() }
                .keyboardShortcut("0", modifiers: .command)
        }

        CommandMenu("维护") {
            Button("重新扫描当前源") { app.rescanCurrentSource() }
                .keyboardShortcut("r", modifiers: .command)
            Button("立即备份目录库") { app.runBackup() }
                .keyboardShortcut("b", modifiers: .command)
            Button("恢复备份…") { app.restoreBackup() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Button("运行健康检查") { app.runHealthCheck() }
        }
    }
}
