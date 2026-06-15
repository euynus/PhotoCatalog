// ============================================================
//  Inspector — port of inspector.jsx (Info / Metadata / Organize / History)
// ============================================================
import SwiftUI

struct InspectorView: View {
    @EnvironmentObject var app: AppState
    let asset: Asset?

    private let tabs: [(String, String)] = [
        ("info", "info"), ("meta", "aperture"), ("org", "organize"), ("hist", "history"),
    ]

    var body: some View {
        Group {
            if let asset {
                content(asset)
            } else {
                VStack(spacing: 10) {
                    Icon("inspector", size: 34)
                    Text("未选择照片").font(.system(size: 12.5))
                }
                .foregroundStyle(Theme.text4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: Theme.inspectorW)
        .background(Theme.bgPanel)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.line).frame(width: 1) }
    }

    private func content(_ asset: Asset) -> some View {
        VStack(spacing: 0) {
            preview(asset)
            headline(asset)
            tabBar
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch app.insTab {
                    case "info": infoTab(asset)
                    case "meta": metaTab(asset)
                    case "org": OrganizeTab(asset: asset)
                    default: histTab(asset)
                    }
                }
                .padding(14)
            }
        }
    }

    private func preview(_ asset: Asset) -> some View {
        ZStack {
            Thumb(asset: asset, urlString: asset.thumb, radius: 5)
                .id(asset.id)
                .aspectRatio(CGFloat(asset.width) / CGFloat(asset.height), contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .shadow(color: .black.opacity(0.5), radius: 11, y: 6)
                .padding(14)
            if app.selectedIds.count > 1 {
                VStack {
                    Spacer()
                    Text("\(app.selectedIds.count) 张已选 · 编辑将批量应用")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Theme.accent).clipShape(Capsule())
                        .padding(.bottom, 8)
                }
            }
        }
        .frame(height: 196)
        .frame(maxWidth: .infinity)
        .background(Color(hex: "#131314"))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func headline(_ asset: Asset) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(asset.filename).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
            HStack(spacing: 7) {
                TypeBadge(asset: asset, small: true)
                Text("\(asset.width) × \(asset.height)")
                Text("·")
                Text(String(format: "%.1f MP", asset.megapixels))
            }
            .font(.system(size: 11.5)).monospacedDigit().foregroundStyle(Theme.text3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.top, 11).padding(.bottom, 9)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(tabs, id: \.0) { tab in
                InsTabButton(icon: tab.1, active: app.insTab == tab.0) { app.insTab = tab.0 }
            }
        }
        .padding(.horizontal, 12).padding(.top, 7)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    // ---------- Info ----------
    private func infoTab(_ a: Asset) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            InsGroup([
                .init("文件名", a.filename, mono: true),
                .init("类型", a.isRaw ? "RAW · \(a.type)" : a.type),
                .init("大小", String(format: "%.1f MB", a.fileMB)),
                .init("尺寸", "\(a.width) × \(a.height)", mono: true),
                .init("色彩空间", a.colorSpace),
                .init("ICC", a.hasICCProfile ? "有" : "无"),
            ])
            InsGroup({
                var rows: [InfoRowData] = [
                    .init("文件夹", a.folderName),
                    .init("位置", a.location),
                    .init("状态",
                          a.status == .ready ? "可访问" : (a.status == .offline ? "离线（外置盘）" : "缺失"),
                          accent: a.status != .ready),
                ]
                if a.faces > 0 { rows.append(.init("人脸", "检测到 \(a.faces) 张")) }
                return rows
            }())
            VStack(alignment: .leading, spacing: 5) {
                Text("原件路径").font(.system(size: 11)).foregroundStyle(Theme.text3)
                Text(a.localPath ?? "演示照片无本地原件")
                    .font(.system(size: 11)).foregroundStyle(Theme.text2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 9).padding(.vertical, 7)
                    .background(Color.black.opacity(0.3))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                HStack(spacing: 6) {
                    pathButton("folder", "在访达中显示", warn: false, disabled: a.localPath == nil) {
                        app.revealInFinder(a.id)
                    }
                    if a.status == .missing {
                        pathButton("link", "重新定位", warn: true) { app.locate(a.id) }
                    }
                }
            }
        }
    }

    private func pathButton(_ icon: String, _ label: String, warn: Bool, disabled: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) { Icon(icon, size: 13); Text(label).font(.system(size: 11.5)) }
                .foregroundStyle(warn ? Theme.accent : Theme.text2)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }

    // ---------- Metadata ----------
    private func metaTab(_ a: Asset) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            InsGroup([.init("相机", a.camera), .init("镜头", a.lens)])
            HStack(spacing: 8) {
                exifCell("焦距", "\(a.focal)mm")
                exifCell("光圈", "ƒ/\(formatAperture(a.aperture))")
            }
            HStack(spacing: 8) {
                exifCell("快门", "\(a.shutter)s")
                exifCell("ISO", "\(a.iso)")
            }
            InsGroup([
                .init("拍摄时间", DateFmt.long(a.date)),
                .init("时间来源", a.captureDateSource),
            ])
            mapView(a)
        }
    }

    private func exifCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10.5)).foregroundStyle(Theme.text3)
            Text(value).font(.system(size: 15, weight: .semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(Color.black.opacity(0.26))
        .overlay(RoundedRectangle(cornerRadius: Theme.r).strokeBorder(Theme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.r))
    }

    private func mapView(_ a: Asset) -> some View {
        ZStack {
            LinearGradient(colors: [Color(hex: "#1e2a33"), Color(hex: "#20302a")],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            MapGrid()
            Icon("location", size: 16).foregroundStyle(Theme.accent)
                .shadow(color: .black.opacity(0.6), radius: 2, y: 2).offset(y: -8)
            VStack {
                Spacer()
                HStack {
                    Text(String(format: "%.4f, %.4f", a.gps.0, a.gps.1))
                        .font(Theme.mono).foregroundStyle(Theme.text2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.black.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 4))
                    Spacer()
                }
            }.padding(7)
        }
        .frame(height: 116)
        .overlay(RoundedRectangle(cornerRadius: Theme.r).strokeBorder(Theme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.r))
    }

    // ---------- History ----------
    private func histTab(_ a: Asset) -> some View {
        InsGroup([
            .init("导入时间", DateFmt.long(a.importedAt)),
            .init("管理方式", "引用式 (Referenced)"),
            .init("内容哈希",
                  a.contentHash.map { "sha256:\($0.prefix(12))…" } ?? "sha256:\(String(a.id.dropFirst()))e7b…",
                  mono: true),
            .init("Quick Hash",
                  a.quickHash.map { "\($0.prefix(10))…" } ?? "\(Int(a.fileMB))M·\(a.pid)af",
                  mono: true),
            .init("原件修改", a.fileModifiedAt.map(DateFmt.short) ?? "—"),
            .init("原件创建", a.fileCreatedAt.map(DateFmt.short) ?? "—"),
            .init("备份状态", "已包含于上次目录库备份", accent: true),
        ])
    }
}

