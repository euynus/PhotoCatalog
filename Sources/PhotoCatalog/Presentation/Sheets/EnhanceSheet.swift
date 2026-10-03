// ============================================================
//  Enhance dialog — AI denoise and super resolution, with a preview
// ============================================================
import SwiftUI
import CoreImage

struct EnhanceSheet: View {
    @Environment(AppState.self) private var app
    let targets: [Asset]
    /// Before and after, at 100% (after at twice the size with super resolution).
    @State private var preview: (before: CGImage, after: CGImage)?
    @State private var previewFailed = false
    @State private var generation = 0

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            HStack {
                Text("增强").font(.system(size: 17, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Theme.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }

            VStack(alignment: .leading, spacing: 12) {
                Text(L("用这台 Mac 上的 AI 模型处理 \(targets.count) 张照片。结果存为原片旁的 16 位 TIFF（…-Enhanced.tif），带原片的元数据加入目录库，修图设置也一并带过去（白平衡除外）。"))
                    .font(.system(size: 12)).foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    previewPane(preview?.before, L("原图"))
                    previewPane(preview?.after, L("增强后"))
                }
                .frame(height: 250)
                Toggle("AI 降噪", isOn: $app.enhanceOptions.denoise)
                    .help("去掉高 ISO 的杂色，保留细节")
                HStack(spacing: 10) {
                    Text("强度").foregroundStyle(app.enhanceOptions.denoise ? Theme.text : Theme.text3)
                    Slider(value: $app.enhanceOptions.denoiseAmount, in: 0...100, step: 1)
                    Text(String(format: "%.0f", app.enhanceOptions.denoiseAmount)).monospacedDigit().frame(width: 28, alignment: .trailing)
                }
                .disabled(!app.enhanceOptions.denoise)
                .padding(.leading, 20)
                Toggle("超分辨率", isOn: $app.enhanceOptions.superResolution)
                    .help("宽和高各放大 2 倍（像素数变为 4 倍），便于大幅打印或裁剪")
                Text(estimate).font(.system(size: 11)).foregroundStyle(Theme.text3)
            }
            .toggleStyle(.checkbox)
            .padding(18)

            HStack(spacing: 9) {
                Spacer()
                ghostButton(nil, L("取消")) { app.sheet = nil }
                Button {
                    app.sheet = nil
                    app.enhancePhotos()
                } label: {
                    Text("增强")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 17).padding(.vertical, 8)
                        .background(Theme.accentFill).clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(app.enhanceOptions.isEmpty)
                .opacity(app.enhanceOptions.isEmpty ? 0.5 : 1)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Theme.bgSidebar)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        }
        .frame(width: 560)
        .font(.system(size: 13))
        .foregroundStyle(Theme.text)
        .background(Theme.bgPanel)
        .task(id: app.enhanceOptions) { await render() }
    }

    private func previewPane(_ image: CGImage?, _ label: String) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6).fill(Theme.canvas)
            if let image {
                Image(decorative: image, scale: 1).resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if previewFailed {
                Text("无法生成预览").font(.system(size: 12)).foregroundStyle(Theme.canvasText2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.canvasText2)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 4))
                .padding(6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Roughly how long the run takes on Apple silicon: the denoiser about 2 seconds per
    /// megapixel, super resolution about half a second.
    private var estimate: String {
        let megapixels = targets.reduce(0.0) { $0 + Double(max($1.width, 1) * max($1.height, 1)) / 1_000_000 }
        let seconds = megapixels * ((app.enhanceOptions.denoise ? 2.2 : 0) + (app.enhanceOptions.superResolution ? 0.5 : 0))
        guard seconds > 0 else { return L("至少选择一项") }
        let roundedSeconds = max(5, Int((seconds / 5).rounded()) * 5), minutes = Int((seconds / 60).rounded())
        return seconds < 90 ? L("预计约 \(roundedSeconds) 秒") : L("预计约 \(minutes) 分钟")
    }

    /// The first photo's middle — or its face, when there is one — at 100%, enhanced with the
    /// current options; a newer preview replaces it.
    private func render() async {
        generation += 1
        let mine = generation, options = app.enhanceOptions
        guard let target = targets.first, let source = app.enhanceSource(for: target) else {
            previewFailed = true
            return
        }
        previewFailed = false
        let result: (before: CGImage, after: CGImage)? = await withCheckedContinuation { continuation in
            Enhance.queue.async {
                guard !options.isEmpty,
                      let image = DevelopRenderer.Source(url: source.url, isRaw: source.isRaw, maxPixel: nil)?.image(.neutral)
                else { return continuation.resume(returning: nil) }
                let extent = image.extent
                // super resolution shows half the area, at twice the size
                let side: CGFloat = options.superResolution ? 128 : 256
                var center = CGPoint(x: extent.midX, y: extent.midY)
                if let people = PeopleMasks.analysis(url: source.url, isRaw: source.isRaw),
                   let face = people.faces.max(by: { $0.width < $1.width }) {
                    let point = face.eyes.first.map { eye in
                        CGPoint(x: eye.map(\.x).reduce(0, +) / CGFloat(eye.count), y: eye.map(\.y).reduce(0, +) / CGFloat(eye.count))
                    } ?? face.center
                    center = CGPoint(x: extent.minX + point.x / CGFloat(people.width) * extent.width,
                                     y: extent.maxY - point.y / CGFloat(people.height) * extent.height)
                }
                let crop = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side).integral
                    .intersection(extent)
                let piece = image.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
                guard let after = Enhance.enhance(piece, options: options).flatMap(Enhance.image),
                      let before = DevelopRenderer.render(options.superResolution
                          ? piece.samplingNearest().transformed(by: CGAffineTransform(scaleX: 2, y: 2)) : piece)
                else { return continuation.resume(returning: nil) }
                continuation.resume(returning: (before, after))
            }
        }
        guard mine == generation else { return }
        preview = result
        previewFailed = result == nil
    }
}
