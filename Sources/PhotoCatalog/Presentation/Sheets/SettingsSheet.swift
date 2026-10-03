// ============================================================
//  Settings (PRD §17) — surfaces import mode, XMP, cache, backup,
//  health check, and batch rename.
// ============================================================
import SwiftUI

struct SettingsSheet: View {
    @Environment(AppState.self) var app
    @State private var shiftHours = 1
    @State private var shiftMinutes = 0
    @State private var absoluteDate = Date()
    @State private var exportPresetName = ""
    @State private var category: Category = .general

    private enum Category: String, CaseIterable {
        case general, importing, develop, exporting, metadata, ai, cache, catalog, files

        var title: String {
            switch self {
            case .general: return L("常规")
            case .importing: return L("导入")
            case .develop: return L("修图")
            case .exporting: return L("导出")
            case .metadata: return L("元数据")
            case .ai: return L("AI")
            case .cache: return L("缓存与性能")
            case .catalog: return L("目录库")
            case .files: return L("文件操作")
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .importing: return "square.and.arrow.down"
            case .develop: return "slider.horizontal.3"
            case .exporting: return "square.and.arrow.up"
            case .metadata: return "tag"
            case .ai: return "sparkles"
            case .cache: return "internaldrive"
            case .catalog: return "photo.on.rectangle"
            case .files: return "folder"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            navigation
            ScrollView { body_ }
                .id(category)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 780, height: 560)
        .navigationTitle(category.title)
        .onAppear(perform: takeStartCategory)
        // asked for again while open, e.g. at the AI category from a feature that needs it
        .onChange(of: app.settingsRequest) { takeStartCategory() }
        .font(.system(size: 13))
        .foregroundStyle(Theme.text)
        .background(Theme.bgPanel)
    }

    private func takeStartCategory() {
        if let start = app.settingsStartCategory.flatMap(Category.init(rawValue:)) { category = start }
        app.settingsStartCategory = nil
    }

