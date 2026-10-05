// ============================================================
//  Web gallery — what the page says and how big its photos are, then where it goes
// ============================================================
import AppKit
import SwiftUI

struct WebGallerySheet: View {
    @Environment(AppState.self) private var app
    @State private var settings: WebGallerySettings
    let count: Int
    let defaultTitle: String

    init(settings: WebGallerySettings, count: Int, defaultTitle: String) {
        _settings = State(initialValue: settings)
        self.count = count
        self.defaultTitle = defaultTitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("网页画廊").font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            Text("把 \(count) 张照片（选中多张时为所选照片，否则为当前列表）连同一个网页存进一个文件夹：点开缩略图看大图，可用方向键或滑动翻看。文件夹可直接放到任何网站空间。")
                .font(.system(size: 12)).foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("标题").gridColumnAlignment(.trailing)
                    TextField(defaultTitle, text: $settings.title).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("副标题")
                    TextField("例如摄影师和联系方式", text: $settings.subtitle).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("配色")
                    Picker("配色", selection: $settings.theme) {
                        ForEach(WebGallerySettings.Theme.allCases, id: \.self) { theme in Text(theme.title).tag(theme) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                GridRow {
                    Text("照片文字")
                    Picker("照片文字", selection: $settings.caption) {
                        ForEach(WebGallerySettings.Caption.allCases, id: \.self) { caption in Text(caption.title).tag(caption) }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    Toggle("大图下显示相机、镜头和曝光", isOn: $settings.showDetails).toggleStyle(.checkbox)
                }
                GridRow {
                    Text("大图")
                    Picker("大图", selection: $settings.largeSize) {
                        ForEach(WebGallerySettings.largeSizes, id: \.self) { edge in Text(L("长边 \(String(edge)) 像素")).tag(edge) }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("缩略图")
                    Picker("缩略图", selection: $settings.thumbnailSize) {
                        ForEach(WebGallerySettings.thumbnailSizes, id: \.self) { edge in Text(L("短边 \(String(edge)) 像素")).tag(edge) }
                    }
                    .labelsHidden()
                }
            }
            Text("照片按修图后的样子以 sRGB JPEG 输出，不含元数据。")
                .font(.system(size: 11)).foregroundStyle(Theme.text3)
            HStack {
                Spacer()
                ghostButton(nil, L("取消")) { app.sheet = nil }
                Button {
                    export()
                } label: {
                    Text("导出…").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 17).padding(.vertical, 8)
                        .background(Theme.accentFill).clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 500)
        .font(.system(size: 13))
        .foregroundStyle(Theme.text)
        .background(Theme.bgPanel)
    }

    private func export() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("导出")
        panel.message = L("选择存放网页画廊的位置，画廊会存进其中一个新文件夹")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        app.webGallerySettings = settings
        app.exportWebGallery(to: url)
    }
}
