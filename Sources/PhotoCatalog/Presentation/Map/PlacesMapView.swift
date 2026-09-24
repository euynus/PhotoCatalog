// ============================================================
//  Places — map of GPS-tagged photos (PRD §6.7 UI-008, §14.2)
// ============================================================
import SwiftUI
import MapKit

struct PlacesMapView: View {
    @Environment(AppState.self) var app
    @State private var position: MapCameraPosition = .automatic
    /// Camera height in meters — drives the clustering grid size.
    @State private var cameraDistance: Double = 10_000_000

    private var located: [Asset] {
        app.list.filter(\.hasGPS)
    }

    private struct Cluster: Identifiable {
        let id: String
        let representative: Asset
        let count: Int
        let coordinate: CLLocationCoordinate2D
    }

    /// Bucket size in degrees — roughly what a 40 pt pin covers at the current
    /// camera height, so pins never pile on top of each other. One hosted
    /// annotation (with a live image loader) per photo does not scale.
    private var gridStep: Double {
        max(0.0005, (cameraDistance / 111_000) / 12)
    }

    private var clusters: [Cluster] {
        let step = gridStep
        var buckets: [String: (rep: Asset, count: Int, latSum: Double, lngSum: Double)] = [:]
        var order: [String] = []
        for a in located {
            let key = "\(Int((a.gps.0 / step).rounded()))|\(Int((a.gps.1 / step).rounded()))"
            if var b = buckets[key] {
                b.count += 1
                b.latSum += a.gps.0
                b.lngSum += a.gps.1
                buckets[key] = b
            } else {
                buckets[key] = (a, 1, a.gps.0, a.gps.1)
                order.append(key)
            }
        }
        return order.compactMap { key in
            guard let b = buckets[key] else { return nil }
            return Cluster(id: key, representative: b.rep, count: b.count,
                           coordinate: CLLocationCoordinate2D(latitude: b.latSum / Double(b.count),
                                                              longitude: b.lngSum / Double(b.count)))
        }
    }

    var body: some View {
        Group {
            if located.isEmpty {
                ContentUnavailableView {
                    Label("没有带位置的照片", systemImage: "mappin.and.ellipse")
                } description: {
                    Text("包含 GPS 信息的照片会按拍摄地点聚合显示在地图上。")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Map(position: $position) {
                    ForEach(clusters) { c in
                        Annotation("", coordinate: c.coordinate) {
                            Button {
                                if c.count == 1 {
                                    app.openLoupe(c.representative.id)
                                } else {
                                    withAnimation {
                                        position = .camera(MapCamera(centerCoordinate: c.coordinate,
                                                                     distance: max(cameraDistance / 6, 1200)))
                                    }
                                }
                            } label: { pin(c) }.buttonStyle(.plain)
                                .help(c.count == 1 ? c.representative.filename : "\(c.count) 张照片 — 点按放大")
                                .accessibilityLabel(c.count == 1 ? c.representative.filename : "\(c.count) 张照片")
                                .accessibilityHint(c.count == 1 ? "打开照片" : "放大地图")
                        }
                    }
                }
                .mapStyle(.standard(elevation: .flat))
                .onMapCameraChange { context in
                    cameraDistance = context.camera.distance
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { countBadge }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgContent)
    }

    private func pin(_ c: Cluster) -> some View {
        Thumb(asset: c.representative, radius: 5, maxDecodePixel: 80)
            .frame(width: 40, height: 30)
            .background(Theme.canvasSurface)
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(c.count == 1 && c.representative.id == app.primaryId ? Theme.accent : Theme.surface,
                              lineWidth: 2))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(alignment: .topTrailing) {
                if c.count > 1 {
                    Text("\(c.count)")
                        .font(.system(size: 9.5, weight: .bold)).monospacedDigit()
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Theme.accent, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.surface, lineWidth: 1))
                        .offset(x: 7, y: -7)
                }
            }
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
    }

    private var countBadge: some View {
        HStack(spacing: 6) {
            Icon("location", size: 13).foregroundStyle(Theme.accent)
            Text("\(located.count) 张照片有位置信息").font(.system(size: 13)).foregroundStyle(Theme.text)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Theme.bgSidebar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}