    private var navigation: some View {
        VStack(spacing: 3) {
            ForEach(Category.allCases, id: \.self) { item in
                Button { category = item } label: {
                    Label(item.title, systemImage: item.symbol)
                        .font(.system(size: 13, weight: category == item ? .semibold : .regular))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 9)
                        .foregroundStyle(category == item ? Theme.accent : Theme.text2)
                        .background(category == item ? Theme.accentSoft : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(category == item ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 156)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.bgSidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
    }

    private var body_: some View {
        @Bindable var app = app   // $app bindings below need the Bindable projection
        return VStack(alignment: .leading, spacing: 24) {
            section(L("常规"), category: .general) {
                row(L("外观")) {
                    Segmented(options: AppAppearance.allCases.map { SegOption(value: $0.rawValue, label: $0.label) },
                              value: app.appearance.rawValue,
                              onChange: { app.appearance = AppAppearance(rawValue: $0) ?? .system }, size: "sm")
                }
                Text("照片画布始终保持深色中性背景，便于判断曝光与色彩。")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                row(L("语言")) {
                    Segmented(options: AppLanguage.allCases.map { SegOption(value: $0.rawValue, label: $0.label) },
                              value: app.language.rawValue,
                              onChange: { app.changeLanguage(AppLanguage(rawValue: $0) ?? .system) }, size: "sm")
                }
                Toggle(isOn: $app.openLastCatalogOnLaunch) {
                    Text("启动时打开上次目录库").font(.system(size: 13)).foregroundStyle(Theme.text)
                }.toggleStyle(TrailingSwitch())
                Toggle(isOn: $app.autoCheckForUpdates) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("自动检查更新").font(.system(size: 13)).foregroundStyle(Theme.text)
                        Text("每天最多联网查看一次 GitHub 上的新版本，有新版本时询问是否安装")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                    }
                }.toggleStyle(TrailingSwitch())
                HStack(spacing: 12) {
                    Stepper(value: $app.recentImportDays, in: 1...365) {
                        Text("「最近导入」窗口 \(app.recentImportDays) 天")
                            .font(.system(size: 13)).foregroundStyle(Theme.text)
                    }
                    Spacer()
                }
            }

            section(L("导入"), category: .importing) {
                Toggle(isOn: $app.pairRawAndJpeg) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("RAW+JPEG 显示为一张照片").font(.system(size: 13)).foregroundStyle(Theme.text)
                        Text("同一文件夹中同名的 RAW 与 JPEG/HEIC 视为一次拍摄：网格只显示 RAW，评分、旗标、关键词和删除同时作用于两个文件。")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.toggleStyle(TrailingSwitch())
                row(L("导入模式")) {
                    Segmented(options: [
                        SegOption(value: "referenced", label: L("原位添加")),
                        SegOption(value: "managed", label: L("复制到目录库")),
                    ], value: app.importMode.rawValue,
                       onChange: { app.importMode = ImportMode(rawValue: $0) ?? .referenced }, size: "sm")
                }
                Text(app.importMode == .referenced ? L("原位添加：只建立索引，原件留在原位置（推荐）。")
                     : app.managedArchiveRule == .camera ? L("复制到目录库：导入时把原件复制到目录库的 Originals/<相机>/YYYY/MM。")
                     : L("复制到目录库：导入时把原件复制到目录库的 Originals/YYYY/MM/DD。"))
                    .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                if app.importMode == .managed {
                    row(L("归档规则")) {
                        Segmented(options: [
                            SegOption(value: "date", label: L("按日期")),
                            SegOption(value: "camera", label: L("按相机")),
                        ], value: app.managedArchiveRule.rawValue,
                           onChange: { app.managedArchiveRule = ManagedArchiveRule(rawValue: $0) ?? .date },
                           size: "sm")
                    }
                }
                row(L("重复处理")) {
                    Segmented(options: [
                        SegOption(value: "groupExact", label: L("分组")),
                        SegOption(value: "skipExact", label: L("跳过")),
                        SegOption(value: "keep", label: L("保留")),
                    ], value: app.importDuplicateStrategy.rawValue,
                       onChange: {
                        app.importDuplicateStrategy = ImportDuplicateStrategy(rawValue: $0) ?? .groupExact
                    }, size: "sm")
                }
                row(L("导入后关键词")) {
                    settingsTextField(L("逗号分隔"), text: $app.importPostKeywords)
                }
                row(L("导入后颜色")) {
                    Picker("", selection: $app.importPostColorLabel) {
                        Text("无").tag("")
                        ForEach(ColorLabel.allCases) { label in
                            Text(label.name).tag(label.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 92)
                }
                row(L("导入后相册")) {
                    settingsTextField(L("相册名"), text: $app.importPostAlbumName)
                }
                row(L("导入时修图")) {
                    DevelopPresetPicker(selection: $app.importDevelopPresetId)
                        .labelsHidden()
                        .frame(width: 160)
                }
                row(L("作者")) {
                    settingsTextField(L("导入时写入，留空则不改"), text: $app.importAuthor)
                }
                row(L("版权")) {
                    settingsTextField(L("如 © {year} 你的名字"), text: $app.importCopyright)
                }
                Toggle(isOn: $app.visionEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("导入时分析场景与人脸（自动标签与人物）").font(.system(size: 13)).foregroundStyle(Theme.text)
                        Text("完全在本机进行，照片不会离开设备。").font(.system(size: 11)).foregroundStyle(Theme.text3)
                    }
                }.toggleStyle(TrailingSwitch())
            }

            section(L("RAW 默认设置"), category: .develop) {
                Text("RAW 照片导入时先套用所属相机的默认预设，复位时也回到它；导入预设再叠加在上面。未单独设置的相机使用“所有相机”。")
                    .font(.system(size: 12)).foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
                row(L("所有相机")) {
                    DevelopPresetPicker(selection: rawDefaultBinding(""), leading: [("", L("原照设置"))])
                        .labelsHidden()
                        .frame(width: 200)
                }
                ForEach(app.rawCameras, id: \.self) { camera in
                    row(camera) {
                        DevelopPresetPicker(selection: rawDefaultBinding(camera),
                                            leading: [("", L("同“所有相机”")), ("none", L("原照设置"))])
                            .labelsHidden()
                            .frame(width: 200)
                    }
                }
            }

            section(L("导出"), category: .exporting) {
                row(L("目录结构")) {
                    Segmented(options: [
                        SegOption(value: "flat", label: L("平铺")),
                        SegOption(value: "date", label: L("日期")),
                        SegOption(value: "sourceFolder", label: L("源文件夹")),
                        SegOption(value: "album", label: L("相册")),
                    ], value: app.exportDirectoryStructure.rawValue,
                       onChange: {
                        app.exportDirectoryStructure = ExportDirectoryStructure(rawValue: $0) ?? .flat
                    }, size: "sm")
                }
                Toggle(isOn: $app.exportWritesXMP) {
                    Text("导出时写入 XMP 附属文件").font(.system(size: 13)).foregroundStyle(Theme.text)
                }.toggleStyle(TrailingSwitch())
                HStack(spacing: 9) {
                    TextField("预设名", text: $exportPresetName)
                        .textFieldStyle(.plain).font(.system(size: 13))
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(Theme.surface)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line2, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .frame(width: 140)
                    ghostButton(nil, L("保存为预设"), small: true) {
                        app.saveExportPreset(name: exportPresetName); exportPresetName = ""
                    }
                    if !app.exportPresets.isEmpty {
                        Menu {
                            ForEach(app.exportPresets) { p in
                                Button(p.name) { app.applyExportPreset(p) }
                            }
                            Divider()
                            ForEach(app.exportPresets) { p in
                                Button("删除「\(p.name)」", role: .destructive) { app.deleteExportPreset(p) }
                            }
                        } label: {
                            Text("应用预设").font(.system(size: 13)).foregroundStyle(Theme.accent)
                        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                    Spacer()
                }
                HStack(spacing: 9) {
                    ghostButton("eye", L("导出选中预览图"), small: true,
                                disabled: !app.canExportPreviewSelection) { app.exportSelectionPreviews() }
                    Spacer()
                }
            }

            section(L("AI"), category: .ai) {
                AISettings()
            }

            section(L("元数据"), category: .metadata) {
                Toggle(isOn: $app.readXMPSidecar) {
                    Text("导入时读取 XMP 附属文件").font(.system(size: 13)).foregroundStyle(Theme.text)
                }.toggleStyle(TrailingSwitch())
                Toggle(isOn: $app.autoWriteXMPSidecar) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("编辑时自动写入 XMP 附属文件").font(.system(size: 13)).foregroundStyle(Theme.text)
                        Text("评分 / 关键词 / 标题等改动会写入同名 .xmp，不改动原图。")
                            .font(.system(size: 11)).foregroundStyle(Theme.text3)
                    }
                }.toggleStyle(TrailingSwitch())
                Toggle(isOn: $app.autoReadChangedXMP) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("自动读取外部修改的 XMP").font(.system(size: 13)).foregroundStyle(Theme.text)
                        Text("其他应用改动 .xmp 后，直接用文件里的元数据更新目录库；关闭时只标出这些照片，可在「照片」菜单中读取。")
                            .font(.system(size: 11)).foregroundStyle(Theme.text3)
                    }
                }.toggleStyle(TrailingSwitch())
            }

            section(L("缩略图与缓存"), category: .cache) {
                row(L("预览长边")) {
                    Segmented(options: [
                        SegOption(value: "1600", label: "1600px"),
                        SegOption(value: "2048", label: "2048px"),
                    ], value: "\(app.previewMaxPixel)",
                       onChange: { app.previewMaxPixel = Int($0) ?? 2_048 }, size: "sm")
                }
                Stepper(value: $app.cacheLimitMB, in: 256...102_400, step: 256) {
                    Text("缓存上限 \(app.cacheLimitMB) MB")
                        .font(.system(size: 13)).foregroundStyle(Theme.text)
                }
                HStack(spacing: 9) {
                    ghostButton("refresh", L("重建缩略图"), small: true) { app.rebuildThumbnails() }
                    ghostButton("trash", L("清理缓存"), small: true) { app.confirmClearCache() }
                    ghostButton("check", L("应用上限"), small: true) { app.pruneCacheToLimit() }
                }
            }

            section(L("性能"), category: .cache) {
                Toggle(isOn: $app.reduceBackgroundOnLowPower) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("低电量模式下减少后台任务").font(.system(size: 13)).foregroundStyle(Theme.text)
                        Text("开启「低电量模式」时暂停后台缩略图补齐，节省电量。")
                            .font(.system(size: 11)).foregroundStyle(Theme.text3)
                    }
                }.toggleStyle(TrailingSwitch())
            }

