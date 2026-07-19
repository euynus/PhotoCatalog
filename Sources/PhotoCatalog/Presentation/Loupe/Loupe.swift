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
                Icon("loupe", size: 40).foregroundStyle(Theme.text4)
                Text("没有可查看的照片").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text2)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let asset = list[idx]
            VStack(spacing: 0) {
                stage(asset, idx: idx, count: list.count)
                filmstrip(list)
            }
            .background(Color(hex: "#0e0e0f"))
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

    private func stage(_ asset: Asset, idx: Int, count: Int) -> some View {
        ZStack {
            // No .id(asset.id): keeping the loader alive across navigation
            // holds the current photo on screen instead of flashing the
            // gradient placeholder while the next one resolves.
            Thumb(asset: asset, urlString: asset.preview, kind: .preview2048, radius: 4, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .shadow(color: .black.opacity(0.6), radius: 30, y: 16)
                .padding(.horizontal, 64).padding(.vertical, 28)

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
                        .foregroundStyle(Theme.yellow)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Theme.yellow.opacity(0.18))
                        .overlay(Capsule().strokeBorder(Theme.yellow.opacity(0.3), lineWidth: 1))
                        .clipShape(Capsule())
                        Spacer()
                    }
                    Spacer()
                }.padding(12)
            }

            // HUD
            VStack {
                Spacer()
                hud(asset, idx: idx, count: count)
                    .padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func navButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Hover { hover in
            Button(action: action) {
                Icon(icon, size: 24).foregroundStyle(Theme.text)
                    .frame(width: 44, height: 44)
                    .background(Color(hex: "#28282a").opacity(hover ? 0.95 : 0.72), in: Circle())
            }.buttonStyle(.plain)
                .help(label)
                .accessibilityLabel(label)
        }
    }

    private func hud(_ asset: Asset, idx: Int, count: Int) -> some View {
        HStack(spacing: 18) {
            HStack(spacing: 8) {
                Text(asset.filename).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
                Text("·").foregroundStyle(Theme.text4)
                Text(asset.camera).font(.system(size: 12)).foregroundStyle(Theme.text2)
                Text("·").foregroundStyle(Theme.text4)
                Text(exposureSummary(asset, separator: "  "))
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.text2)
            }.lineLimit(1)
            HStack(spacing: 12) {
                StarsView(value: asset.rating, size: 15, gap: 2) { n in
                    app.mutateAsset(asset.id) { $0.rating = asset.rating == n ? 0 : n }
                }
                FlagPill(flag: asset.flag, size: 15)
                ColorDot(label: asset.colorLabel, size: 11)
                Text("\(idx + 1) / \(count)").font(.system(size: 11.5)).monospacedDigit()
                    .foregroundStyle(Theme.text3)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .fixedSize(horizontal: true, vertical: false)
        .background(Color(hex: "#1c1c1e").opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line2, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 15, y: 8)
    }

    private func filmstrip(_ list: [Asset]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(list) { a in
                        Hover { hover in
                            Button { app.setPrimary(a.id) } label: {
                                ZStack {
                                    Thumb(asset: a, radius: 2, maxDecodePixel: 216)
                                        .overlay(alignment: .bottomLeading) {
                                            if a.rating > 0 {
                                                StarsView(value: a.rating, size: 7, dim: true).padding(.leading, 3).padding(.bottom, 2)
                                            }
                                        }
                                        .overlay(alignment: .topTrailing) {
                                            if a.flag == .pick {
                                                Circle().fill(Theme.accent).frame(width: 7, height: 7).padding(3)
                                            } else if a.flag == .reject {
                                                Circle().fill(Theme.red).frame(width: 7, height: 7).padding(3)
                                            }
                                        }
                                }
                                .frame(width: 108, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                            .buttonStyle(.plain)
                            .opacity(a.id == app.primaryId ? 1 : (hover ? 0.85 : 0.62))
                            .overlay(RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(a.id == app.primaryId ? Theme.accent : .clear, lineWidth: 2))
                            .accessibilityLabel(a.filename)
                            .accessibilityAddTraits(a.id == app.primaryId ? .isSelected : [])
                        }
                        .id(a.id)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
            .frame(height: 92)
            .background(Color(hex: "#1a1a1c"))
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
            .onChange(of: app.primaryId) {
                if let id = app.primaryId { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }
}
