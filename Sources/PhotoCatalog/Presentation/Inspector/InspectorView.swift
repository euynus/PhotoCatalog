// ============================================================
//  Inspector — port of inspector.jsx (Info / Metadata / Organize / History)
// ============================================================
import SwiftUI

struct InspectorView: View {
    @Environment(AppState.self) var app
    let asset: Asset?
    let assetRevision: Int

    private let tabs: [(String, String, String)] = [
        ("info", "info", "信息"), ("meta", "aperture", "元数据"),
        ("org", "organize", "整理"), ("hist", "history", "历史"),
    ]

    var body: some View {
        Group {
            if let asset {
                content(asset)
                    .id(assetRevision)
            } else {
                VStack(spacing: 10) {
                    Icon("inspector", size: 34)
                    Text("未选择照片").font(.system(size: 12.5))
                }
                .foregroundStyle(Theme.text3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: Theme.inspectorMinW,
               idealWidth: Theme.inspectorW,
               maxWidth: Theme.inspectorMaxW,
               maxHeight: .infinity)
        .background(Theme.bgPanel)
        .foregroundStyle(Theme.text)
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
                .padding(.horizontal, 14).padding(.vertical, 16)
            }
        }
    }

    private func preview(_ asset: Asset) -> some View {
        VStack(spacing: 0) {
            // Keep the loader alive across selection changes.
            Thumb(asset: asset, urlString: asset.thumb, radius: 0, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
            if app.selectedIds.count > 1 {
                Label("\(app.selectedIds.count) 张 · 批量编辑", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.canvasText2)
                    .lineLimit(1)
                    .padding(.horizontal, 12).padding(.bottom, 10)
                    .help("编辑将批量应用")
                    .accessibilityHint("编辑将批量应用")
            }
        }
        .frame(height: 196)
        .frame(maxWidth: .infinity)
        .background(Theme.canvas)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.canvasLine).frame(height: 1) }
    }

    private func headline(_ asset: Asset) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(asset.filename)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1).truncationMode(.middle)
                .help(asset.filename)
            HStack(spacing: 6) {
                TypeBadge(asset: asset, small: true)
                Text("\(asset.width) × \(asset.height)")
                Text("·")
                Text(megapixelText(asset.megapixels))
            }
            .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.text2)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(tabs, id: \.0) { tab in
                InsTabButton(icon: tab.1, name: tab.2, active: app.insTab == tab.0) { app.insTab = tab.0 }
            }
        }
        .padding(.horizontal, 10).padding(.top, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    // ---------- Info ----------
    private func infoTab(_ a: Asset) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            InsGroup([
                .init("文件名", a.filename, mono: true),
                .init("类型", a.isRaw ? "RAW · \(a.type)" : a.type),
                .init("大小", fileSizeText(megabytes: a.fileMB)),
                .init("尺寸", "\(a.width) × \(a.height)", mono: true),
                .init("色彩空间", a.colorSpace),
                .init("ICC", a.hasICCProfile ? "有" : "无"),
            ], title: "文件")
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
            }(), title: "来源")
            VStack(alignment: .leading, spacing: 9) {
                Text("原件路径").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.text2)
                Text(a.localPath ?? "演示照片无本地原件")
                    .font(Theme.mono).foregroundStyle(Theme.text2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    let canReveal = a.localPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
                    pathButton("folder", "在访达中显示", warn: false, disabled: !canReveal) {
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
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(disabled)
        .help(label)
        .accessibilityLabel(label)
    }

    // ---------- Metadata ----------
    private func metaTab(_ a: Asset) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            InsGroup([.init("相机", a.camera), .init("镜头", a.lens)], title: "设备")
            HStack(spacing: 8) {
                exifCell("焦距", formatFocalLength(a.focal))
                exifCell("光圈", formatApertureValue(a.aperture))
            }
            HStack(spacing: 8) {
                exifCell("快门", formatShutterSpeed(a.shutter))
                exifCell("ISO", formatISOValue(a.iso))
            }
            InsGroup([
                .init("拍摄时间", DateFmt.longCapture(a.date)),
                .init("时间来源", a.captureDateSource),
            ], title: "拍摄信息")
            let rightsRows = [
                a.author.isEmpty ? nil : InfoRowData("作者", a.author),
                a.copyright.isEmpty ? nil : InfoRowData("版权", a.copyright),
            ].compactMap { $0 }
            if !rightsRows.isEmpty { InsGroup(rightsRows, title: "版权") }
            if !a.makerNotes.isEmpty {
                InsGroup([.init("MakerNotes", a.makerNotes)], title: "厂商信息")
            }
            gpsPanel(a)
        }
    }

    private func exifCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.text3)
            Text(value).font(.system(size: 17, weight: .medium)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func gpsPanel(_ a: Asset) -> some View {
        if a.hasGPS {
            mapView(a)
        } else {
            HStack(spacing: 8) {
                Icon("location", size: 16).foregroundStyle(Theme.text3)
                Text("无 GPS 信息").font(.system(size: 12)).foregroundStyle(Theme.text3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
        }
    }

    private func mapView(_ a: Asset) -> some View {
        ZStack {
            Theme.surface
            MapGrid()
            Icon("location", size: 16).foregroundStyle(Theme.accent)
                .offset(y: -8)
            VStack {
                Spacer()
                Text(formatGPSLabel(a.gps, altitude: a.gpsAltitude, isPresent: a.hasGPS))
                    .font(Theme.mono).foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(Theme.bgPanel)
            }
        }
        .frame(height: 116)
        .overlay(RoundedRectangle(cornerRadius: Theme.r).strokeBorder(Theme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.r))
    }

    // ---------- History ----------
    private func histTab(_ a: Asset) -> some View {
        InsGroup([
            .init("导入时间", DateFmt.long(a.importedAt)),
            .init("管理方式", app.managementDisplayText(for: a)),
            .init("内容哈希",
                  a.contentHash.map { "sha256:\($0.prefix(12))…" } ?? "sha256:\(String(a.id.dropFirst()))e7b…",
                  mono: true),
            .init("Quick Hash",
                  a.quickHash.map { "\($0.prefix(10))…" } ?? "\(Int(a.fileMB))M·\(a.pid)af",
                  mono: true),
            .init("原件修改", a.fileModifiedAt.map { DateFmt.short($0) } ?? "—"),
            .init("原件创建", a.fileCreatedAt.map { DateFmt.short($0) } ?? "—"),
            .init("备份状态", "已包含于上次目录库备份", accent: true),
        ], title: "记录")
    }

}

func formatAperture(_ v: Double) -> String {
    v == v.rounded() ? String(format: "%.0f", v) : String(format: "%.1f", v)
}

func formatFocalLength(_ value: Int) -> String {
    value > 0 ? "\(value)mm" : "—"
}

func formatApertureValue(_ value: Double) -> String {
    value > 0 ? "ƒ/\(formatAperture(value))" : "—"
}

func formatShutterSpeed(_ value: String) -> String {
    value.isEmpty ? "—" : "\(value)s"
}

func formatISO(_ value: Int) -> String {
    value > 0 ? "ISO\(value)" : "—"
}

func formatISOValue(_ value: Int) -> String {
    value > 0 ? "\(value)" : "—"
}

func exposureSummary(_ asset: Asset, separator: String = " · ") -> String {
    let parts = [
        formatFocalLength(asset.focal),
        formatApertureValue(asset.aperture),
        formatShutterSpeed(asset.shutter),
        formatISO(asset.iso),
    ].filter { $0 != "—" }
    return parts.isEmpty ? "—" : parts.joined(separator: separator)
}

func formatAltitude(_ value: Double) -> String {
    value == value.rounded() ? "\(Int(value.rounded())) m" : String(format: "%.1f m", value)
}

func hasGPS(_ gps: (Double, Double)) -> Bool {
    !(gps.0 == 0 && gps.1 == 0)
}

func formatGPSLabel(_ gps: (Double, Double), altitude: Double?, isPresent: Bool? = nil) -> String {
    guard isPresent ?? hasGPS(gps) else { return "无 GPS" }
    let coordinate = String(format: "%.4f, %.4f", gps.0, gps.1)
    guard let altitude else { return coordinate }
    return coordinate + " · \(formatAltitude(altitude))"
}

private struct InsTabButton: View {
    let icon: String
    let name: String
    let active: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Icon(icon, size: 15)
                Text(name).font(.system(size: 10.5, weight: active ? .semibold : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(active ? Theme.accent : (hover ? Theme.text2 : Theme.text3))
            .frame(maxWidth: .infinity).frame(height: 46)
            .background(
                UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6)
                    .fill(active ? Theme.accentSoft : (hover ? Theme.surfaceHi : .clear)))
            .overlay(alignment: .bottom) {
                if active {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.accent)
                        .frame(height: 2).padding(.horizontal, 6)
                }
            }
        }
        .buttonStyle(.plain).onHover { hover = $0 }
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(active ? .isSelected : [])
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
    let title: String
    init(_ rows: [InfoRowData], title: String) {
        self.rows = rows
        self.title = title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.text2)
                .padding(.bottom, 7)
                .accessibilityAddTraits(.isHeader)
            ForEach(rows) { r in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(r.label).font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                        .frame(width: 68, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(r.value)
                        .font(r.mono ? .system(size: 11, design: .monospaced) : .system(size: 12))
                        .foregroundStyle(r.accent ? Theme.accent : Theme.text)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 6)
            }
        }
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
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
            .stroke(Theme.line, lineWidth: 1)
        }
    }
}
