// ============================================================
//  Slideshow settings — timing, look and music, then play or export a video
// ============================================================
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SlideshowSheet: View {
    @Environment(AppState.self) private var app
    @State private var settings: SlideshowSettings
    /// How long the chosen music lasts (read once per file, not on every slider move).
    @State private var musicSeconds: Double?
    let count: Int

    init(settings: SlideshowSettings, count: Int) {
        _settings = State(initialValue: settings)
        _musicSeconds = State(initialValue: Self.length(settings.musicPath))
        self.count = count
    }

    private static func length(_ path: String) -> Double? {
        path.isEmpty ? nil : SlideshowVideo.musicDuration(URL(fileURLWithPath: path))
    }

    var body: some View {
        let slide = settings.slideSeconds(fitting: count, toMusic: musicSeconds)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("幻灯片").font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            Text("放映 \(count) 张照片（选中多张时为所选照片，否则为当前列表），共 \(Self.duration(slide * Double(count)))")
                .font(.system(size: 12)).foregroundStyle(Theme.text3)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("每张").gridColumnAlignment(.trailing)
                    HStack {
                        Slider(value: $settings.slideSeconds, in: SlideshowSettings.slideRange, step: 0.5)
                            .disabled(settings.fitToMusic && musicSeconds != nil)
                        Text(L("\(String(format: "%.1f", slide)) 秒")).monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                }
                GridRow {
                    Text("淡入淡出")
                    HStack {
                        Slider(value: $settings.fadeSeconds, in: SlideshowSettings.fadeRange, step: 0.25)
                        Text(L("\(String(format: "%.2f", settings.fadeSeconds)) 秒")).monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                }
                GridRow {
                    Text("文字")
                    Picker("文字", selection: $settings.caption) {
                        ForEach(SlideshowSettings.Caption.allCases, id: \.self) { caption in Text(caption.title).tag(caption) }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("背景")
                    Picker("背景", selection: $settings.backdrop) {
                        ForEach(SlideshowSettings.Backdrop.allCases, id: \.self) { backdrop in Text(backdrop.title).tag(backdrop) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                GridRow {
                    Text("播放")
                    HStack(spacing: 16) {
                        Toggle("平移和缩放", isOn: $settings.panAndZoom)
                        Toggle("随机顺序", isOn: $settings.shuffle)
                        Toggle("循环", isOn: $settings.repeats)
                    }
                    .toggleStyle(.checkbox)
                }
                GridRow {
                    Text("音乐")
                    HStack(spacing: 8) {
                        Text(settings.musicPath.isEmpty ? L("无") : (settings.musicPath as NSString).lastPathComponent)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(settings.musicPath.isEmpty ? Theme.text3 : Theme.text2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !settings.musicPath.isEmpty {
                            Button("移除") { settings.musicPath = "" }.controlSize(.small)
                        }
                        Button("选择…") { chooseMusic() }.controlSize(.small)
                    }
                }
                if !settings.musicPath.isEmpty {
                    GridRow {
                        Color.clear.frame(width: 1, height: 1)
                        Toggle("按音乐长度安排每张照片的时间", isOn: $settings.fitToMusic)
                            .toggleStyle(.checkbox)
                            .help(musicSeconds.map { L("音乐长 \(Self.duration($0))") } ?? "")
                    }
                }
                GridRow {
                    Text("视频尺寸")
                    Picker("视频尺寸", selection: $settings.videoSize) {
                        ForEach(SlideshowSettings.VideoSize.allCases, id: \.self) { size in Text(size.title).tag(size) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            HStack {
                Button("导出视频…") { exportVideo() }
                    .disabled(app.slideshowExportProgress != nil)
                    .help("把幻灯片存为 MP4 视频，带上音乐")
                Spacer()
                ghostButton(nil, L("取消")) { app.sheet = nil }
                Button {
                    app.slideshowSettings = settings
                    app.playSlideshow()
                } label: {
                    Label("播放", systemImage: "play.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.onAccent)
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
        .onChange(of: settings.musicPath) { musicSeconds = Self.length(settings.musicPath) }
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total < 60 ? L("\(total) 秒") : L("\(total / 60) 分 \(total % 60) 秒")
    }

    private func chooseMusic() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.message = L("选择幻灯片的音乐")
        if panel.runModal() == .OK, let url = panel.url { settings.musicPath = url.path }
    }

    private func exportVideo() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = L("幻灯片") + ".mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        app.slideshowSettings = settings
        app.exportSlideshowVideo(to: url)
    }
}

/// The status bar's word on a slideshow video being written, with a way to stop it.
struct SlideshowExportLabel: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if let progress = app.slideshowExportProgress {
            HStack(spacing: 5) {
                ProgressView(value: progress).tint(Theme.accent).frame(width: 54)
                Text("正在导出幻灯片视频…").monospacedDigit()
                Button { app.cancelSlideshowExport() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.text3)
                    .help("取消导出")
                    .accessibilityLabel("取消导出")
            }
            .foregroundStyle(Theme.accent)
            .fixedSize()
        }
    }
}
