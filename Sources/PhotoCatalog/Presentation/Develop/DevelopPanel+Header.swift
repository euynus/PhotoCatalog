import SwiftUI
import AppKit

extension DevelopPanel {
    func header(_ asset: Asset, settings: DevelopSettings) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DevelopHistogramView(histogram: app.developHistogram?.assetId == asset.id
                                 ? app.developHistogram?.histogram : nil)
            ExposureStrip(asset: asset)
            Text(asset.filename).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 8) {
                Toggle(isOn: Binding(get: { app.developShowsOriginal }, set: { app.developShowsOriginal = $0 })) {
                    Label("修改前", systemImage: "circle.righthalf.filled")
                }
                .toggleStyle(.button)
                .help("修改前 / 修改后 (\\)")
                Toggle(isOn: Binding(get: { app.developComparing }, set: { app.developComparing = $0 })) {
                    Label("对比", systemImage: "rectangle.split.2x1")
                }
                .toggleStyle(.button)
                .help("修改前与修改后并排 (Y)")
                Spacer(minLength: 0)
                Button("复位") { app.resetDevelop(asset) }
                .disabled(settings == app.defaultDevelopSettings(for: asset))
                .help("恢复为默认设置：相机的 RAW 默认设置，或原照设置")
            }
            .controlSize(.small)
            HStack(spacing: 8) {
                presetMenu
                Spacer(minLength: 0)
                Button("拷贝…") { app.showDevelopTransfer(.copy) }
                    .help("拷贝修图设置 (⇧⌘C)")
                Button("粘贴") { app.pasteDevelopSettings() }
                    .disabled(app.developClipboard == nil)
                    .help("粘贴修图设置 (⇧⌘V)")
            }
            .controlSize(.small)
        }
    }

    private var presetMenu: some View {
        Menu {
            Section("内置") {
                ForEach(DevelopPreset.builtIns) { preset in
                    Button(preset.name) { app.applyDevelopPreset(preset) }
                }
            }
            if !app.developPresets.isEmpty {
                Section("我的预设") {
                    ForEach(app.developPresets) { preset in
                        Button(preset.name) { app.applyDevelopPreset(preset) }
                    }
                }
            }
            Divider()
            Button("存储为预设…") { app.showDevelopTransfer(.preset) }
            Button("导入预设…") { app.chooseAndImportDevelopPresets() }
            if !app.developPresets.isEmpty {
                Menu("删除预设") {
                    ForEach(app.developPresets) { preset in
                        Button(preset.name, role: .destructive) { app.confirmDeleteDevelopPreset(preset.id) }
                    }
                }
            }
        } label: {
            Label("预设", systemImage: "wand.and.stars")
        }
        .fixedSize()
        .help("应用或存储修图预设")
    }
}
