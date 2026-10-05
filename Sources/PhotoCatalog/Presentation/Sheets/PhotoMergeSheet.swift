// ============================================================
//  Photo merge — Lightroom's HDR and Panorama Merge Preview
// ============================================================
import SwiftUI

/// The photos about to merge, a preview of the result, and its options.
struct PhotoMergeSheet: View {
    @Environment(AppState.self) private var app
    let targets: [Asset]
    @State private var preview: CGImage?
    @State private var previewFailed = false
    /// Why the preview couldn't be made, when the merge can say.
    @State private var failure: String?
    @State private var generation = 0

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            HStack {
                Text(app.photoMergeKind == .hdr ? L("HDR 合并") : L("全景合并")).font(.system(size: 17, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Theme.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }

            VStack(alignment: .leading, spacing: 12) {
                Text(app.photoMergeKind == .hdr
                     ? L("把 \(targets.count) 张不同曝光的照片合成一张，亮部和暗部的细节都保留。结果存为参考照片旁的 16 位 TIFF，加入目录库后可继续修图。")
                     : L("把 \(targets.count) 张相互重叠的照片按拍摄顺序拼成一张全景，投影到柱面并裁去空白边缘。结果存为第一张照片旁的 16 位 TIFF，加入目录库后可继续修图。"))
                    .font(.system(size: 12)).foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Theme.canvas)
                    if let preview {
                        Image(decorative: preview, scale: 1).resizable().aspectRatio(contentMode: .fit).padding(6)
                    } else if previewFailed {
                        Text(failure ?? L("无法生成预览")).font(.system(size: 12)).foregroundStyle(Theme.canvasText2)
                            .multilineTextAlignment(.center).padding()
                    } else {
                        VStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(app.photoMergeKind == .hdr ? "正在合成预览…" : "正在拼接预览…")
                                .font(.system(size: 12)).foregroundStyle(Theme.canvasText2)
                        }
                    }
                }
                .frame(height: 280)
                // the canvas is dark in either appearance: a light-mode spinner on it couldn't be seen
                .environment(\.colorScheme, .dark)
                if app.photoMergeKind == .hdr {
                    if exposuresAlike {
                        Label("这些照片的曝光相近，HDR 合并的效果有限；请选用一组不同曝光的照片",
                              systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11)).foregroundStyle(Theme.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Toggle("自动对齐", isOn: $app.hdrOptions.align)
                        .help("手持拍摄时，先把各张照片对齐")
                    Toggle("消除重影", isOn: $app.hdrOptions.deghost)
                        .help("照片之间有移动的物体时，那里只用中间曝光的照片")
                }
            }
            .toggleStyle(.checkbox)
            .padding(18)

            HStack(spacing: 9) {
                Spacer()
                ghostButton(nil, L("取消")) { app.sheet = nil }
                Button {
                    app.sheet = nil
                    app.mergePhotos()
                } label: {
                    Text("合并")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 17).padding(.vertical, 8)
                        .background(Theme.accentFill).clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(failure != nil)
                .opacity(failure != nil ? 0.5 : 1)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Theme.bgSidebar)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        }
        .frame(width: 520)
        .font(.system(size: 13))
        .foregroundStyle(Theme.text)
        .background(Theme.bgPanel)
        .task(id: app.hdrOptions) { await render() }
    }

    /// Whether the photos' exposures, from their metadata, lie within about ⅔ EV of each other.
    private var exposuresAlike: Bool {
        let brightness = targets.compactMap(AppState.exposureBrightness)
        guard brightness.count == targets.count, let low = brightness.min(), let high = brightness.max(), low > 0 else {
            return false
        }
        return log2(high / low) < 0.7
    }

    /// A small merge with the current options; a newer one replaces it.
    private func render() async {
        generation += 1
        let mine = generation, targets = targets, options = app.hdrOptions, kind = app.photoMergeKind
        preview = nil
        previewFailed = false
        failure = nil
        let result: (image: CGImage?, failure: PhotoMerge.PanoramaFailure?) = await withCheckedContinuation { continuation in
            PhotoMerge.queue.async {
                let frames = AppState.photoMergeFrames(targets)
                switch PhotoMerge.merge(frames, kind: kind, options: options, maxPixel: kind == .hdr ? 900 : 600) {
                case .success(let merged): continuation.resume(returning: (DevelopRenderer.render(merged.image), nil))
                case .failure(.unreadable): continuation.resume(returning: (nil, nil))
                case .failure(.panorama(let failure)): continuation.resume(returning: (nil, failure))
                }
            }
        }
        guard mine == generation else { return }
        preview = result.image
        previewFailed = result.image == nil
        failure = result.failure.map(AppState.panoramaFailureMessage)
    }
}
