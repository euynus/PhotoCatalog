// ============================================================
//  Develop preset picker — leading choices, the built-ins, then the user's own
// ============================================================
import SwiftUI

/// Picks a develop preset by id, after the `leading` choices ("" for none, by default).
struct DevelopPresetPicker: View {
    @Environment(AppState.self) private var app
    @Binding var selection: String
    var leading: [(tag: String, title: String)] = [("", L("无"))]

    var body: some View {
        Picker("修图预设", selection: $selection) {
            ForEach(leading, id: \.tag) { choice in Text(choice.title).tag(choice.tag) }
            Section("内置") {
                ForEach(DevelopPreset.builtIns) { preset in Text(preset.name).tag(preset.id) }
            }
            if !app.developPresets.isEmpty {
                Section("我的预设") {
                    ForEach(app.developPresets) { preset in Text(preset.name).tag(preset.id) }
                }
            }
            // a preset deleted since it was chosen still shows as chosen, so the picker has a row for it
            if !leading.contains(where: { $0.tag == selection }), !app.allDevelopPresets.contains(where: { $0.id == selection }) {
                Text("已删除的预设").tag(selection)
            }
        }
        .pickerStyle(.menu)
    }
}
