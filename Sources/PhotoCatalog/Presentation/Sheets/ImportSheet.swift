// ============================================================
//  Import / scan progress — port of ImportSheet()
// ============================================================
import SwiftUI

struct ImportSheet: View {
    @EnvironmentObject var app: AppState

    private let total = 1284
    @State private var scanned = 0
    @State private var done = 0
    @State private var failed = 0
    @State private var skipped = 0
    @State private var paused = false
    @State private var phase = "scanning"   // scanning -> importing -> complete
    @State private var tiles: [Asset] = []

    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    private var pool: [Asset] { app.assets.filter { $0.status == .ready } }

    private var pct: Int {
        phase == "scanning" ? Int(Double(scanned) / Double(total) * 100)
                            : Int(Double(done) / Double(total) * 100)
    }
    private var pending: Int { max(0, scanned - done - failed - skipped) }

    var body: some View {
        VStack(spacing: 0) {
            head
            source
            progress
            stats
            wall
            foot
        }
        .frame(width: 560)
        .background(Color(hex: "#232325"))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line2, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.7), radius: 60, y: 40)
        .onReceive(timer) { _ in tick() }
    }

    private func tick() {
        guard !paused else { return }
        if phase == "scanning" {
            scanned = min(total, scanned + Int.random(in: 18...43))
            if scanned >= total { phase = "importing" }
        } else if phase == "importing" {
            let nd = min(total, done + Int.random(in: 14...35))
            done = nd
            if Double.random(in: 0...1) > 0.85 { failed += 1 }
            if Double.random(in: 0...1) > 0.8 { skipped += 1 }
            if !pool.isEmpty {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) {
                    tiles = Array(([pool[nd % pool.count]] + tiles).prefix(28))
                }
            }
            if nd >= total { phase = "complete" }
        }
    }

    private var head: some View {
        HStack {
            HStack(spacing: 9) {
                Icon("importIcon", size: 17).foregroundStyle(Theme.accent)
                Text(phase == "scanning" ? "正在扫描文件夹…" : phase == "importing" ? "正在导入照片…" : "导入完成")
                    .font(.system(size: 14.5, weight: .semibold))
            }
            Spacer()
            sheetClose { app.sheet = nil }
        }
        .padding(.horizontal, 18).padding(.vertical, 15)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var source: some View {
        HStack(spacing: 9) {
            Icon("folder", size: 15).foregroundStyle(Theme.text2)
            Text("/Volumes/Photos/2026 东京之旅").font(.system(size: 12)).foregroundStyle(Theme.text)
            Spacer()
            Text("引用式").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.accent)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Theme.accentSoft).clipShape(Capsule())
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var progress: some View {
        HStack(spacing: 12) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surface)
                    Capsule().fill(Theme.importFill)
                        .frame(width: geo.size.width * CGFloat(pct) / 100)
                        .animation(.easeOut(duration: 0.2), value: pct)
                }
            }
            .frame(height: 7)
            Text("\(pct)%").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .frame(width: 42, alignment: .trailing)
        }
        .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 6)
    }

    private var stats: some View {
        HStack(spacing: 8) {
            stat(scanned.formatted(), "已扫描", nil)
            stat(pending.formatted(), "待处理", nil)
            stat(done.formatted(), "成功", Theme.accent)
            stat("\(skipped)", "跳过（重复）", Theme.yellow)
            stat("\(failed)", "失败", Theme.redSoft)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private func stat(_ n: String, _ label: String, _ color: Color?) -> some View {
        VStack(spacing: 3) {
            Text(n).font(.system(size: 17, weight: .semibold)).monospacedDigit()
                .foregroundStyle(color ?? Theme.text)
            Text(label).font(.system(size: 10)).foregroundStyle(Theme.text3)
        }
        .frame(maxWidth: .infinity)
        .padding(9)
        .background(Color.black.opacity(0.24))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var wall: some View {
        VStack(alignment: .leading, spacing: 0) {
            if tiles.isEmpty {
                Text("缩略图将在导入时逐步出现…").font(.system(size: 12)).foregroundStyle(Theme.text4)
                    .frame(maxWidth: .infinity).padding(.top, 40)
            } else {
                FlowRow(spacing: 4, lineSpacing: 4) {
                    ForEach(Array(tiles.enumerated()), id: \.offset) { _, a in
                        Thumb(asset: a, radius: 3).frame(width: 56, height: 38)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 120, alignment: .topLeading)
        .clipped()
        .padding(.horizontal, 18).padding(.bottom, 14)
    }

    private var foot: some View {
        HStack(spacing: 9) {
            if phase != "complete" {
                HStack(spacing: 6) {
                    if failed > 0 {
                        Icon("warning", size: 13).foregroundStyle(Theme.redSoft)
                        Text("\(failed) 个文件失败 · 可稍后重试").foregroundStyle(Theme.redSoft)
                    }
                }
                .font(.system(size: 11.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                ghostButton(paused ? "play" : "pause", paused ? "继续" : "暂停") { paused.toggle() }
                ghostButton(nil, "后台运行") { app.sheet = nil }
            } else {
                HStack(spacing: 6) {
                    Icon("check", size: 14, weight: .bold).foregroundStyle(Theme.accent)
                    Text("已导入 \(done.formatted()) 张 · \(skipped) 张跳过 · \(failed) 张失败")
                }
                .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                .frame(maxWidth: .infinity, alignment: .leading)
                Button { app.sheet = nil; app.push("导入完成", "check") } label: {
                    Text("完成").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 17).padding(.vertical, 8)
                        .background(Theme.accent).clipShape(RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
        .background(Color.black.opacity(0.18))
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

// shared sheet helpers
func sheetClose(_ action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Icon("close", size: 15).foregroundStyle(Theme.text2)
            .frame(width: 26, height: 26).background(Theme.surface).clipShape(Circle())
    }.buttonStyle(.plain)
}

func ghostButton(_ icon: String?, _ label: String, danger: Bool = false, small: Bool = false,
                 action: @escaping () -> Void) -> some View {
    Button(action: action) {
        HStack(spacing: 6) {
            if let icon { Icon(icon, size: small ? 13 : 14) }
            Text(label).font(.system(size: small ? 12 : 12.5))
        }
        .foregroundStyle(danger ? Theme.redSoft : Theme.text)
        .padding(.horizontal, small ? 10 : 15).padding(.vertical, small ? 5 : 8)
        .background(danger ? Theme.red.opacity(0.001) : Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }.buttonStyle(.plain)
}
