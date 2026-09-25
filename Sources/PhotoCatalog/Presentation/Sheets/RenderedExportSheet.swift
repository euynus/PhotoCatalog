// ============================================================
//  Export dialog — presets on the left, settings on the right
// ============================================================
import SwiftUI
import AppKit

struct RenderedExportSheet: View {
    @Environment(AppState.self) private var app
    /// A photo to preview the file name with.
    let sample: RenderedExportItem?
    let count: Int

    @State private var settings: ExportSettings
    @State private var folder: String
    @State private var savingPreset = false
    @State private var presetName = ""

    init(settings: ExportSettings, folder: String, sample: RenderedExportItem?, count: Int) {
        self.sample = sample
        self.count = count
        _settings = State(initialValue: settings)
        _folder = State(initialValue: folder)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 9) {
                    Image(systemName: "square.and.arrow.up").foregroundStyle(Theme.accent)
                    Text("导出 \(count) 张照片").font(.system(size: 17, weight: .semibold))
                }
                Spacer()
                sheetClose { app.sheet = nil }
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Theme.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }

            HStack(spacing: 0) {
                presetColumn
                    .frame(width: 210)
                Rectangle().fill(Theme.line).frame(width: 1)
                form
            }

            footer
        }
        .frame(width: 840, height: 640)
        .font(.system(size: 13))
        .foregroundStyle(Theme.text)
        .background(Theme.bgPanel)
    }

    // ---- presets ----
    private var presetColumn: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { app.allRenderedExportPresets.first { $0.settings == settings }?.id },
                                    set: { id in
                                        if let preset = app.allRenderedExportPresets.first(where: { $0.id == id }) {
                                            settings = preset.settings
                                        }
                                    })) {
                Section("内置预设") {
                    ForEach(RenderedExportPreset.builtIns) { preset in Text(preset.name).tag(preset.id) }
                }
                if !app.renderedExportPresets.isEmpty {
                    Section("我的预设") {
                        ForEach(app.renderedExportPresets) { preset in
                            Text(preset.name).tag(preset.id)
                                .contextMenu {
                                    Button("删除预设", role: .destructive) { app.deleteRenderedExportPreset(preset.id) }
                                }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            Button("存储为预设…") {
                presetName = ""
                savingPreset = true
            }
            .controlSize(.small)
            .padding(10)
            .popover(isPresented: $savingPreset, arrowEdge: .top) {
                VStack(alignment: .trailing, spacing: 10) {
                    TextField("预设名称", text: $presetName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(savePreset)
                    Button("存储", action: savePreset)
                        .keyboardShortcut(.defaultAction)
                        .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(12)
                .frame(width: 240)
            }
        }
        .background(Theme.bgSidebar)
    }

    private func savePreset() {
        guard !presetName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        app.saveRenderedExportPreset(name: presetName, settings: settings)
        savingPreset = false
    }

    // ---- settings ----
    private var form: some View {
        Form {
            Section("导出位置") {
                LabeledContent(L("文件夹", table: "Context")) {
                    HStack(spacing: 8) {
                        Text((folder as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(Theme.text2)
                        Button("选择…", action: chooseFolder)
                    }
                }
                TextField("放入子文件夹", text: $settings.subfolder, prompt: Text("可选"))
                Picker("文件已存在时", selection: $settings.collision) {
                    ForEach(ExportSettings.Collision.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("文件命名") {
                LabeledContent("文件名") {
                    HStack(spacing: 6) {
                        TextField("文件名", text: $settings.fileNameTemplate).labelsHidden()
                        Menu("插入") {
                            ForEach(ExportSettings.fileNameTokens, id: \.token) { token in
                                Button("\(token.title)  \(token.token)") { settings.fileNameTemplate += token.token }
                            }
                        }
                        .fixedSize()
                    }
                }
                if settings.fileNameTemplate.contains("{seq}") {
                    TextField("起始序号", value: $settings.sequenceStart, format: .number)
                }
                LabeledContent("示例") {
                    Text(exampleName).foregroundStyle(Theme.text2).lineLimit(1).truncationMode(.middle)
                }
            }
            Section("文件设置") {
                Picker("格式", selection: $settings.format) {
                    ForEach(ExportSettings.Format.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if settings.format.isLossy {
                    LabeledContent("品质") {
                        HStack {
                            Slider(value: Binding(get: { settings.quality },
                                                  set: { settings.quality = ($0 * 100).rounded() / 100 }),
                                   in: 0.3...1)
                            Text("\(Int((settings.quality * 100).rounded()))").monospacedDigit().frame(width: 30)
                        }
                    }
                } else {
                    Toggle("16 位/通道", isOn: $settings.sixteenBit)
                }
                Picker("色彩空间", selection: $settings.colorSpace) {
                    ForEach(ExportSettings.ColorSpace.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("调整图像大小") {
                Picker("尺寸", selection: $settings.resize) {
                    ForEach(ExportSettings.Resize.allCases) { Text($0.title).tag($0) }
                }
                switch settings.resize {
                case .none:
                    EmptyView()
                case .longEdge, .shortEdge:
                    TextField("像素", value: $settings.edge, format: .number)
                case .fitWithin:
                    TextField("最大宽度（像素）", value: $settings.maxWidth, format: .number)
                    TextField("最大高度（像素）", value: $settings.maxHeight, format: .number)
                }
                if settings.resize != .none {
                    Toggle("允许放大", isOn: $settings.allowEnlarge)
                }
            }
            Section("元数据") {
                Picker("包含", selection: $settings.metadata) {
                    ForEach(ExportSettings.Metadata.allCases) { Text($0.title).tag($0) }
                }
                Toggle("移除位置信息", isOn: $settings.removeLocation)
                    .disabled(settings.metadata != .all)
            }
            Section("水印") {
                Toggle("添加文字水印", isOn: Binding(get: { settings.watermarkEnabled }, set: { on in
                    settings.watermarkEnabled = on
                    if on && settings.watermark.isEmpty { settings.watermark = "© \(NSFullUserName())" }
                }))
                if settings.watermarkEnabled {
                    TextField("水印文字", text: $settings.watermark)
                }
            }
            Section("导出后") {
                Toggle("在访达中显示", isOn: $settings.revealInFinder)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var exampleName: String {
        guard let sample else { return "—" }
        return settings.fileName(original: sample.baseName, sequence: settings.sequenceStart, date: sample.date,
                                 camera: sample.camera, title: sample.title, rating: sample.rating)
            + "." + settings.format.fileExtension
    }

    private var summary: String {
        var parts = [settings.format.title, settings.colorSpace.title]
        switch settings.resize {
        case .none: parts.append(L("原始尺寸"))
        case .longEdge: parts.append(L("长边 \(String(settings.edge)) px"))
        case .shortEdge: parts.append(L("短边 \(String(settings.edge)) px"))
        case .fitWithin: parts.append(L("\(String(settings.maxWidth)) × \(String(settings.maxHeight)) 以内"))
        }
        if settings.watermarkEnabled { parts.append(L("水印")) }
        return parts.joined(separator: " · ")
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Text(summary).font(.system(size: 12)).foregroundStyle(Theme.text3)
            Spacer()
            ghostButton(nil, L("取消")) { app.sheet = nil }
            Button(action: export) {
                Label("导出", systemImage: "square.and.arrow.up")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.onAccent)
                    .fixedSize()
                    .padding(.horizontal, 17).padding(.vertical, 8)
                    .background(Theme.accentFill).clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(count == 0)
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(Theme.bgSidebar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("选择")
        panel.directoryURL = URL(fileURLWithPath: folder)
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    private func export() {
        var settings = self.settings
        settings.edge = max(16, settings.edge)
        settings.maxWidth = max(16, settings.maxWidth)
        settings.maxHeight = max(16, settings.maxHeight)
        settings.sequenceStart = max(0, settings.sequenceStart)
        app.sheet = nil
        app.startRenderedExport(settings: settings, folder: URL(fileURLWithPath: folder, isDirectory: true))
    }
}
