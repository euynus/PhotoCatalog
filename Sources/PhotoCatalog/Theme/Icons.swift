// ============================================================
//  Icon system
//  The prototype used "SF-Symbol-flavored line icons" (per icons.jsx);
//  on a native app the most faithful rendering is real SF Symbols.
// ============================================================
import SwiftUI

/// Maps each prototype icon name to its closest SF Symbol.
enum IconName {
    static let map: [String: String] = [
        "photos": "photo",
        "clock": "clock",
        "star": "star",
        "flag": "flag",
        "reject": "xmark.circle",
        "trash": "trash",
        "folder": "folder",
        "album": "rectangle.stack",
        "project": "briefcase",
        "client": "person.crop.square",
        "sparkles": "sparkles",
        "tag": "tag",
        "copy": "doc.on.doc",
        "grid": "square.grid.2x2",
        "loupe": "photo",
        "compare": "rectangle.split.2x1",
        "map": "map",
        "search": "magnifyingglass",
        "filter": "line.3.horizontal.decrease",
        "sort": "arrow.up.arrow.down",
        "importIcon": "square.and.arrow.down",
        "export": "square.and.arrow.up",
        "plus": "plus",
        "minus": "minus",
        "close": "xmark",
        "chevronR": "chevron.right",
        "chevronD": "chevron.down",
        "chevronU": "chevron.up",
        "chevronL": "chevron.left",
        "info": "info.circle",
        "aperture": "camera.aperture",
        "organize": "slider.horizontal.3",
        "history": "clock.arrow.circlepath",
        "inspector": "sidebar.right",
        "location": "mappin.and.ellipse",
        "camera": "camera",
        "gear": "gearshape",
        "warning": "exclamationmark.triangle",
        "offline": "wifi.slash",
        "missing": "questionmark.square.dashed",
        "check": "checkmark",
        "pause": "pause.fill",
        "play": "play.fill",
        "refresh": "arrow.clockwise",
        "link": "link",
        "eye": "eye",
        "dotGrid": "circle.grid.3x3.fill",
    ]
}

/// Drop-in replacement for the prototype `<Icon name size stroke>` element.
struct Icon: View {
    let name: String
    var size: CGFloat = 17
    var weight: Font.Weight = .regular

    init(_ name: String, size: CGFloat = 17, weight: Font.Weight = .regular) {
        self.name = name
        self.size = size
        self.weight = weight
    }

    var body: some View {
        Image(systemName: IconName.map[name] ?? "questionmark")
            .font(.system(size: size, weight: weight))
            .imageScale(.medium)
    }
}
