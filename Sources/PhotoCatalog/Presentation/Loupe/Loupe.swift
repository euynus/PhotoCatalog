// ============================================================
//  Loupe (single view) + filmstrip — port of loupe.jsx
// ============================================================
import SwiftUI

struct Loupe: View {
    @Environment(AppState.self) var app

    var body: some View {
        let list = app.list
        let idx = max(0, list.firstIndex { $0.id == app.primaryId } ?? 0)
        if list.isEmpty {
            VStack(spacing: 10) {
                Icon("loupe", size: 40).foregroundStyle(Theme.canvasText3)
                Text("没有可查看的照片").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.canvasText2)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.canvas)
        } else {
            let asset = list[idx]
            VStack(spacing: 0) {
                stage(asset)
                hud(asset, idx: idx, count: list.count)
                filmstrip(list)
            }
            .background(Theme.canvas)
            .task(id: "\(asset.id)|\(app.thumbnailCacheGeneration)") {
                // warm the neighbors so arrow-key navigation lands on a cache hit
                let cacheGeneration = app.thumbnailCacheGeneration
                for neighbor in [idx - 1, idx + 1] where neighbor >= 0 && neighbor < list.count {
                    let a = list[neighbor]
                    guard !a.preview.isEmpty else { continue }
                    let resolved = await app.visibleImageSource(for: a, requestedSource: a.preview,
                                                                kind: .preview2048)
                    guard !Task.isCancelled else { return }
                    await ThumbLoader.prefetch(resolved, maxPixel: ThumbnailService.Kind.preview2048.maxPixel,
                                               cacheGeneration: cacheGeneration)
                }
            }
        }
    }

    private func go(_ delta: Int) {
        let list = app.list
        guard !list.isEmpty else { return }
        let idx = max(0, list.firstIndex { $0.id == app.primaryId } ?? 0)
        let target = idx + delta
        guard target >= 0, target < list.count else { return }  // clamp at ends, like the arrow keys
        app.setPrimary(list[target].id)
    }

    private func stage(_ asset: Asset) -> some View {
        ZStack {
            // Keep the loader alive across navigation.
            Thumb(asset: asset, urlString: asset.preview, kind: .preview2048, radius: 2, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 60).padding(.vertical, 20)

            // nav arrows
            HStack {
                navButton("chevronL", label: "上一张") { go(-1) }
                Spacer()
                navButton("chevronR", label: "下一张") { go(1) }
            }.padding(.horizontal, 14)

            // offline badge
            if asset.status == .offline {
                VStack {
                    HStack {
                        HStack(spacing: 6) {
                            Icon("offline", size: 15); Text("离线 — 显示缓存预览").font(.system(size: 11.5))
                        }
                        .foregroundStyle(Theme.canvasText2)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Theme.canvasSurface)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.canvasLine, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        Spacer()
                    }
                    Spacer()
                }.padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }

    private func navButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Hover { hover in
            Button(action: action) {
                Icon(icon, size: 21).foregroundStyle(Theme.canvasText)
                    .frame(width: 36, height: 44)
                    .background(hover ? Theme.canvasSurfaceHi : Theme.canvasSurface,
                                in: RoundedRectangle(cornerRadius: 5))
            }.buttonStyle(.plain)
                .help(label)
                .accessibilityLabel(label)
        }
    }

    private func hud(_ asset: Asset, idx: Int, count: Int) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(asset.filename)
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(asset.filename)
                HStack(spacing: 6) {
                    Text(asset.camera)
                    Text("·").foregroundStyle(Theme.text4)
                    Text(exposureSummary(asset, separator: "  ")).monospacedDigit()
                }
                .font(.system(size: 11.5)).foregroundStyle(Theme.text2)
                .lineLimit(1)
                .help("\(asset.camera) · \(exposureSummary(asset))")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 5) {
                HStack(spacing: 9) {
                    StarsView(value: asset.rating, size: 15, gap: 2) { n in
                        app.mutateAsset(asset.id) { $0.rating = asset.rating == n ? 0 : n }
                    }
                    FlagPill(flag: asset.flag, size: 15)
                    ColorDot(label: asset.colorLabel, size: 11)
                }
                Text("\(idx + 1) / \(count)").font(.system(size: 11.5)).monospacedDigit()
                    .foregroundStyle(Theme.text2)
            }
            .fixedSize()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Theme.bgPanel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func filmstrip(_ list: [Asset]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(list) { a in
                        Hover { hover in
                            Button { app.setPrimary(a.id) } label: {
                                VStack(spacing: 4) {
                                    Thumb(asset: a, radius: 2, contentMode: .fit, maxDecodePixel: 216)
                                        .frame(width: 108, height: 72)
                                        .background(Theme.canvas)
                                    HStack(spacing: 5) {
                                        if a.rating > 0 {
                                            StarsView(value: a.rating, size: 8, dim: true)
                                        }
                                        Spacer(minLength: 0)
                                        FlagPill(flag: a.flag, size: 10)
                                    }
                                    .frame(height: 12)
                                }
                                .padding(4)
                                .frame(width: 116, height: 96)
                                .background(a.id == app.primaryId ? Theme.canvasSelection
                                            : (hover ? Theme.canvasSurfaceHi : .clear))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            .buttonStyle(.plain)
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(a.id == app.primaryId ? Theme.accent : .clear, lineWidth: 2))
                            .help(a.filename)
                            .accessibilityLabel(a.filename)
                            .accessibilityAddTraits(a.id == app.primaryId ? .isSelected : [])
                        }
                        .id(a.id)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .frame(height: 112)
            .background(Theme.canvasSurface)
            .overlay(alignment: .top) { Rectangle().fill(Theme.canvasLine).frame(height: 1) }
            .environment(\.colorScheme, .dark)
            .onChange(of: app.primaryId) {
                if let id = app.primaryId { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }
}
