// ============================================================
//  Copy / sync settings and new-preset dialog — which settings travel
// ============================================================
import SwiftUI

struct DevelopTransferSheet: View {
    @Environment(AppState.self) private var app
    let mode: AppState.DevelopTransferMode

    @State private var fields: Set<DevelopField>
    @State private var name = ""

    init(mode: AppState.DevelopTransferMode, fields: Set<DevelopField>) {
        self.mode = mode
        _fields = State(initialValue: fields)
    }

    private var title: String {
        switch mode {
        case .copy: "拷贝修图设置"
        case .sync: "同步修图设置"
        case .preset: "新建修图预设"
        }
    }

    private var actionTitle: String {
        switch mode {
        case .copy: "拷贝"
        case .sync: "同步"
        case .preset: "存储预设"
        }
    }

    private var canConfirm: Bool {
        !fields.isEmpty && (mode != .preset || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 17, weight: .semibold))
                Spacer()
                sheetClose { app.sheet = nil }
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Theme.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }

            VStack(alignment: .leading, spacing: 14) {
                if mode == .preset {
                    TextField("预设名称", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                if mode == .sync {
                    Text("把当前照片的所选设置应用到其他选中的照片。")
                        .font(.system(size: 12)).foregroundStyle(Theme.text3)
                }
                ForEach(DevelopField.groups, id: \.title) { group in
                    fieldGroup(group.title, group.fields)
                }
                HStack(spacing: 12) {
                    Button("全选") { fields = Set(DevelopField.allCases) }
                    Button("全不选") { fields = [] }
                    Spacer()
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
            }
            .padding(18)

            HStack(spacing: 9) {
                Spacer()
                ghostButton(nil, "取消") { app.sheet = nil }
                Button(action: confirm) {
                    Text(actionTitle)
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.onAccent)
                        .fixedSize()
                        .padding(.horizontal, 17).padding(.vertical, 8)
                        .background(Theme.accentFill).clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(!canConfirm)
                .opacity(canConfirm ? 1 : 0.5)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Theme.bgSidebar)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        }
        .frame(width: 420)
        .font(.system(size: 13))
        .foregroundStyle(Theme.text)
        .background(Theme.bgPanel)
    }

    /// A section with a checkbox for all of it (mixed when partly checked) and one per setting.
    private func fieldGroup(_ title: String, _ members: [DevelopField]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(sources: members.map(binding), isOn: \.self) {
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .toggleStyle(.checkbox)
            if members.count > 1 {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                          alignment: .leading, spacing: 6) {
                    ForEach(members) { field in
                        Toggle(field.title, isOn: binding(field)).toggleStyle(.checkbox)
                    }
                }
                .padding(.leading, 20)
            }
        }
    }

    private func binding(_ field: DevelopField) -> Binding<Bool> {
        Binding(get: { fields.contains(field) },
                set: { on in if on { fields.insert(field) } else { fields.remove(field) } })
    }

    private func confirm() {
        guard canConfirm else { return }
        switch mode {
        case .copy:
            app.developTransferFields = fields
            app.copyDevelopSettings(fields: fields)
        case .sync:
            app.developTransferFields = fields
            app.syncDevelopSettings(fields: fields)
        case .preset:
            app.saveDevelopPreset(name: name, fields: fields)
        }
        app.sheet = nil
    }
}
