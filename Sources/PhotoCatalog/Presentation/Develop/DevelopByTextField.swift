import SwiftUI
import AppKit

/// Develop → AI 调整: a described look, applied by the language model.
struct DevelopByTextField: View {
    @Environment(AppState.self) private var app
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField(L("描述想要的效果，例如：暖一点的胶片感"), text: $text)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit(apply)
                if app.developByTextRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Button("应用", action: apply)
                        .controlSize(.small)
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || !app.isLLMReady)
                }
            }
            if !app.isLLMReady {
                Button("在“设置 → AI”中设置服务后可用") { app.openSettings(category: "ai") }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        }
        .onAppear { if text.isEmpty { text = app.developByTextQuery } }
    }

    private func apply() {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty, !app.developByTextRunning else { return }
        let request = text
        Task { _ = await app.developByText(request) }
    }
}
