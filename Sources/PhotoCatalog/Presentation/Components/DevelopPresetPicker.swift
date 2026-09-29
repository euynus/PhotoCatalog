// ============================================================
//  Develop preset picker — "none", the built-ins, then the user's own
// ============================================================
import SwiftUI

/// Picks a develop preset by id ("" for none), for the import settings.
struct DevelopPresetPicker: View {
    @Environment(AppState.self) private var app
    @Binding var selection: String

    var body: some View {
        Picker("修图预设", selection: $selection) {
            Text("无").tag("")
            Section("内置") {
                ForEach(DevelopPreset.builtIns) { preset in Text(preset.name).tag(preset.id) }
            }
            if !app.developPresets.isEmpty {
                Section("我的预设") {
                    ForEach(app.developPresets) { preset in Text(preset.name).tag(preset.id) }
                }
            }
            // a preset deleted since it was chosen still shows as chosen, so the picker has a row for it
            if !selection.isEmpty, app.importDevelopPreset == nil {
                Text("已删除的预设").tag(selection)
            }
        }
        .pickerStyle(.menu)
    }
}
