// ============================================================
//  Develop panel — Lightroom's Basic adjustments
// ============================================================
import SwiftUI
import AppKit

struct DevelopPanel: View {
    @Environment(AppState.self) var app
    let asset: Asset?
    @State var mixerProperty: ColorMixer.Property = .hue
    @State var gradingRegion: ColorGrading.Region = .shadows
    @State var curveChannel: ToneCurve.Channel = .rgb

    var body: some View {
        Group {
            if let asset {
                content(asset)
            } else {
                ContentUnavailableView("未选择照片", systemImage: "slider.horizontal.3")
            }
        }
        .frame(minWidth: Theme.inspectorMinW, idealWidth: Theme.inspectorW, maxWidth: Theme.inspectorMaxW,
               maxHeight: .infinity)
        .background(Theme.bgPanel)
        .foregroundStyle(Theme.text)
    }
}
