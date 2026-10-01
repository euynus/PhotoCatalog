// ============================================================
//  Tethered capture — starting a session (Lightroom's Tethered Capture Settings)
// ============================================================
import AppKit
import SwiftUI

/// Where shots come from (a camera on a cable, or a folder another app saves them to), the
/// session's name and folder, how shots are named, and the preset and keywords they get.
struct TetherSheet: View {
    @Environment(AppState.self) private var app
    @State private var settings: TetherSettings
    /// A camera's id, or "folder" to watch a folder.
    @State private var source: String

    init(settings: TetherSettings, cameras: [CameraDevice]) {
        _settings = State(initialValue: settings)
        _source = State(initialValue: settings.watchedFolderPath.isEmpty ? cameras.first?.id ?? "folder" : "folder")
    }

    private var cameras: [CameraDevice] { app.cameraDevices.filter { !$0.isPhone } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("联机拍摄").font(.system(size: 15, weight: .semibold))
                Spacer()
                sheetClose { app.sheet = nil }
            }
            Text("拍下的照片直接存入会话文件夹、导入目录库并立即显示。macOS 能控制的相机用数据线连接；其他相机可以让厂商的联机软件（如 EOS Utility）把照片存进一个文件夹，由这里监视导入。")
                .font(.system(size: 12)).foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("来源").gridColumnAlignment(.trailing)
                    Picker("来源", selection: $source) {
                        ForEach(cameras) { camera in Label(camera.name, systemImage: "camera").tag(camera.id) }
                        if !cameras.isEmpty { Divider() }
                        Label("监视文件夹", systemImage: "folder").tag("folder")
                    }
                    .labelsHidden()
                }
                if source == "folder" {
                    GridRow {
                        Color.clear.frame(width: 1, height: 1)
                        VStack(alignment: .leading, spacing: 4) {
                            folderRow(settings.watchedFolderPath, placeholder: L("尚未选择")) {
                                if let url = chooseFolder(L("选择联机软件保存照片的文件夹")) { settings.watchedFolderPath = url.path }
                            }
                            Text("开始前已在文件夹中的照片不会导入")
                                .font(.system(size: 11)).foregroundStyle(Theme.text3)
                        }
                    }
                }
                GridRow {
                    Text("会话名称")
                    TextField(settings.folderName(), text: $settings.sessionName)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("保存到")
                    folderRow(settings.destinationPath, placeholder: "") {
                        if let url = chooseFolder(L("选择保存联机拍摄会话的文件夹")) { settings.destinationPath = url.path }
                    }
                }
                GridRow {
                    Text("文件命名")
                    Picker("文件命名", selection: $settings.naming) {
                        ForEach(TetherSettings.Naming.allCases, id: \.self) { naming in Text(naming.title).tag(naming) }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("修图预设")
                    Picker("修图预设", selection: $settings.presetId) {
                        Text("无").tag("")
                        ForEach(app.allDevelopPresets) { preset in Text(preset.name).tag(preset.id) }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("关键词")
                    TextField("用逗号分隔", text: $settings.keywords)
                        .textFieldStyle(.roundedBorder)
                }
            }
            Text("照片保存在“\(settings.folderName())”文件夹中，以引用方式编入目录库。")
                .font(.system(size: 11)).foregroundStyle(Theme.text3)
            HStack {
                Spacer()
                ghostButton(nil, L("取消")) { app.sheet = nil }
                Button {
                    var next = settings
                    if source != "folder" { next.watchedFolderPath = "" }
                    let camera = cameras.first { $0.id == source }
                    app.sheet = nil
                    app.startTether(next, camera: camera)
                } label: {
                    Text("开始").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 17).padding(.vertical, 8)
                        .background(Theme.accentFill).clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(source == "folder" && settings.watchedFolderPath.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 500)
        .font(.system(size: 13))
        .foregroundStyle(Theme.text)
        .background(Theme.bgPanel)
    }

    private func folderRow(_ path: String, placeholder: String, choose: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(path.isEmpty ? placeholder : (path as NSString).abbreviatingWithTildeInPath)
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(path.isEmpty ? Theme.text3 : Theme.text2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("选择…", action: choose).controlSize(.small)
        }
    }

    private func chooseFolder(_ message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// While a session runs: where shots come from, how many came, the preset they get, and the
/// shutter when the camera takes one on command.
struct TetherBar: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if let status = app.tether {
            HStack(spacing: 10) {
                Image(systemName: status.canCapture ? "camera.fill" : "folder.fill").foregroundStyle(Theme.accent)
                Text(status.sourceName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(status.folder.lastPathComponent).font(.system(size: 12)).foregroundStyle(Theme.text2).lineLimit(1)
                Text("已拍 \(status.shots) 张").font(.system(size: 12)).foregroundStyle(Theme.text2).monospacedDigit()
                if let last = status.lastName {
                    Text(last).font(.system(size: 11)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
                }
                if status.failed > 0 {
                    Text("\(status.failed) 张失败").font(.system(size: 11)).foregroundStyle(Theme.yellow)
                }
                if status.working { ProgressView().controlSize(.small) }
                Spacer(minLength: 8)
                Menu {
                    Button("无") { app.setTetherPreset("") }
                    Divider()
                    ForEach(app.allDevelopPresets) { preset in Button(preset.name) { app.setTetherPreset(preset.id) } }
                } label: {
                    Text(app.allDevelopPresets.first { $0.id == app.tetherSettings.presetId }.map { L("预设：\($0.name)") } ?? L("预设：无"))
                        .font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("之后拍下的照片使用的修图预设")
                if status.canCapture {
                    Button { app.captureTether() } label: { Label("拍摄", systemImage: "camera.shutter.button") }
                        .controlSize(.small)
                        .help("让相机拍一张 (F12)")
                }
                Button("结束") { app.endTether() }
                    .controlSize(.small)
                    .help("结束联机拍摄")
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Theme.bgPanel)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        }
    }
}