func formatAperture(_ v: Double) -> String {
    v == v.rounded() ? String(format: "%.0f", v) : String(format: "%.1f", v)
}

private struct InsTabButton: View {
    let icon: String
    let active: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Icon(icon, size: 16)
                .foregroundStyle(active ? Theme.accent : (hover ? Theme.text2 : Theme.text3))
                .frame(maxWidth: .infinity).frame(height: 30)
                .background(
                    UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6)
                        .fill(hover && !active ? Color.white(0.03) : .clear))
                .overlay(alignment: .bottom) {
                    if active {
                        RoundedRectangle(cornerRadius: 2).fill(Theme.accent)
                            .frame(height: 2).padding(.horizontal, 6)
                    }
                }
        }
        .buttonStyle(.plain).onHover { hover = $0 }
    }
}

// ---------- Info group / row ----------
struct InfoRowData: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    var mono: Bool = false
    var accent: Bool = false
    init(_ label: String, _ value: String, mono: Bool = false, accent: Bool = false) {
        self.label = label; self.value = value; self.mono = mono; self.accent = accent
    }
}

struct InsGroup: View {
    let rows: [InfoRowData]
    init(_ rows: [InfoRowData]) { self.rows = rows }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, r in
                if idx > 0 { Rectangle().fill(Theme.line).frame(height: 1) }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(r.label).font(.system(size: 12)).foregroundStyle(Theme.text3)
                        .frame(width: 64, alignment: .leading)
                    Text(r.value)
                        .font(r.mono ? .system(size: 11, design: .monospaced) : .system(size: 12))
                        .foregroundStyle(r.accent ? Theme.accent : Theme.text)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .multilineTextAlignment(.trailing)
                }
                .padding(.horizontal, 11).padding(.vertical, 7)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.r).strokeBorder(Theme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.r))
    }
}

struct MapGrid: View {
    var body: some View {
        GeometryReader { geo in
            Path { p in
                let step: CGFloat = 22
                var x: CGFloat = 0
                while x < geo.size.width {
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: geo.size.height)); x += step
                }
                var y: CGFloat = 0
                while y < geo.size.height {
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: geo.size.width, y: y)); y += step
                }
            }
            .stroke(Color.white(0.05), lineWidth: 1)
        }
    }
}