            section(L("维护"), category: .catalog) {
                row(L("自动备份")) {
                    Segmented(options: [
                        SegOption(value: "off", label: L("关闭", table: "Context")),
                        SegOption(value: "daily", label: L("每天")),
                        SegOption(value: "weekly", label: L("每周")),
                    ], value: app.automaticBackupFrequency,
                       onChange: { app.automaticBackupFrequency = $0 }, size: "sm")
                }
                HStack(spacing: 9) {
                    ghostButton("check", L("立即备份"), small: true,
                                disabled: !app.canRunCatalogMaintenance) { app.runBackup() }
                    ghostButton("refresh", L("恢复备份"), small: true,
                                disabled: !app.canRunCatalogMaintenance) { app.restoreBackup() }
                    ghostButton("info", L("运行健康检查"), small: true,
                                disabled: !app.canRunCatalogMaintenance) { app.runHealthCheck() }
                }
                if let r = app.healthReport {
                    Text(r.summary).font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(r.isHealthy ? Theme.text2 : Theme.redSoft)
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.bgSidebar)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(r.isHealthy ? Theme.line2 : Theme.redSoft).frame(width: 2)
                        }
                }
            }

            section(L("批量重命名"), category: .files) {
                Text("按命名模板重命名选中已导入照片的原件，重命名前可预览新文件名（也可在「照片」菜单或右键菜单中打开）。")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                HStack(spacing: 9) {
                    ghostButton(nil, L("重命名选中照片…"), small: true,
                                disabled: !app.canOperateOnSelectedOriginals) { app.showRenameSheet() }
                    Spacer()
                }
            }

            section(L("外部编辑器"), category: .files) {
                Text("「在外部编辑器中编辑」(⌥⌘E) 会把照片连同修图调整存为 16 位 TIFF 副本（原件旁的「…-编辑.tif」），加入目录库并与原片叠放，再用这个应用打开；原件不会被修改。")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                HStack(spacing: 9) {
                    Text(app.externalEditorName ?? L("未选择"))
                        .font(.system(size: 13)).foregroundStyle(app.externalEditorName == nil ? Theme.text3 : Theme.text)
                    ghostButton(nil, L("选择…"), small: true) { app.chooseExternalEditor() }
                    Spacer()
                }
            }

            section(L("原件文件"), category: .files) {
                Text("复制不会改变目录库路径；移动成功后会更新目录库中的原件位置。")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                HStack(spacing: 9) {
                    ghostButton("copy", L("复制选中原件"), small: true,
                                disabled: !app.canOperateOnSelectedOriginals) { app.copySelectedOriginals() }
                    ghostButton("folder", L("移动选中原件"), danger: true, small: true,
                                disabled: !app.canOperateOnSelectedOriginals) { app.moveSelectedOriginals() }
                    ghostButton("trash", L("移到废纸篓"), danger: true, small: true,
                                disabled: !app.canOperateOnSelectedOriginals) { app.trashSelectedOriginals() }
                    Spacer()
                }
            }

            section(L("批量调整拍摄时间"), category: .files) {
                Text("对选中照片整体平移拍摄时间（时区/相机时钟校正），或统一设为指定时间。")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                HStack(spacing: 12) {
                    Stepper(value: $shiftHours, in: -72...72) {
                        Text("\(shiftHours > 0 ? "+" : "")\(shiftHours) 时")
                            .font(.system(size: 13)).foregroundStyle(Theme.text)
                    }
                    Stepper(value: $shiftMinutes, in: -59...59) {
                        Text("\(shiftMinutes > 0 ? "+" : "")\(shiftMinutes) 分")
                            .font(.system(size: 13)).foregroundStyle(Theme.text)
                    }
                    ghostButton(nil, L("平移选中"), small: true) {
                        app.shiftCaptureTime(hours: shiftHours, minutes: shiftMinutes)
                    }
                    Spacer()
                }
                HStack(spacing: 12) {
                    DatePicker("", selection: $absoluteDate)
                        .labelsHidden().datePickerStyle(.compact)
                    ghostButton(nil, L("设为该时间"), small: true) { app.setCaptureDate(absoluteDate) }
                    Spacer()
                }
            }

            section(L("目录库"), category: .catalog) {
                HStack(spacing: 9) {
                    ghostButton("plus", L("新建目录库"), small: true) { app.createCatalog() }
                    ghostButton("folder", L("打开目录库"), small: true) { app.openCatalog() }
                    ghostButton("close", L("关闭目录库"), small: true) { app.closeCatalog() }
                    ghostButton("trash", L("清除最近"), small: true) { app.confirmClearRecentCatalogs() }
                }
                Text(app.catalogPath)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            section(L("隐私"), category: .general) {
                Text("本地优先 · 仅访问授权的文件夹。可清除以下本地数据。")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                HStack(spacing: 9) {
                    ghostButton("trash", L("清除日志"), small: true) { app.confirmClearLogs() }
                    ghostButton("trash", L("清除安全书签"), small: true) { app.confirmClearSecurityBookmarks() }
                }
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, category: Category,
                                       @ViewBuilder content: () -> Content) -> some View {
        if self.category == category {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 8)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
                content()
            }
        }
    }

    private func rawDefaultBinding(_ camera: String) -> Binding<String> {
        Binding(get: { app.rawDefaultPresetIds[camera] ?? "" },
                set: { app.setRawDefaultPreset($0, forCamera: camera) })
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label).font(.system(size: 13)).foregroundStyle(Theme.text2)
            Spacer()
            content()
        }
    }

    private func settingsTextField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain).font(.system(size: 13))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Theme.surface)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line2, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .frame(width: 220)
    }
}

/// A setting's switch at the trailing edge, its label filling the row: the switches line up
/// in one column instead of each following its own label.
private struct TrailingSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .top, spacing: 16) {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: configuration.$isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.accent)
        }
    }
}
