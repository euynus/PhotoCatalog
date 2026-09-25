// ============================================================
//  Memory-card import — pick photos by day, copy them off, catalog the copies
// ============================================================
import SwiftUI
import AppKit
import ImageIO

struct CardImportSheet: View {
    @Environment(AppState.self) private var app

    @State private var card: CardVolume?
    /// A folder picked instead of a card (a camera in mass-storage mode, a card reader's copy…).
    @State private var customSource: URL?
    @State private var options: CardImportOptions
    @State private var files: [CardFile] = []
    @State private var scanning = false
    @State private var selection: Set<String> = []
    @State private var hideImported = false

    init(card: CardVolume?, options: CardImportOptions) {
        _card = State(initialValue: card)
        _options = State(initialValue: options)
    }

    private var sourceRoot: URL? { customSource ?? card?.dcim }
    private var sourceName: String { customSource?.lastPathComponent ?? card?.name ?? "选择来源" }
    private var chosen: [CardFile] { files.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            head
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    gridBar
                    Rectangle().fill(Theme.line).frame(height: 1)
                    grid
                }
                Rectangle().fill(Theme.line).frame(width: 1)
                optionsForm.frame(width: 330)
            }
            footer
        }
        .frame(width: 1060, height: 720)
        .font(.system(size: 13))
        .foregroundStyle(Theme.text)
        .background(Theme.bgPanel)
        .task(id: sourceRoot) { await scan() }
    }

    // ---- source ----
    private var head: some View {
        HStack(spacing: 12) {
            Image(systemName: "sdcard").foregroundStyle(Theme.accent)
            Text("从存储卡导入").font(.system(size: 17, weight: .semibold))
            Menu {
                ForEach(app.cardVolumes) { volume in
                    Button(volume.name) {
                        card = volume
                        customSource = nil
                    }
                }
                if !app.cardVolumes.isEmpty { Divider() }
                Button("选择文件夹…") {
                    if let url = chooseFolder(prompt: "选择来源", start: nil) { customSource = url }
                }
            } label: {
                Label(sourceName, systemImage: customSource == nil ? "sdcard" : "folder")
            }
            .fixedSize()
            Spacer()
            sheetClose { app.sheet = nil }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func scan() async {
        guard let root = sourceRoot else {
            files = []
            selection = []
            return
        }
        scanning = true
        let index = CardImportService.CatalogIndex(app.assets)
        let found = await Task.detached(priority: .userInitiated) { CardImportService.scan(root, catalog: index) }.value
        guard root == sourceRoot else { return }
        files = found
        selection = Set(found.filter { !$0.alreadyImported }.map(\.id))
        scanning = false
    }

    // ---- photos ----
    private var gridBar: some View {
        HStack(spacing: 12) {
            Button("全选") { selection = Set(visibleFiles.map(\.id)) }
            Button("全不选") { selection = [] }
            Toggle("隐藏已导入", isOn: $hideImported)
                .toggleStyle(.checkbox)
            Spacer()
            let imported = files.filter(\.alreadyImported).count
            if imported > 0 {
                Text("\(imported) 张已在目录库中").foregroundStyle(Theme.text3)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var visibleFiles: [CardFile] { hideImported ? files.filter { !$0.alreadyImported } : files }

    /// Photos grouped by the day they were shot, oldest first.
    private var days: [(key: String, files: [CardFile])] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        var order: [String] = []
        var groups: [String: [CardFile]] = [:]
        for file in visibleFiles {
            let key = formatter.string(from: file.modified)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(file)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    @ViewBuilder
    private var grid: some View {
        if sourceRoot == nil {
            ContentUnavailableView {
                Label("未检测到存储卡", systemImage: "sdcard")
            } description: {
                Text("插入存储卡，或选择一个包含照片的文件夹。")
            } actions: {
                Button("选择文件夹…") {
                    if let url = chooseFolder(prompt: "选择来源", start: nil) { customSource = url }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if scanning && files.isEmpty {
            ProgressView("正在读取「\(sourceName)」…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visibleFiles.isEmpty {
            ContentUnavailableView(files.isEmpty ? "没有找到照片" : "照片都已导入", systemImage: "photo.on.rectangle")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
                    ForEach(days, id: \.key) { day in
                        Section {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 10)], spacing: 10) {
                                ForEach(day.files) { file in
                                    CardThumbCell(file: file, selected: selection.contains(file.id)) {
                                        if selection.contains(file.id) {
                                            selection.remove(file.id)
                                        } else {
                                            selection.insert(file.id)
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 14)
                        } header: {
                            dayHeader(day.key, day.files)
                        }
                    }
                }
                .padding(.bottom, 14)
            }
        }
    }

    private func dayHeader(_ key: String, _ files: [CardFile]) -> some View {
        let ids = Set(files.map(\.id))
        let all = ids.isSubset(of: selection)
        return HStack {
            Text(dayTitle(key)).font(.system(size: 12, weight: .semibold))
            Text("\(files.count) 张").foregroundStyle(Theme.text3)
            Spacer()
            Button(all ? "取消选择此日" : "选择此日") {
                if all { selection.subtract(ids) } else { selection.formUnion(ids) }
            }
            .buttonStyle(.link)
            .font(.system(size: 12))
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Theme.bgPanel)
    }

    private func dayTitle(_ key: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: key) else { return key }
        return DateFmt.long(date, withTime: false)
    }

    // ---- options ----
    private var optionsForm: some View {
        @Bindable var app = app
        return Form {
            Section("目标位置") {
                LabeledContent("文件夹") {
                    HStack(spacing: 8) {
                        Text((options.destination.path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(Theme.text2)
                        Button("选择…") {
                            if let url = chooseFolder(prompt: "选择", start: options.destination) {
                                options.destination = url
                            }
                        }
                    }
                }
                Picker("整理方式", selection: $options.organize) {
                    ForEach(CardImportOptions.Organize.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("文件命名") {
                Toggle("导入时重命名", isOn: $options.rename)
                if options.rename {
                    LabeledContent("模板") {
                        HStack(spacing: 6) {
                            TextField("模板", text: $options.renameTemplate).labelsHidden()
                            Menu("插入") {
                                ForEach(ExportSettings.fileNameTokens.prefix(5), id: \.token) { token in
                                    Button("\(token.title)  \(token.token)") { options.renameTemplate += token.token }
                                }
                            }
                            .fixedSize()
                        }
                    }
                    if options.renameTemplate.contains("{seq}") {
                        TextField("起始序号", value: $options.sequenceStart, format: .number)
                    }
                    LabeledContent("示例") {
                        Text(exampleName).foregroundStyle(Theme.text2).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            Section("备份") {
                Toggle("同时复制到第二位置", isOn: $options.backupEnabled)
                if options.backupEnabled {
                    LabeledContent("备份文件夹") {
                        HStack(spacing: 8) {
                            Text(options.backup.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "未选择")
                                .lineLimit(1).truncationMode(.middle).foregroundStyle(Theme.text2)
                            Button("选择…") {
                                if let url = chooseFolder(prompt: "选择", start: options.backup) { options.backup = url }
                            }
                        }
                    }
                }
            }
            Section("导入时应用") {
                TextField("关键词", text: $app.importPostKeywords, prompt: Text("逗号分隔"))
                TextField("作者", text: $app.importAuthor)
                TextField("版权", text: $app.importCopyright, prompt: Text("© {year} 名字"))
            }
            Section("完成后") {
                Toggle("推出存储卡", isOn: $options.ejectAfter)
                    .disabled(customSource != nil || card == nil)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var exampleName: String {
        guard let file = chosen.first ?? files.first else { return "—" }
        let original = file.url.deletingPathExtension().lastPathComponent
        return FileNameTemplate.render(options.renameTemplate, original: original, sequence: options.sequenceStart,
                                       date: file.modified) + "." + file.url.pathExtension
    }

    private var footer: some View {
        let chosen = self.chosen
        let bytes = chosen.reduce(Int64(0)) { $0 + $1.size }
        let ready = !chosen.isEmpty && (!options.backupEnabled || options.backup != nil)
        return HStack(spacing: 9) {
            Text("已选 \(chosen.count) / \(files.count) 张 · "
                 + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                .font(.system(size: 12)).foregroundStyle(Theme.text3)
            Spacer()
            ghostButton(nil, "取消") { app.sheet = nil }
            Button {
                app.sheet = nil
                app.importFromCard(customSource == nil ? card : nil, files: chosen, options: options)
            } label: {
                Label("导入 \(chosen.count) 张", systemImage: "square.and.arrow.down")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.onAccent)
                    .fixedSize()
                    .padding(.horizontal, 17).padding(.vertical, 8)
                    .background(Theme.accentFill).clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(!ready)
            .opacity(ready ? 1 : 0.5)
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(Theme.bgSidebar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func chooseFolder(prompt: String, start: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        panel.directoryURL = start
        return panel.runModal() == .OK ? panel.url : nil
    }
}

private struct CardThumbCell: View {
    let file: CardFile
    let selected: Bool
    let toggle: () -> Void
    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(Theme.canvasSurface)
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit().padding(4)
                }
            }
            .frame(height: 92)
            .overlay(alignment: .topLeading) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(selected ? Theme.accent : Color.white.opacity(0.85))
                    .background(Circle().fill(selected ? Color.white : Color.black.opacity(0.25)).padding(2))
                    .padding(6)
            }
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 3) {
                    if file.alreadyImported { badge("已导入") }
                    if file.isRaw { badge("RAW") }
                }
                .padding(5)
            }
            .opacity(selected ? 1 : 0.5)
            Text(file.name)
                .font(.system(size: 10)).foregroundStyle(Theme.text2)
                .lineLimit(1).truncationMode(.middle)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .task(id: file.id) { image = await CardThumbnailLoader.shared.thumbnail(for: file.url) }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
    }
}

/// Card thumbnails from the files' embedded previews, decoded off the cooperative pool
/// (RAW decoding can deadlock it) and kept for the life of the app.
@MainActor
private final class CardThumbnailLoader {
    static let shared = CardThumbnailLoader()
    private let cache: NSCache<NSURL, ImageBox> = {
        let cache = NSCache<NSURL, ImageBox>()
        cache.countLimit = 3000
        return cache
    }()

    func thumbnail(for url: URL) async -> CGImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit.image }
        let box = await ThumbnailRepairQueue.run(.visible) { () -> ImageBox? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 240,
                  ] as CFDictionary) else { return nil }
            return ImageBox(image)
        } ?? nil
        if let box { cache.setObject(box, forKey: url as NSURL) }
        return box?.image
    }
}
