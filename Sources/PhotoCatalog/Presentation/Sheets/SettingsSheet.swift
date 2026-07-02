// ============================================================
//  Settings (PRD §17) — surfaces import mode, XMP, cache, backup,
//  health check, and batch rename.
// ============================================================
import SwiftUI

struct SettingsSheet: View {
    @EnvironmentObject var app: AppState
    @State private var renamePrefix = "IMG"
    @State private var shiftHours = 1
    @State private var shiftMinutes = 0
    @State private var absoluteDate = Date()
    @State private var exportPresetName = ""

    var body: some View {
        VStack(spacing: 0) {
            head
            ScrollView { body_ }
            foot
        }
        .frame(width: 560)
        .frame(maxHeight: 620)
        .background(Color(hex: "#232325"))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line2, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.7), radius: 60, y: 40)
    }

    private var head: some View {
        HStack {
            HStack(spacing: 9) {
                Icon("gear", size: 17).foregroundStyle(Theme.accent)
                Text("设置").font(.system(size: 14.5, weight: .semibold))
            }
            Spacer()
            sheetClose { app.sheet = nil }
        }
        .padding(.horizontal, 18).padding(.vertical, 15)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var body_: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("常规") {
                Toggle(isOn: $app.openLastCatalogOnLaunch) {
                    Text("启动时打开上次目录库").font(.system(size: 12.5)).foregroundStyle(Theme.text)
                }.toggleStyle(.switch).tint(Theme.accent)
                HStack(spacing: 12) {
                    Stepper(value: $app.recentImportDays, in: 1...365) {
                        Text("「最近导入」窗口 \(app.recentImportDays) 天")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.text)
                    }
                    Spacer()
                }
            }

            section("导入") {
                row("导入模式") {
                    Segmented(options: [
                        SegOption(value: "referenced", label: "引用式"),
                        SegOption(value: "managed", label: "托管式"),
                    ], value: app.importMode.rawValue,
                       onChange: { app.importMode = ImportMode(rawValue: $0) ?? .referenced }, size: "sm")
                }
                Text(app.importMode == .managed
                     ? "托管式：导入时复制原件到目录库 Originals/\(app.managedArchiveRule == .camera ? "<相机>/YYYY/MM" : "YYYY/MM/DD")。"
                     : "引用式：只索引，原件保留在原位置（推荐）。")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                if app.importMode == .managed {
                    row("归档规则") {
                        Segmented(options: [
                            SegOption(value: "date", label: "按日期"),
                            SegOption(value: "camera", label: "按相机"),
                        ], value: app.managedArchiveRule.rawValue,
                           onChange: { app.managedArchiveRule = ManagedArchiveRule(rawValue: $0) ?? .date },
                           size: "sm")
                    }
                }
                row("重复处理") {
                    Segmented(options: [
                        SegOption(value: "groupExact", label: "分组"),
                        SegOption(value: "skipExact", label: "跳过"),
                        SegOption(value: "keep", label: "保留"),
                    ], value: app.importDuplicateStrategy.rawValue,
                       onChange: {
                        app.importDuplicateStrategy = ImportDuplicateStrategy(rawValue: $0) ?? .groupExact
                    }, size: "sm")
                }
                row("导入后关键词") {
                    settingsTextField("逗号分隔", text: $app.importPostKeywords)
                }
                row("导入后颜色") {
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
                row("导入后相册") {
                    settingsTextField("相册名", text: $app.importPostAlbumName)
                }
                Toggle(isOn: $app.visionEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("导入时 Vision 分析（场景标签 + 人脸）").font(.system(size: 12.5)).foregroundStyle(Theme.text)
                        Text("完全在本机进行，照片不会离开设备。").font(.system(size: 11)).foregroundStyle(Theme.text3)
                    }
                }.toggleStyle(.switch).tint(Theme.accent)
            }

            section("导出") {
                row("目录结构") {
                    Segmented(options: [
                        SegOption(value: "flat", label: "平铺"),
                        SegOption(value: "date", label: "日期"),
                        SegOption(value: "sourceFolder", label: "源文件夹"),
                        SegOption(value: "album", label: "相册"),
                    ], value: app.exportDirectoryStructure.rawValue,
                       onChange: {
                        app.exportDirectoryStructure = ExportDirectoryStructure(rawValue: $0) ?? .flat
                    }, size: "sm")
                }
                Toggle(isOn: $app.exportWritesXMP) {
                    Text("导出时写入 XMP sidecar").font(.system(size: 12.5)).foregroundStyle(Theme.text)
                }.toggleStyle(.switch).tint(Theme.accent)
                HStack(spacing: 9) {
                    TextField("预设名", text: $exportPresetName)
                        .textFieldStyle(.plain).font(.system(size: 12.5))
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(Color.black.opacity(0.28))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line2, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .frame(width: 140)
                    ghostButton(nil, "保存为预设", small: true) {
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
                            Text("应用预设").font(.system(size: 12)).foregroundStyle(Theme.accent)
                        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                    Spacer()
                }
                HStack(spacing: 9) {
                    ghostButton("eye", "导出选中预览图", small: true) { app.exportSelectionPreviews() }
                    Spacer()
                }
            }

            section("元数据") {
                Toggle(isOn: $app.readXMPSidecar) {
                    Text("导入时读取 XMP sidecar").font(.system(size: 12.5)).foregroundStyle(Theme.text)
                }.toggleStyle(.switch).tint(Theme.accent)
                Toggle(isOn: $app.autoWriteXMPSidecar) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("编辑时自动写入 XMP sidecar").font(.system(size: 12.5)).foregroundStyle(Theme.text)
                        Text("评分 / 关键词 / 标题等改动会写入同名 .xmp，不改动原图。")
                            .font(.system(size: 11)).foregroundStyle(Theme.text3)
                    }
                }.toggleStyle(.switch).tint(Theme.accent)
            }

            section("缩略图与缓存") {
                row("预览长边") {
                    Segmented(options: [
                        SegOption(value: "1600", label: "1600px"),
                        SegOption(value: "2048", label: "2048px"),
                    ], value: "\(app.previewMaxPixel)",
                       onChange: { app.previewMaxPixel = Int($0) ?? 2_048 }, size: "sm")
                }
                Stepper(value: $app.cacheLimitMB, in: 256...102_400, step: 256) {
                    Text("缓存上限 \(app.cacheLimitMB) MB")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.text)
                }
                HStack(spacing: 9) {
                    ghostButton("refresh", "重建缩略图", small: true) { app.rebuildThumbnails() }
                    ghostButton("trash", "清理缓存", small: true) { app.clearCache() }
                    ghostButton("check", "应用上限", small: true) { app.pruneCacheToLimit() }
                }
            }

            section("性能") {
                Toggle(isOn: $app.reduceBackgroundOnLowPower) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("低电量模式下减少后台任务").font(.system(size: 12.5)).foregroundStyle(Theme.text)
                        Text("开启「低电量模式」时暂停后台缩略图补齐，节省电量。")
                            .font(.system(size: 11)).foregroundStyle(Theme.text3)
                    }
                }.toggleStyle(.switch).tint(Theme.accent)
            }

            section("维护") {
                row("自动备份") {
                    Segmented(options: [
                        SegOption(value: "off", label: "关闭"),
                        SegOption(value: "daily", label: "每天"),
                        SegOption(value: "weekly", label: "每周"),
                    ], value: app.automaticBackupFrequency,
                       onChange: { app.automaticBackupFrequency = $0 }, size: "sm")
                }
                HStack(spacing: 9) {
                    ghostButton("check", "立即备份", small: true) { app.runBackup() }
                    ghostButton("refresh", "恢复备份", small: true) { app.restoreBackup() }
                    ghostButton("info", "运行健康检查", small: true) { app.runHealthCheck() }
                }
                if let r = app.healthReport {
                    Text(r.summary).font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(r.isHealthy ? Theme.text2 : Theme.redSoft)
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.24))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
            }

            section("批量重命名") {
                Text("按命名模板重命名选中已导入照片的原件。可用占位符：{seq} {date} {time} {camera} {original}（纯前缀等价于「前缀_{seq}」）。")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                HStack(spacing: 9) {
                    TextField("如 {date}_{seq} 或 IMG", text: $renamePrefix)
                        .textFieldStyle(.plain).font(.system(size: 12.5))
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(Color.black.opacity(0.28))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line2, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .frame(width: 200)
                    ghostButton(nil, "重命名选中", small: true) { app.batchRename(template: renamePrefix) }
                    Spacer()
                }
            }

            section("原件文件") {
                Text("复制不会改变目录库路径；移动成功后会更新目录库中的原件位置。")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                HStack(spacing: 9) {
                    ghostButton("copy", "复制选中原件", small: true) { app.copySelectedOriginals() }
                    ghostButton("folder", "移动选中原件", danger: true, small: true) { app.moveSelectedOriginals() }
                    ghostButton("trash", "移到废纸篓", danger: true, small: true) { app.trashSelectedOriginals() }
                    Spacer()
                }
            }

            section("批量调整拍摄时间") {
                Text("对选中照片整体平移拍摄时间（时区/相机时钟校正），或统一设为指定时间。")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                HStack(spacing: 12) {
                    Stepper(value: $shiftHours, in: -72...72) {
                        Text("\(shiftHours > 0 ? "+" : "")\(shiftHours) 时")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.text)
                    }
                    Stepper(value: $shiftMinutes, in: -59...59) {
                        Text("\(shiftMinutes > 0 ? "+" : "")\(shiftMinutes) 分")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.text)
                    }
                    ghostButton(nil, "平移选中", small: true) {
                        app.shiftCaptureTime(hours: shiftHours, minutes: shiftMinutes)
                    }
                    Spacer()
                }
                HStack(spacing: 12) {
                    DatePicker("", selection: $absoluteDate)
                        .labelsHidden().datePickerStyle(.compact)
                    ghostButton(nil, "设为该时间", small: true) { app.setCaptureDate(absoluteDate) }
                    Spacer()
                }
            }

            section("目录库") {
                HStack(spacing: 9) {
                    ghostButton("plus", "新建目录库", small: true) { app.createCatalog() }
                    ghostButton("folder", "打开目录库", small: true) { app.openCatalog() }
                    ghostButton("trash", "清除最近", small: true) { app.clearRecentCatalogs() }
                }
                Text(app.catalogPath)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            section("隐私") {
                Text("本地优先 · 仅访问授权的文件夹。可清除以下本地数据。")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                HStack(spacing: 9) {
                    ghostButton("trash", "清除日志", small: true) { app.clearLogs() }
                    ghostButton("trash", "清除安全书签", small: true) { app.clearSecurityBookmarks() }
                }
            }
        }
        .padding(18)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 11, weight: .bold)).tracking(0.3)
                .foregroundStyle(Theme.text3).textCase(.uppercase)
            content()
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label).font(.system(size: 12.5)).foregroundStyle(Theme.text2)
            Spacer()
            content()
        }
    }

    private func settingsTextField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain).font(.system(size: 12.5))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.black.opacity(0.28))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line2, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .frame(width: 220)
    }

    private var foot: some View {
        HStack {
            Spacer()
            Button { app.sheet = nil } label: {
                Text("完成").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 17).padding(.vertical, 8)
                    .background(Theme.accent).clipShape(RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
        .background(Color.black.opacity(0.18))
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}
