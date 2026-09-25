// ============================================================
//  Location — place photos on a map, or along a GPX track
// ============================================================
import SwiftUI
import MapKit

/// Search a place or click the map; the pin's spot goes to every selected photo.
struct LocationSheet: View {
    @Environment(AppState.self) private var app
    let ids: Set<String>

    @State private var position: MapCameraPosition
    @State private var pin: CLLocationCoordinate2D?
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false
    @State private var searchFailed = false

    /// Opens on the photos' current location (latitude, longitude) when they share one.
    init(ids: Set<String>, current start: (Double, Double)?) {
        self.ids = ids
        let current = start.map { CLLocationCoordinate2D(latitude: $0.0, longitude: $0.1) }
        _pin = State(initialValue: current)
        _position = State(initialValue: current.map {
            .region(MKCoordinateRegion(center: $0, latitudinalMeters: 4000, longitudinalMeters: 4000))
        } ?? .automatic)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "mappin.and.ellipse").foregroundStyle(Theme.accent)
                Text("设置位置 · \(ids.count) 张照片").font(.system(size: 17, weight: .semibold))
                Spacer()
                sheetClose { app.sheet = nil }
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Theme.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }

            HStack(spacing: 0) {
                searchColumn.frame(width: 260)
                Rectangle().fill(Theme.line).frame(width: 1)
                MapReader { proxy in
                    Map(position: $position) {
                        if let pin { Marker("", coordinate: pin).tint(Theme.accentFill) }
                    }
                    .mapStyle(.standard(elevation: .flat))
                    .onTapGesture(coordinateSpace: .local) { point in
                        if let coordinate = proxy.convert(point, from: .local) { pin = coordinate }
                    }
                    .overlay(alignment: .top) {
                        Text("点按地图放置位置")
                            .font(.system(size: 11)).foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.black.opacity(0.5), in: Capsule())
                            .padding(10)
                            .allowsHitTesting(false)
                    }
                }
            }

            HStack(spacing: 9) {
                Text(pin.map { String(format: "%.5f, %.5f", $0.latitude, $0.longitude) } ?? "尚未选择位置")
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.text3)
                Spacer()
                ghostButton(nil, "移除位置", danger: true, disabled: !anyLocated) {
                    app.setLocation(nil, for: ids)
                    app.sheet = nil
                }
                ghostButton(nil, "取消") { app.sheet = nil }
                Button {
                    guard let pin else { return }
                    app.setLocation((pin.latitude, pin.longitude), for: ids)
                    app.sheet = nil
                } label: {
                    Text("设置位置")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 17).padding(.vertical, 8)
                        .background(Theme.accentFill).clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(pin == nil)
                .opacity(pin == nil ? 0.5 : 1)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Theme.bgSidebar)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        }
        .frame(width: 880, height: 600)
        .font(.system(size: 13))
        .foregroundStyle(Theme.text)
        .background(Theme.bgPanel)
    }

    private var anyLocated: Bool {
        app.assets.contains { ids.contains($0.id) && $0.hasGPS }
    }

    private var searchColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("搜索地点", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await search() } }
            if searching {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            } else if searchFailed {
                Text("没有找到结果").font(.system(size: 12)).foregroundStyle(Theme.text3)
            }
            List(results, id: \.self) { item in
                Button {
                    let coordinate = item.placemark.coordinate
                    pin = coordinate
                    withAnimation {
                        position = .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 3000,
                                                              longitudinalMeters: 3000))
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name ?? "未命名地点").lineLimit(1)
                        if let subtitle = item.placemark.title, subtitle != item.name {
                            Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.text3).lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .padding(12)
        .background(Theme.bgSidebar)
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        searching = true
        searchFailed = false
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        let items = (try? await MKLocalSearch(request: request).start())?.mapItems ?? []
        searching = false
        results = items
        searchFailed = items.isEmpty
        if let first = items.first {
            withAnimation {
                position = .region(MKCoordinateRegion(center: first.placemark.coordinate, latitudinalMeters: 6000,
                                                      longitudinalMeters: 6000))
            }
        }
    }
}

/// Matches photos to a GPX track by capture time, with the camera's time zone to line the
/// clocks up. Shows how many photos the track covers before anything changes.
struct GPXMatchSheet: View {
    @Environment(AppState.self) private var app
    let name: String
    let track: GPXTrack
    /// Selected photos, or every photo in the current view.
    let selected: Set<String>
    let inView: Set<String>

    @State private var offsetMinutes: Int
    @State private var useSelection: Bool
    @State private var overwrite = false

    init(name: String, track: GPXTrack, selected: Set<String>, inView: Set<String>) {
        self.name = name
        self.track = track
        self.selected = selected
        self.inView = inView
        _offsetMinutes = State(initialValue: TimeZone.current.secondsFromGMT(for: track.start ?? .now) / 60)
        _useSelection = State(initialValue: selected.count > 1)
    }

    private var ids: Set<String> { useSelection ? selected : inView }
    private var matches: [String: GPXPoint] {
        app.gpxMatches(track, ids: ids, cameraUTCOffset: offsetMinutes * 60, overwrite: overwrite)
    }

    var body: some View {
        let matches = self.matches
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").foregroundStyle(Theme.accent)
                Text("按 GPX 轨迹匹配位置").font(.system(size: 17, weight: .semibold))
                Spacer()
                sheetClose { app.sheet = nil }
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Theme.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }

            Form {
                Section("轨迹") {
                    LabeledContent("文件", value: name)
                    LabeledContent("轨迹点", value: "\(track.points.count)")
                    if let start = track.start, let end = track.end {
                        LabeledContent("时间") {
                            Text(DateFmt.long(start) + " – " + DateFmt.long(end).suffix(5))
                        }
                    }
                }
                Section {
                    Stepper(value: $offsetMinutes, in: -12 * 60...14 * 60, step: 30) {
                        LabeledContent("相机时区", value: offsetTitle)
                    }
                } header: {
                    Text("时间对齐")
                } footer: {
                    Text("相机记录的是当地时间，GPS 轨迹是世界协调时。请设为拍摄时相机时钟所用的时区。")
                        .font(.system(size: 11)).foregroundStyle(Theme.text3)
                }
                Section("照片") {
                    Picker("范围", selection: $useSelection) {
                        Text("选中的 \(selected.count) 张").tag(true)
                        Text("当前视图的 \(inView.count) 张").tag(false)
                    }
                    .pickerStyle(.segmented)
                    Toggle("覆盖已有位置", isOn: $overwrite)
                    LabeledContent("可匹配") {
                        Text("\(matches.count) / \(ids.count) 张")
                            .foregroundStyle(matches.isEmpty ? Theme.text3 : Theme.accent)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack(spacing: 9) {
                Spacer()
                ghostButton(nil, "取消") { app.sheet = nil }
                Button {
                    app.applyGPXMatches(matches)
                    app.sheet = nil
                } label: {
                    Text("添加 \(matches.count) 个位置")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 17).padding(.vertical, 8)
                        .background(Theme.accentFill).clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(matches.isEmpty)
                .opacity(matches.isEmpty ? 0.5 : 1)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Theme.bgSidebar)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        }
        .frame(width: 520, height: 560)
        .font(.system(size: 13))
        .foregroundStyle(Theme.text)
        .background(Theme.bgPanel)
    }

    private var offsetTitle: String {
        let sign = offsetMinutes < 0 ? "-" : "+"
        let value = abs(offsetMinutes)
        return String(format: "UTC%@%d:%02d", sign, value / 60, value % 60)
    }
}
