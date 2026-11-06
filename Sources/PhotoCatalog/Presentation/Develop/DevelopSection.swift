import SwiftUI
import AppKit

/// The Develop sections, by the id their folded state is kept under, on each side.
enum DevelopSections {
    static let panel = ["profile", "whiteBalance", "tone", "presence", "curve", "mixer", "grading", "detail", "lens",
                        "transform", "effects", "lensBlur", "calibration", "lut", "ai", "softProof"]
    static let sidebar = ["presets", "snapshots", "history"]
    /// Sections folded shut, one id per line; the rarely used ones start folded.
    static let storageKey = "pc_collapsedDevelopSections"
    static let initiallyFolded = "calibration\nlut\nsoftProof"
}

/// A Develop section that folds shut at its title, as Lightroom's do; ⌥-click (or the title's
/// menu) opens it alone among its `group`. `accessory` sits at the end of the title row, as
/// Lightroom's Auto does. A folded section doesn't build its content.
struct DevelopSection<Accessory: View, Content: View>: View {
    let title: String
    let id: String
    let group: [String]
    let accessory: () -> Accessory
    let content: () -> Content
    @AppStorage(DevelopSections.storageKey, store: .app) private var collapsed = DevelopSections.initiallyFolded

    init(_ title: String, id: String, group: [String], @ViewBuilder accessory: @escaping () -> Accessory,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.id = id
        self.group = group
        self.accessory = accessory
        self.content = content
    }

    private var folded: Set<String> { Set(collapsed.split(separator: "\n").map(String.init)) }

    private func setFolded(_ ids: Set<String>) { collapsed = ids.sorted().joined(separator: "\n") }

    /// Folds every section of the group but this one, leaving the other side's alone.
    private func openAlone() { setFolded(folded.union(group).subtracting([id])) }

    var body: some View {
        let isFolded = folded.contains(id)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    if NSEvent.modifierFlags.contains(.option) {
                        openAlone()
                    } else {
                        setFolded(isFolded ? folded.subtracting([id]) : folded.union([id]))
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(isFolded ? 0 : 90))
                            .frame(width: 10)
                        Text(title).font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(Theme.text2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("点按折叠或展开 · ⌥ 点按只展开这一项")
                .accessibilityLabel(title)
                .accessibilityValue(isFolded ? L("已折叠") : L("已展开"))
                .accessibilityAddTraits(.isHeader)
                .contextMenu {
                    Button("只展开“\(title)”") { openAlone() }
                    Button("全部展开") { setFolded(folded.subtracting(group)) }
                    Button("全部折叠") { setFolded(folded.union(group)) }
                }
                Spacer(minLength: 0)
                accessory()
            }
            if !isFolded { content() }
        }
        .padding(.bottom, isFolded ? 6 : 12)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}
