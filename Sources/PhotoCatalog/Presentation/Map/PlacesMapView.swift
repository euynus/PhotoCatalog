// ============================================================
//  Places — map of GPS-tagged photos (PRD §6.7 UI-008, §14.2)
// ============================================================
import SwiftUI
import MapKit

struct PlacesMapView: View {
    @EnvironmentObject var app: AppState

    private var located: [Asset] {
        app.list.filter { !($0.gps.0 == 0 && $0.gps.1 == 0) }
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
            Map(initialPosition: .automatic) {
                ForEach(located) { a in
                    Annotation("", coordinate: CLLocationCoordinate2D(latitude: a.gps.0, longitude: a.gps.1)) {
                        Button { app.openLoupe(a.id) } label: { pin(a) }.buttonStyle(.plain)
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat))
            .overlay(alignment: .topLeading) { countBadge }
        }
    }

    private func pin(_ a: Asset) -> some View {
        Thumb(asset: a, radius: 5)
            .frame(width: 40, height: 30)
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(a.id == app.primaryId ? Theme.accent : .white, lineWidth: 2))
            .clipShape(RoundedRectangle(cornerRadius: 5))
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
