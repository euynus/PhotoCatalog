// ============================================================
//  Photo merge — Lightroom's HDR Merge Preview
// ============================================================
import SwiftUI

/// The photos about to merge, a preview of the result, and its options.
struct PhotoMergeSheet: View {
    @Environment(AppState.self) private var app
    let targets: [Asset]
    @State private var preview: CGImage?
    @State private var previewFailed = false
    @State private var generation = 0

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            HStack {
                Text("HDR 合并").font(.system(size: 17, weight: .semibold))
                Spacer()
                sheetClose { app.sheet = nil }
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Theme.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }

            VStack(alignment: .leading, spacing: 12) {
                Text("把 \(targets.count) 张不同曝光的照片合成一张，亮部和暗部的细节都保留。结果存为参考照片旁的 16 位 TIFF，加入目录库后可继续修图。")
                    .font(.system(size: 12)).foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Theme.canvas)
                    if let preview {
                        Image(decorative: preview, scale: 1).resizable().aspectRatio(contentMode: .fit).padding(6)
                    } else if previewFailed {
                        Text("无法生成预览").font(.system(size: 12)).foregroundStyle(Theme.canvasText2)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(height: 280)
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
        let mine = generation, frames = app.photoMergeFrames(targets), options = app.hdrOptions
        preview = nil
        previewFailed = false
        let image: CGImage? = await withCheckedContinuation { continuation in
            PhotoMerge.queue.async {
                let merged = PhotoMerge.hdr(frames, options: options, maxPixel: 900)
                continuation.resume(returning: merged.flatMap { DevelopRenderer.render($0.image) })
            }
        }
        guard mine == generation else { return }
        preview = image
        previewFailed = image == nil
    }
}
