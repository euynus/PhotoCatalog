// ============================================================
//  Print dialog — paper and layout on the left, the page as it prints on the right
// ============================================================
import SwiftUI
import AppKit

struct PrintSheet: View {
    @Environment(AppState.self) private var app
    let items: [PrintItem]
    @State private var settings: PrintSettings
    @State private var page = 0
    @State private var preview: CGImage?
    @State private var profiles: [SoftProofing.Profile] = []

    /// The preview draws with the print's own layout and code, at a screen resolution.
    private static let previewResolution: Double = 150
    private static let previewQueue = DispatchQueue(label: "PhotoCatalog.print-preview", qos: .userInitiated)

    init(settings: PrintSettings, items: [PrintItem]) {
        self.items = items
        _settings = State(initialValue: settings)
    }

    private var pageCount: Int { settings.pageCount(photos: items.count) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 9) {
                    Image(systemName: "printer").foregroundStyle(Theme.accent)
                    Text("打印 \(items.count) 张照片").font(.system(size: 17, weight: .semibold))
                }
                Spacer()
                sheetClose { app.sheet = nil }
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Theme.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }

            HStack(spacing: 0) {
                form.frame(width: 360)
                Rectangle().fill(Theme.line).frame(width: 1)
                pagePreview
            }

            footer
        }
        .frame(width: 900, height: 660)
        .font(.system(size: 13))
        .foregroundStyle(Theme.text)
        .background(Theme.bgPanel)
        .onAppear { profiles = [SoftProofing.Profile(id: "", name: L("由打印机管理"))] + SoftProofing.profiles() }
        .task(id: PreviewKey(settings: settings, page: page)) {
            // a moment's pause, so dragging a slider renders once
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            var looks = settings
            looks.resolution = Self.previewResolution
            let renderer = PrintRenderer(items: items, settings: looks)
            let index = min(page, max(0, renderer.pageCount - 1))
            let image = await withCheckedContinuation { continuation in
                Self.previewQueue.async { continuation.resume(returning: renderer.pageImage(index, scale: 2)) }
            }
            if !Task.isCancelled { preview = image }
        }
    }

    private struct PreviewKey: Equatable {
        let settings: PrintSettings
        let page: Int
    }

    // ---- settings ----
    private var form: some View {
        Form {
            Section("纸张") {
                Picker("尺寸", selection: $settings.paper) {
                    ForEach(PrintSettings.Paper.allCases) { Text($0.title).tag($0) }
                }
                Picker("方向", selection: $settings.orientation) {
                    ForEach(PrintSettings.Orientation.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("边距") {
                    HStack {
                        Slider(value: Binding(get: { settings.margin / 72 * 25.4 }, set: { settings.margin = $0 / 25.4 * 72 }),
                               in: 0...40, step: 1)
                        Text("\(Int((settings.margin / 72 * 25.4).rounded())) mm").monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                }
            }
            Section("版式") {
                Picker("版式", selection: $settings.layout) {
                    ForEach(PrintSettings.Layout.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if settings.layout == .single {
                    Toggle("填满页面（裁切照片）", isOn: $settings.fill)
                } else {
                    Stepper("行：\(settings.rows)", value: $settings.rows, in: 1...12)
                    Stepper("列：\(settings.columns)", value: $settings.columns, in: 1...12)
                    LabeledContent("间距") {
                        HStack {
                            Slider(value: Binding(get: { settings.spacing / 72 * 25.4 }, set: { settings.spacing = $0 / 25.4 * 72 }),
                                   in: 0...20, step: 1)
                            Text("\(Int((settings.spacing / 72 * 25.4).rounded())) mm").monospacedDigit()
                                .frame(width: 48, alignment: .trailing)
                        }
                    }
                }
                Toggle("旋转以适合", isOn: $settings.rotateToFit)
                Picker("标注", selection: $settings.caption) {
                    ForEach(PrintSettings.Caption.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("打印作业") {
                Picker("分辨率", selection: $settings.resolution) {
                    ForEach([150.0, 240, 300, 360], id: \.self) { Text("\(Int($0)) ppi").tag($0) }
                }
                Picker("打印锐化", selection: $settings.sharpenFor) {
                    ForEach([ExportSettings.SharpenFor.none, .mattePaper, .glossyPaper]) { Text($0.title).tag($0) }
                }
                if settings.sharpenFor != .none {
                    Picker("数量", selection: $settings.sharpenAmount) {
                        ForEach(ExportSettings.SharpenAmount.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Picker("色彩管理", selection: Binding(get: { settings.profile ?? "" },
                                                  set: { settings.profile = $0.isEmpty ? nil : $0 })) {
                    ForEach(profiles) { Text($0.name).tag($0.id) }
                }
                if settings.profile != nil {
                    Picker("方法", selection: $settings.intent) {
                        ForEach(SoftProof.Intent.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text("在打印机设置中关闭打印机的色彩管理，以免颜色被转换两次")
                        .font(.system(size: 11)).foregroundStyle(Theme.text3)
                }
            }
        }
        .formStyle(.grouped)
    }

    // ---- the page ----
    private var pagePreview: some View {
        VStack(spacing: 10) {
            GeometryReader { geometry in
                let size = settings.pageSize
                let scale = min((geometry.size.width - 40) / size.width, (geometry.size.height - 20) / size.height)
                ZStack {
                    Rectangle().fill(.white)
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
                Text("第 \(min(page, max(0, pageCount - 1)) + 1) 页，共 \(pageCount) 页").monospacedDigit()
                Button { page = min(pageCount - 1, page + 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(page >= pageCount - 1)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
        }
        .padding(16)
        .background(Theme.bgContent)
        .onChange(of: pageCount) { page = min(page, max(0, pageCount - 1)) }
    }

    private var summary: String {
        var parts = [settings.paper.title, settings.orientation.title, settings.layout.title, "\(Int(settings.resolution)) ppi"]
        if settings.layout == .contactSheet { parts[2] = L("联系表 \(String(settings.rows)) × \(String(settings.columns))") }
        if settings.profile != nil { parts.append(L("应用管理颜色")) }
        return parts.joined(separator: " · ")
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Text(summary).font(.system(size: 12)).foregroundStyle(Theme.text3)
            Spacer()
            ghostButton(nil, L("取消")) { app.sheet = nil }
            ghostButton("pdf", L("存储为 PDF…")) { app.savePrintPDF(settings) }
                .disabled(items.isEmpty)
            Button { app.printPhotos(settings) } label: {
                Label("打印…", systemImage: "printer")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.onAccent)
                    .fixedSize()
                    .padding(.horizontal, 17).padding(.vertical, 8)
                    .background(Theme.accentFill).clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(items.isEmpty)
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(Theme.bgSidebar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}
