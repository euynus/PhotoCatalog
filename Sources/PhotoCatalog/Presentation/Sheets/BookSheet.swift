// ============================================================
//  Photo book — page size, layout and words, with the pages previewed, saved as a PDF
// ============================================================
import SwiftUI

struct BookSheet: View {
    @Environment(AppState.self) private var app
    @State private var settings: BookSettings
    @State private var page = 0
    @State private var preview: CGImage?
    let items: [BookItem]

    private static let previewQueue = DispatchQueue(label: "PhotoCatalog.book-preview", qos: .userInitiated)

    init(settings: BookSettings, items: [BookItem]) {
        _settings = State(initialValue: settings)
        self.items = items
    }

    /// The pages as laid out now (cheap: no photo is rendered).
    private var pages: [BookPage] { BookLayout.pages(items.map(\.item.aspect), settings: settings) }

    var body: some View {
        let pageCount = pages.count
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 9) {
                    Image(systemName: "book").foregroundStyle(Theme.accent)
                    Text("画册：\(items.count) 张照片").font(.system(size: 17, weight: .semibold))
                }
                Spacer()
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Theme.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }

            HStack(spacing: 0) {
                form.frame(width: 340)
                Rectangle().fill(Theme.line).frame(width: 1)
                pagePreview(pageCount)
            }

            HStack(spacing: 9) {
                Text(L("\(settings.size.title) · \(pageCount) 页")).font(.system(size: 12)).foregroundStyle(Theme.text3)
                Spacer()
                ghostButton(nil, L("取消")) { app.sheet = nil }
                Button { app.saveBookPDF(settings) } label: {
                    Label("存储为 PDF…", systemImage: "doc.richtext")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.onAccent)
                        .fixedSize()
                        .padding(.horizontal, 17).padding(.vertical, 8)
                        .background(Theme.accentFill).clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(items.isEmpty)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        }
        .frame(width: 900, height: 640)
        .font(.system(size: 13))
        .foregroundStyle(Theme.text)
        .background(Theme.bgPanel)
        .task(id: PreviewKey(settings: settings, page: page)) {
            // a moment's pause, so typing a title renders once
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let renderer = BookRenderer(items: items, settings: settings)
            renderer.resolution = 150
            let index = min(page, max(0, renderer.pages.count - 1))
            let image = await withCheckedContinuation { continuation in
                Self.previewQueue.async { continuation.resume(returning: renderer.pageImage(index, scale: 2)) }
            }
            if !Task.isCancelled { preview = image }
        }
        .onChange(of: pageCount) { page = min(page, max(0, pageCount - 1)) }
    }

    private struct PreviewKey: Equatable {
        let settings: BookSettings
        let page: Int
    }

    private var form: some View {
        Form {
            Section("页面") {
                Picker("尺寸", selection: $settings.size) {
                    ForEach(BookSettings.Size.allCases, id: \.self) { size in Text(size.title).tag(size) }
                }
                Picker("版式", selection: $settings.layout) {
                    ForEach(BookSettings.Layout.allCases, id: \.self) { layout in Text(layout.title).tag(layout) }
                }
                .help("自动：与页面同向的照片单独一页，另一方向的两张并排或上下排在一页")
                Picker("边距", selection: $settings.margin) {
                    ForEach(BookSettings.Margin.allCases, id: \.self) { margin in Text(margin.title).tag(margin) }
                }
                Picker("背景", selection: $settings.background) {
                    ForEach(BookSettings.Background.allCases, id: \.self) { background in Text(background.title).tag(background) }
                }
                .pickerStyle(.segmented)
            }
            Section("文字") {
                Toggle("封面", isOn: $settings.cover)
                if settings.cover {
                    TextField("标题", text: $settings.title)
                    TextField("副标题", text: $settings.subtitle)
                }
                Picker("照片文字", selection: $settings.caption) {
                    ForEach(BookSettings.Caption.allCases, id: \.self) { caption in Text(caption.title).tag(caption) }
                }
                Toggle("页码", isOn: $settings.pageNumbers)
                    .disabled(settings.margin == .none)
                    .help("页码印在下边距里；满版时没有边距可印")
            }
        }
        .formStyle(.grouped)
    }

    private func pagePreview(_ pageCount: Int) -> some View {
        VStack(spacing: 10) {
            GeometryReader { geometry in
                let size = settings.size.points
                let scale = min((geometry.size.width - 40) / size.width, (geometry.size.height - 20) / size.height)
                ZStack {
                    Rectangle().fill(settings.background == .black ? Color.black : .white)
                        .frame(width: size.width * scale, height: size.height * scale)
                        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                    if let preview {
                        Image(decorative: preview, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: size.width * scale, height: size.height * scale)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 12) {
                Button { page = max(0, page - 1) } label: { Image(systemName: "chevron.left") }
                    .disabled(page == 0)
                Text(settings.cover && page == 0 ? L("封面，共 \(pageCount) 页")
                     : L("第 \(min(page, max(0, pageCount - 1)) + 1) 页，共 \(pageCount) 页")).monospacedDigit()
                Button { page = min(pageCount - 1, page + 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(page >= pageCount - 1)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
        }
        .padding(16)
        .background(Theme.bgContent)
    }
}
