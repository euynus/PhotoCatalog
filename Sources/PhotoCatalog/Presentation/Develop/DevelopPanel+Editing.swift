import SwiftUI
import AppKit

extension DevelopPanel {
    func slider(_ control: DevelopControl, _ asset: Asset, _ settings: DevelopSettings) -> some View {
        DevelopSlider(title: control.title, value: settings[keyPath: control.id], range: control.range,
                      step: control.step, format: control.format,
                      isNeutral: settings[keyPath: control.id] == control.neutral,
                      onChange: draft(asset) { $0[keyPath: control.id] = $1 },
                      onReset: { commit(asset, control.title) { $0[keyPath: control.id] = control.neutral } },
                      onCommit: { commitDraft(asset, control.title) })
    }

    // ---- editing: drafts drive the live preview, a release saves one undoable step ----
    func draft(_ asset: Asset,
                       _ apply: @escaping (inout DevelopSettings, Double) -> Void) -> (Double) -> Void {
        { value in
            var next = app.developSettings(for: asset.id)
            apply(&next, value)
            app.updateDevelopDraft(next, for: asset.id)
        }
    }

    func commitDraft(_ asset: Asset, _ title: String) {
        app.commitDevelopDraft(for: asset.id, undoName: L("调整\(title)"))
    }

    func commit(_ asset: Asset, _ title: String, _ apply: (inout DevelopSettings) -> Void) {
        var next = app.developSettings[asset.id] ?? .neutral
        apply(&next)
        app.commitDevelop([asset.id: next], undoName: L("复位\(title)"))
    }
}
