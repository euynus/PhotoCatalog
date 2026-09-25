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
                Filmstrip(photos: app.photoList, assetRevision: app.assetRenderVersion)
            }
            .background(Theme.canvas)
            .environment(\.colorScheme, .dark)
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
            // Keep the loaders alive across navigation; zoom persists between photos.
            LoupeZoomablePhoto(asset: asset)

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

    private func navButton(_ icon: String, label: String, disabled: Bool,
                           action: @escaping () -> Void) -> some View {
        Hover { hover in
            Button(action: action) {
                Icon(icon, size: 13).foregroundStyle(Theme.canvasText)
                    .frame(width: 28, height: 28)
                    .background(hover ? Theme.canvasSurfaceHi : .clear,
                                in: RoundedRectangle(cornerRadius: 4))
            }.buttonStyle(.plain)
                .disabled(disabled)
                .opacity(disabled ? 0.35 : 1)
                .help(label)
                .accessibilityLabel(label)
        }
    }

    private func hud(_ asset: Asset, idx: Int, count: Int) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 12) {
                Text(asset.filename)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.canvasText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(asset.filename)
                Text("\(idx + 1) / \(count)")
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(Theme.canvasText2)
                    .fixedSize()
            }
            .frame(height: 16)
            HStack(spacing: 10) {
                Text("\(asset.camera) · \(exposureSummary(asset, separator: "  "))")
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(Theme.canvasText2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .help("\(asset.camera) · \(exposureSummary(asset))")
                HStack(spacing: 8) {
                    StarsView(value: asset.rating, size: 13, gap: 2) { n in
                        app.mutateAsset(asset.id, scope: .review, withCompanions: true, undoName: L("评分")) { $0.rating = asset.rating == n ? 0 : n }
                    }
                    FlagPill(flag: asset.flag, size: 12).frame(width: 14)
                    ColorDot(label: asset.colorLabel, size: 10).frame(width: 10)
                }
                .fixedSize()
                Rectangle().fill(Theme.canvasLine).frame(width: 1, height: 16)
                LoupeZoomButton()
                HStack(spacing: 2) {
                    navButton("chevronL", label: L("上一张"), disabled: idx == 0) { go(-1) }
                    navButton("chevronR", label: L("下一张"), disabled: idx == count - 1) { go(1) }
                }
                .fixedSize()
            }
            .frame(height: 28)
        }
        .padding(.horizontal, 12)
        .frame(height: 64)
        .frame(maxWidth: .infinity)
        .background(Theme.canvasSurface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.canvasLine).frame(height: 1) }
    }
}

/// Reads the zoom itself so panning (which updates it continuously) re-renders only the photo.
private struct LoupeZoomablePhoto: View {
    @Environment(AppState.self) private var app
    let asset: Asset

    var body: some View {
        ZoomablePhoto(asset: asset, zoom: app.loupeZoom) { app.loupeZoom = $0 }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(app.loupeZoom == nil ? 12 : 0)
    }
}

private struct LoupeZoomButton: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let zoom = app.loupeZoom
        Hover { hover in
            Button { _ = app.toggleZoom() } label: {
                HStack(spacing: 4) {
                    Image(systemName: zoom == nil ? "plus.magnifyingglass" : "minus.magnifyingglass")
                    Text(zoom.map { "\(Int(($0.scale * 100).rounded()))%" } ?? L("适合"))
                        .monospacedDigit()
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.canvasText)
                .padding(.horizontal, 7)
                .frame(height: 28)
                .background(hover ? Theme.canvasSurfaceHi : .clear, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .help(zoom == nil ? "放大到 1:1 (Z，或双击照片)" : "缩放以适合 (Z / Esc)")
            .accessibilityLabel(zoom == nil ? "放大到 1:1" : "缩放以适合")
        }
        .fixedSize()
    }
}

/// The current collection as a horizontal strip; shared by Loupe and Develop.
struct Filmstrip: View {
    @Environment(AppState.self) var app
    let photos: PhotoList
    /// Bumped by every catalog edit: refreshes stars and flags, which `photos` ignores.
    let assetRevision: Int

    var body: some View {
        let _ = assetRevision
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    // positions as item ids, like the grid: a new list doesn't re-index every photo
                    ForEach(0..<photos.count, id: \.self) { position in
                        let a = photos[position]
                        Hover { hover in
                            Button { app.setPrimary(a.id) } label: {
                                VStack(spacing: 4) {
                                    Thumb(asset: a, radius: 2, contentMode: .fit, maxDecodePixel: 216)
                                        .frame(width: 108, height: 72)
                                        .background(Theme.canvas)
                                    HStack(spacing: 5) {
                                        if a.rating > 0 {
                                            StarsView(value: a.rating, size: 8, dim: true, filledOnly: true)
                                        }
                                        Spacer(minLength: 0)
                                        FlagPill(flag: a.flag, size: 10)
                                    }
                                    .frame(height: 12)
                                    .background(Theme.canvasSurface)
                                }
                                .padding(4)
                                .frame(width: 116, height: 96)
                                .background(a.id == app.primaryId || hover ? Theme.canvasSurfaceHi : Theme.canvas)
                                .clipShape(RoundedRectangle(cornerRadius: 2))
                            }
                            .buttonStyle(.plain)
                            .overlay(RoundedRectangle(cornerRadius: 2)
                                .strokeBorder(a.id == app.primaryId ? Theme.canvasText : Theme.canvasLine,
                                              lineWidth: a.id == app.primaryId ? 1.5 : 1))
                            .help(a.filename)
                            .accessibilityLabel(a.filename)
                            .accessibilityAddTraits(a.id == app.primaryId ? .isSelected : [])
                        }
                        .id(a.id)   // a position showing another photo starts fresh
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .frame(height: 112)
            .background(Theme.canvasSurface)
            .overlay(alignment: .top) { Rectangle().fill(Theme.canvasLine).frame(height: 1) }
            .environment(\.colorScheme, .dark)
            .onAppear {
                if let position = primaryPosition { proxy.scrollTo(position, anchor: .center) }
            }
            .onChange(of: app.primaryId) {
                if let position = primaryPosition { withAnimation { proxy.scrollTo(position, anchor: .center) } }
            }
        }
    }

    private var primaryPosition: Int? {
        guard let id = app.primaryId else { return nil }
        return photos.assets.firstIndex { $0.id == id }
    }
}
