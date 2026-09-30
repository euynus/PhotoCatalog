// ============================================================
//  Natural-language search dialog
// ============================================================
import SwiftUI

struct NaturalSearchSheet: View {
    @Environment(AppState.self) private var app
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("用自然语言查找").font(.system(size: 17, weight: .semibold))
                Spacer()
                sheetClose { app.sheet = nil }
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Theme.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }

            VStack(alignment: .leading, spacing: 10) {
                Text("用一句话描述要找的照片，AI 会把它换成筛选条件和搜索词，在当前来源中查找。只发送这句话和目录库中的相机、镜头与关键词名称，不发送照片。")
                    .font(.system(size: 12)).foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
                TextField(L("例如：去年夏天在海边拍的、四星以上的照片"), text: $query, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(search)
                if !app.isLLMReady {
                    HStack(spacing: 8) {
                        Label("还没有设置 AI 服务", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12)).foregroundStyle(Theme.text2)
                        Button("打开设置") { app.openSettings(category: "ai") }.controlSize(.small)
                    }
                }
            }
            .padding(18)

            HStack(spacing: 9) {
                if app.naturalSearchRunning { ProgressView().controlSize(.small) }
                Spacer()
                ghostButton(nil, L("取消")) { app.sheet = nil }
                Button(action: search) {
                    Text("查找")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 17).padding(.vertical, 8)
                        .background(Theme.accentFill).clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSearch)
                .opacity(canSearch ? 1 : 0.5)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Theme.bgSidebar)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        }
        .frame(width: 480)
        .font(.system(size: 13))
        .foregroundStyle(Theme.text)
        .background(Theme.bgPanel)
        .onAppear {
            query = app.naturalSearchQuery
            focused = true
        }
    }

    private var canSearch: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && app.isLLMReady && !app.naturalSearchRunning
    }

    private func search() {
        guard canSearch else { return }
        Task {
            if await app.searchNaturally(query) { app.sheet = nil }
        }
    }
}
