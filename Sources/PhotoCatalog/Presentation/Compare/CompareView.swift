// ============================================================
//  Compare view (2–4 side by side) — port of compare.jsx
// ============================================================
import SwiftUI

struct CompareView: View {
    @Environment(AppState.self) var app
    @State private var trayOpen = false

    private var assets: [Asset] { app.compareIds.compactMap { id in app.assets.first { $0.id == id } } }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if trayOpen { tray }
            stage
        }
        .background(Color(hex: "#0e0e0f"))
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("比较视图").font(.system(size: 13, weight: .semibold))
            Text("为同一场景的候选照片打分、标旗，挑出最佳一张")
                .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
            Spacer()
            Text("\(assets.count) / 4 张").font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.text2)
            Hover { hover in
                Button { trayOpen.toggle() } label: {
                    HStack(spacing: 5) { Icon("plus", size: 13, weight: .bold); Text("添加照片").font(.system(size: 12)) }
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(hover ? Theme.surfaceHi : Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(assets.count >= 4)
                .opacity(assets.count >= 4 ? 0.4 : 1)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Color(hex: "#1a1a1c"))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var tray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(app.list.filter { !app.compareIds.contains($0.id) }.prefix(24)) { a in
                    Hover { hover in
                        Button {
                            app.addToCompare(a.id)
                            trayOpen = false
                        } label: {
                            Thumb(asset: a, radius: 3)
                                .frame(width: 76, height: 52)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .opacity(hover ? 1 : 0.8)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(a.filename)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(Color(hex: "#161618"))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var stage: some View {
        HStack(spacing: 10) {
            ForEach(assets) { a in
                ComparePanel(asset: a, isWinner: app.winner == a.id)
            }
            if assets.count < 2 {
                Hover { hover in
                    Button { trayOpen = true } label: {
                        VStack(spacing: 8) { Icon("plus", size: 24); Text("添加照片以开始比较").font(.system(size: 12.5)) }
                            .foregroundStyle(hover ? Theme.text3 : Theme.text4)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(hover ? Color.white(0.02) : .clear)
                            .overlay(RoundedRectangle(cornerRadius: Theme.r)
                                .strokeBorder(hover ? Color.white(0.22) : Theme.line2,
                                              style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
                            .clipShape(RoundedRectangle(cornerRadius: Theme.r))
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ComparePanel: View {
    @Environment(AppState.self) var app
    let asset: Asset
    let isWinner: Bool
    @State private var hover = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Thumb(asset: asset, urlString: asset.preview, kind: .preview2048, radius: 4, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .shadow(color: .black.opacity(0.5), radius: 13, y: 8)
                    .padding(14)
                if isWinner {
                    VStack { HStack {
                        HStack(spacing: 5) { Icon("check", size: 13, weight: .bold); Text("选定").font(.system(size: 11, weight: .bold)) }
                            .foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Theme.accent).clipShape(Capsule())
                        Spacer() }; Spacer() }.padding(10)
                }
                VStack { HStack {
                    Spacer()
                    Hover { btnHover in
                        Button { app.removeFromCompare(asset.id) } label: {
                            Icon("close", size: 13, weight: .bold)
                                .foregroundStyle(btnHover ? Theme.text : Theme.text2)
                                .frame(width: 24, height: 24)
                                .background(Color.black.opacity(btnHover ? 0.75 : 0.5))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain).help("移出比较")
                        .accessibilityLabel("移出比较")
                    }
                    .opacity(hover ? 1 : 0)
                }; Spacer() }.padding(9)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(hex: "#0e0e0f"))
            foot
        }
        .background(Color(hex: "#161618"))
        .overlay(RoundedRectangle(cornerRadius: Theme.r)
            .strokeBorder(isWinner ? Theme.accent : Theme.line, lineWidth: 1.5))
        .clipShape(RoundedRectangle(cornerRadius: Theme.r))
        .shadow(color: isWinner ? Theme.accent.opacity(0.12) : .clear, radius: 15, y: 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onHover { hover = $0 }
    }

    private var foot: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 3) {
                Text(asset.filename).font(.system(size: 12.5, weight: .semibold))
                Text(exposureSummary(asset))
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.text3)
            }
            HStack(spacing: 10) {
                StarsView(value: asset.rating, size: 17, gap: 2) { n in
                    app.mutateAsset(asset.id) { $0.rating = asset.rating == n ? 0 : n }
                }
                HStack(spacing: 4) {
                    miniFlag(.pick, "flag")
                    miniFlag(.reject, "reject")
                }
                Spacer()
                Hover { hover in
                    Button {
                        app.winner = asset.id; app.push("已选为最佳", "check")
                    } label: {
                        Text("选为最佳").font(.system(size: 11.5, weight: isWinner ? .semibold : .regular))
                            .foregroundStyle(isWinner ? Theme.onAccent : (hover ? Theme.text : Theme.text2))
                            .padding(.horizontal, 11).padding(.vertical, 5)
                            .background(isWinner ? Theme.accent : (hover ? Theme.surfaceHi : Theme.surface))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "#1c1c1e"))
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func miniFlag(_ flag: Flag, _ icon: String) -> some View {
        let on = asset.flag == flag
        let tint: Color = flag == .pick ? Theme.accent : Theme.redSoft
        let bg: Color = flag == .pick ? Theme.accentSoft : Theme.red.opacity(0.16)
        return Hover { hover in
            Button {
                app.mutateAsset(asset.id) { $0.flag = on ? .none : flag }
            } label: {
                Icon(icon, size: 13).foregroundStyle(on ? tint : (hover ? Theme.text2 : Theme.text3))
                    .frame(width: 26, height: 24)
                    .background(on ? bg : (hover ? Theme.surfaceHi : Theme.surface))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }.buttonStyle(.plain).help(flag == .pick ? "精选" : "拒绝")
                .accessibilityLabel(flag == .pick ? "精选" : "拒绝")
        }
    }
}
