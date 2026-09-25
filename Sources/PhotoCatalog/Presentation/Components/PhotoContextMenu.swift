// ============================================================
//  Right-click menu for photos — open, reveal, share, review, remove
// ============================================================
import SwiftUI
import AppKit

/// Acts on the selection when the clicked photo is part of it, otherwise on that photo.
/// SwiftUI builds every visible cell's menu eagerly, so the body reads no observable state:
/// otherwise each click or rating would rebuild dozens of menus.
struct PhotoContextMenu: View {
    @Environment(AppState.self) private var app
    let asset: Asset
    /// The paired JPEG's path, passed in by the grid (which already resolves the pair).
    let pairedJPEGPath: String?

    private var fileURL: URL? {
        guard asset.status == .ready, let path = asset.localPath else { return nil }
        return URL(fileURLWithPath: path)
    }

    var body: some View {
        Button("打开") { act { app.openSelection() } }
            .disabled(fileURL == nil)
        if let fileURL {
            Menu("打开方式") {
                OpenWithItems(fileURL: fileURL) { editor in act { app.openSelection(with: editor) } }
                if let pairedJPEGPath {
                    Divider()
                    Button("打开配对的 JPEG") { NSWorkspace.shared.open(URL(fileURLWithPath: pairedJPEGPath)) }
                }
            }
        }
        Button("在访达中显示") { act { app.revealSelectionInFinder() } }
            .disabled(fileURL == nil)
        if let fileURL {
            ShareLink(item: fileURL) {
                Label("分享", systemImage: "square.and.arrow.up")
            }
        }

        Divider()
        Menu("评分") {
            ForEach(0...5, id: \.self) { rating in
                Button(rating == 0 ? "无评分" : String(repeating: "★", count: rating)) {
                    act { _ = app.setRating(rating) }
                }
            }
        }
        Menu("旗标") {
            Button("精选") { act { _ = app.setFlag(.pick) } }
            Button("拒绝") { act { _ = app.setFlag(.reject) } }
            Button("无旗标") { act { _ = app.setFlag(.none) } }
        }
        Menu("颜色标签") {
            ForEach(ColorLabel.allCases) { color in
                Button(color.name) { act { _ = app.setColor(color) } }
            }
            Button("无") { act { _ = app.setColor(nil) } }
        }
        Menu("修图设置") {
            Button("拷贝修图设置…") { act { app.showDevelopTransfer(.copy) } }
            Button("粘贴修图设置") { act { app.pasteDevelopSettingsIfCopied() } }
            Menu("应用修图预设") {
                // presets change rarely, so reading them doesn't rebuild menus on every click
                ForEach(app.allDevelopPresets) { preset in
                    Button(preset.name) { act { app.applyDevelopPreset(preset) } }
                }
            }
            Divider()
            Button("向左旋转") { act { app.rotateSelection(clockwise: false) } }
            Button("向右旋转") { act { app.rotateSelection(clockwise: true) } }
            Button("复位修图调整") { act { app.resetDevelopSelection() } }
        }

        Button("设置位置…") { act { app.showLocationEditor() } }

        Divider()
        Button("导出…") { act { app.showRenderedExport() } }
        Button("加入相册…") { act { app.addSelectionToAlbum() } }
        Button("从目录库移除…", role: .destructive) { act { app.confirmDeleteSelected() } }
    }

    private func act(_ action: () -> Void) {
        app.prepareContextSelection(asset.id)
        action()
    }
}

/// Apps that can open the file, default first. LaunchServices is asked once per file type.
private struct OpenWithItems: View {
    let fileURL: URL
    let onOpen: (URL) -> Void

    @MainActor private static var editorsByExtension: [String: [URL]] = [:]

    private var editors: [URL] {
        let ext = fileURL.pathExtension.lowercased()
        if let cached = Self.editorsByExtension[ext] { return cached }
        let preferred = NSWorkspace.shared.urlForApplication(toOpen: fileURL)
        let all = NSWorkspace.shared.urlsForApplications(toOpen: fileURL)
            .filter { $0 != preferred }
            .sorted { name(of: $0).localizedStandardCompare(name(of: $1)) == .orderedAscending }
        let result = Array(([preferred].compactMap { $0 } + all).prefix(12))
        Self.editorsByExtension[ext] = result
        return result
    }

    var body: some View {
        ForEach(editors, id: \.self) { editor in
            Button { onOpen(editor) } label: {
                Label {
                    Text(name(of: editor))
                } icon: {
                    Image(nsImage: icon(of: editor))
                }
            }
        }
    }

    private func name(of app: URL) -> String {
        FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    private func icon(of app: URL) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: app.path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}
