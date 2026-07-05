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
        if located.isEmpty {
            VStack(spacing: 10) {
                Icon("location", size: 46).foregroundStyle(Theme.text4)
                Text("没有带位置的照片").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text2)
                Text("含 GPS 信息的照片会显示在地图上").font(.system(size: 12.5)).foregroundStyle(Theme.text3)
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
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat))
            .onMapCameraChange { context in
                cameraDistance = context.camera.distance
            }
            .overlay(alignment: .topLeading) { countBadge }
        }
    }

    private func pin(_ c: Cluster) -> some View {
        Thumb(asset: c.representative, radius: 5)
            .frame(width: 40, height: 30)
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(c.count == 1 && c.representative.id == app.primaryId ? Theme.accent : .white,
                              lineWidth: 2))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(alignment: .topTrailing) {
                if c.count > 1 {
                    Text("\(c.count)")
                        .font(.system(size: 9.5, weight: .bold)).monospacedDigit()
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Theme.accent, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color(hex: "#1c1c1e"), lineWidth: 1))
                        .offset(x: 7, y: -7)
                }
            }
            .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
    }

    private var countBadge: some View {
        HStack(spacing: 6) {
            Icon("location", size: 13).foregroundStyle(Theme.accent)
            Text("\(located.count) 张照片有位置信息").font(.system(size: 12)).foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .background(Color(hex: "#1c1c1e").opacity(0.85), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.line2, lineWidth: 1))
        .padding(14)
    }
}
