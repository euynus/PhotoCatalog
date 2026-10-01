// ============================================================
//  Develop profiles — the Profile row at the top of Lightroom's Basic panel
// ============================================================
import SwiftUI

/// The profiles as buttons. Resting the pointer on one shows its look on the photo, as the
/// presets do; a click chooses it. Any but Standard shows its amount.
struct DevelopProfilePicker: View {
    @Environment(AppState.self) private var app
    let asset: Asset
    let settings: DevelopSettings
    @State private var hovered: DevelopProfile?

    var body: some View {
        let current = DevelopProfile(stored: settings.profile)
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(DevelopProfile.allCases) { profile in
                    button(profile, selected: profile == current)
                }
            }
            if current != .standard {
                let control = DevelopControl.profileAmount
                DevelopSlider(title: control.title, value: settings.profileAmount, range: control.range, step: control.step,
                              format: control.format, isNeutral: settings.profileAmount == control.neutral,
                              onChange: { value in
                                  var next = app.developSettings(for: asset.id)
                                  next.profileAmount = value
                                  app.updateDevelopDraft(next, for: asset.id)
                              },
                              onReset: {
                                  var next = app.developSettings[asset.id] ?? .neutral
                                  next.profileAmount = control.neutral
                                  app.commitDevelop([asset.id: next], undoName: L("配置文件数量"))
                              },
                              onCommit: {
                                  guard let draft = app.developDraft, draft.assetId == asset.id else { return }
                                  app.commitDevelop([asset.id: draft.settings], undoName: L("配置文件数量"))
                              })
            }
        }
        .onChange(of: asset.id) {
            hovered = nil
            app.endDevelopPresetPreview()
        }
        .onDisappear { app.endDevelopPresetPreview() }
    }

    private func button(_ profile: DevelopProfile, selected: Bool) -> some View {
        Button { app.setDevelopProfile(profile, for: asset) } label: {
            Text(profile.title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.accent : Theme.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(selected ? Theme.accentSoft : hovered == profile ? Theme.surfaceHi : Theme.surface,
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Theme.accent : Theme.line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(profile.help)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { inside in
            if inside {
                hovered = profile
                app.previewDevelopProfile(profile, on: asset)
            } else if hovered == profile {
                hovered = nil
                app.endDevelopProfilePreview(profile)
            }
        }
    }
}
