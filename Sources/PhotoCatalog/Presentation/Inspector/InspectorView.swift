// ============================================================
//  Inspector — port of inspector.jsx (Info / Metadata / Organize / History)
// ============================================================
import SwiftUI

struct InspectorView: View {
    @Environment(AppState.self) var app
    let asset: Asset?
    let assetRevision: Int

    var body: some View {
        let _ = assetRevision
        Group {
            if let asset {
                content(asset)
            } else {
                VStack(spacing: 10) {
                    Icon("inspector", size: 24)
                    Text("未选择照片").font(.system(size: 13))
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
            header(asset)
            InspectorTabPicker()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch app.insTab {
                    case "info": infoTab(asset)
                    case "meta": metaTab(asset)
                    case "org": OrganizeTab(asset: asset, assetRevision: assetRevision)
                    default: histTab(asset)
                    }
                }
                .padding(12)
            }
        }
    }

    private func header(_ asset: Asset) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                // Keep the loader alive across selection changes.
                Thumb(asset: asset, urlString: asset.thumb, radius: 5, contentMode: .fit,
                      maxDecodePixel: 160)
                    .frame(width: 64, height: 64)
                    .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .accessibilityHidden(true)
                headline(asset)
            }
            ExposureStrip(asset: asset)
            if hasCameraInfo(asset) {
                Label(cameraLine(asset), systemImage: "camera")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(cameraLine(asset))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hasCameraInfo(_ asset: Asset) -> Bool {
        !asset.camera.isEmpty || !asset.lens.isEmpty
    }

    private func cameraLine(_ asset: Asset) -> String {
        [asset.camera, asset.lens].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func headline(_ asset: Asset) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(asset.filename)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2).truncationMode(.middle)
                .help(asset.filename)
                .textSelection(.enabled)
            Text("\(asset.width) × \(asset.height) · \(megapixelText(asset.megapixels)) · \(fileSizeText(megabytes: asset.fileMB))")
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.text2)
                .lineLimit(1)
            if app.selectedIds.count > 1 {
                Label("\(app.selectedIds.count) 张 · 批量编辑", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                    .help("编辑将批量应用")
                    .accessibilityHint("编辑将批量应用")
            } else {
                HStack(spacing: 4) {
                    TypeBadge(asset: asset, small: true)
                    if let pair = GridView.pairLabel(app.companions(of: asset)) {
                        Text("+ \(pair)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.text3)
                            .help("RAW + \(pair) 显示为一张照片，编辑同时写入两个文件")
                    }
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }


    // ---------- Info ----------
    private func infoTab(_ a: Asset) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            InsGroup([
                .init(L("文件名"), a.filename, mono: true),
                .init(L("类型"), a.isRaw ? "RAW · \(a.type)" : a.type),
                .init(L("大小"), fileSizeText(megabytes: a.fileMB)),
                .init(L("尺寸"), "\(a.width) × \(a.height)", mono: true),
                .init(L("色彩空间"), a.colorSpace),
                .init("ICC", a.hasICCProfile ? L("有") : L("无")),
            ] + pairRows(a), title: L("文件"))
            InsGroup({
                var rows: [InfoRowData] = [
                    .init(L("文件夹", table: "Context"), a.folderName),
                    .init(L("位置"), a.location),
                    .init(L("状态"),
                          a.status == .ready ? L("可访问") : (a.status == .offline ? L("离线（外置盘）") : L("缺失")),
                          accent: a.status != .ready),
                ]
                if a.faces > 0 { rows.append(.init(L("人脸"), L("检测到 \(a.faces) 张"))) }
                return rows
            }(), title: L("来源"))
            VStack(alignment: .leading, spacing: 8) {
                Text("原件路径").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text2)
                    .accessibilityAddTraits(.isHeader)
                Text(a.localPath ?? L("演示照片无本地原件"))
                    .font(Theme.mono).foregroundStyle(Theme.text2)
                    .lineSpacing(2)
                    .lineLimit(4).truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .help(a.localPath ?? L("演示照片无本地原件"))
                HStack(spacing: 6) {
                    let canReveal = a.localPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
                    pathButton("folder", L("在访达中显示"), warn: false, disabled: !canReveal) {
                        app.revealInFinder(a.id)
                    }
                    if a.status == .missing {
                        pathButton("link", L("重新定位"), warn: true) { app.locate(a.id) }
                    }
                }
            }
        }
    }

    private func pairRows(_ a: Asset) -> [InfoRowData] {
        let companions = app.companions(of: a)
        guard !companions.isEmpty else { return [] }
        return [.init(L("配对文件"),
                      companions.map { "\($0.filename) · \(fileSizeText(megabytes: $0.fileMB))" }
                        .joined(separator: "\n"),
                      mono: true)]
    }

    private func pathButton(_ icon: String, _ label: String, warn: Bool, disabled: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) { Icon(icon, size: 13); Text(label).font(.system(size: 13)) }
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
        VStack(alignment: .leading, spacing: 12) {
            InsGroup([.init(L("相机"), a.camera), .init(L("镜头"), a.lens)], title: L("设备", table: "Context"))
            InsGroup([
                .init(L("焦距"), formatFocalLength(a.focal)),
                .init(L("光圈"), formatApertureValue(a.aperture)),
                .init(L("快门"), formatShutterSpeed(a.shutter)),
                .init("ISO", formatISOValue(a.iso)),
            ], title: L("曝光"))
            InsGroup([
                .init(L("拍摄时间"), DateFmt.longCapture(a.date)),
                .init(L("时间来源"), CaptureDateSource.label(a.captureDateSource)),
            ], title: L("拍摄信息"))
            let rightsRows = [
                a.author.isEmpty ? nil : InfoRowData(L("作者"), a.author),
                a.copyright.isEmpty ? nil : InfoRowData(L("版权"), a.copyright),
            ].compactMap { $0 }
            if !rightsRows.isEmpty { InsGroup(rightsRows, title: L("版权")) }
            if !a.makerNotes.isEmpty {
                MakerNotesGroup(rows: makerNoteRows(a.makerNotes))
            }
            gpsPanel(a)
        }
    }

    @ViewBuilder
    private func gpsPanel(_ a: Asset) -> some View {
        if a.hasGPS {
            InsGroup([
                .init(L("坐标"), formatGPSLabel(a.gps, altitude: a.gpsAltitude, isPresent: a.hasGPS), mono: true),
            ], title: L("位置"))
        } else {
            HStack(spacing: 8) {
                Icon("location", size: 16).foregroundStyle(Theme.text3)
                Text("无 GPS 信息").font(.system(size: 13)).foregroundStyle(Theme.text3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    // ---------- History ----------
    private func histTab(_ a: Asset) -> some View {
        InsGroup([
            .init(L("导入时间"), DateFmt.long(a.importedAt)),
            .init(L("管理方式"), app.managementDisplayText(for: a)),
            .init(L("内容哈希"),
                  a.contentHash.map { "sha256:\($0.prefix(12))…" } ?? L("未计算"),
                  mono: true),
            .init("Quick Hash",
                  a.quickHash.map { "\($0.prefix(10))…" } ?? L("未计算"),
                  mono: true),
            .init(L("原件修改"), a.fileModifiedAt.map { DateFmt.short($0) } ?? "—"),
            .init(L("原件创建"), a.fileCreatedAt.map { DateFmt.short($0) } ?? "—"),
            .init(L("目录库备份"), app.statusBackupText),
        ], title: L("记录"))
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
    guard isPresent ?? hasGPS(gps) else { return L("无 GPS") }
    let coordinate = String(format: "%.4f, %.4f", gps.0, gps.1)
    guard let altitude else { return coordinate }
    return coordinate + " · \(formatAltitude(altitude))"
}

/// Its own view so a new selection doesn't re-run the segmented control's AppKit update.
private struct InspectorTabPicker: View {
    @Environment(AppState.self) private var app
    private static let tabs = [("info", L("信息")), ("meta", L("元数据")), ("org", L("整理")), ("hist", L("历史"))]

    var body: some View {
        @Bindable var app = app
        Picker("简介分页", selection: $app.insTab) {
            ForEach(Self.tabs, id: \.0) { tab in
                Text(tab.1).tag(tab.0)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

/// Splits the "Vendor: key=value, key=value · …" summary into readable rows.
func makerNoteRows(_ summary: String) -> [InfoRowData] {
    summary.components(separatedBy: " · ").flatMap { entry -> [InfoRowData] in
        guard let colon = entry.range(of: ": ") else { return [InfoRowData(L("备注"), entry)] }
        let name = String(entry[..<colon.lowerBound])
        let body = String(entry[colon.upperBound...])
        let pairs = body.components(separatedBy: ", ").compactMap { pair -> InfoRowData? in
            guard let eq = pair.firstIndex(of: "=") else { return nil }
            let value = pair[pair.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : InfoRowData(String(pair[..<eq]), value)
        }
        return pairs.isEmpty ? [InfoRowData(name, body)] : pairs
    }
}

/// Camera exposure at a glance — the four numbers photographers scan first.
struct ExposureStrip: View {
    let asset: Asset

    var body: some View {
        HStack(spacing: 0) {
            cell(formatFocalLength(asset.focal), L("焦距"))
            divider
            cell(formatApertureValue(asset.aperture), L("光圈"))
            divider
            cell(formatShutterSpeed(asset.shutter), L("快门"))
            divider
            cell(formatISOValue(asset.iso), "ISO")
        }
        .frame(height: 44)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var divider: some View {
        Rectangle().fill(Theme.line).frame(width: 1, height: 24)
    }

    private func cell(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .foregroundStyle(value == "—" ? Theme.text4 : Theme.text)
                .lineLimit(1).minimumScaleFactor(0.75)
            Text(label).font(.system(size: 10)).foregroundStyle(Theme.text3)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct MakerNotesGroup: View {
    let rows: [InfoRowData]
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            InsGroup(rows, title: "", compact: true)
                .padding(.top, 4)
        } label: {
            Text("厂商信息").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text2)
        }
        .tint(Theme.text3)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
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
    var compact = false
    init(_ rows: [InfoRowData], title: String, compact: Bool = false) {
        self.rows = rows
        self.title = title
        self.compact = compact
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !title.isEmpty {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text2)
                    .padding(.bottom, 6)
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(rows) { r in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(r.label).font(.system(size: compact ? 11 : 13)).foregroundStyle(Theme.text3)
                        .frame(width: compact ? 96 : 68, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(r.value)
                        .font(r.mono ? .system(size: 12, design: .monospaced) : .system(size: compact ? 11 : 13))
                        .foregroundStyle(r.accent ? Theme.accent : Theme.text)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(.bottom, compact ? 0 : 8)
        .overlay(alignment: .bottom) {
            if !compact { Rectangle().fill(Theme.line).frame(height: 1) }
        }
    }
}
