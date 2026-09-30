// ============================================================
//  Settings → AI — the language-model service the AI features use
// ============================================================
import SwiftUI

/// Picks the service (Anthropic or an OpenAI-compatible endpoint), its address and model, and
/// keeps the API key in the keychain.
struct AISettings: View {
    @Environment(AppState.self) private var app
    @State private var key = ""
    @State private var keyLoaded = false

    var body: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: 12) {
            Text("用于 AI 描述照片、用自然语言查找和用文字修图。只在使用这些功能时联网，照片只发送缩小到 1024 像素的预览图；API Key 保存在钥匙串中。")
                .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
            Picker("接口", selection: Binding(get: { app.llmConfiguration.kind }, set: { kind in
                switch kind {
                case .anthropic: app.llmConfiguration = .anthropic
                case .openAICompatible:
                    let preset = LLMConfiguration.presets[0]
                    app.llmConfiguration = LLMConfiguration(kind: .openAICompatible, baseURL: preset.baseURL,
                                                            model: preset.model, acceptsImages: preset.acceptsImages)
                }
                loadKey()
            })) {
                ForEach(LLMConfiguration.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if app.llmConfiguration.kind == .openAICompatible {
                Menu("常用服务") {
                    ForEach(LLMConfiguration.presets) { preset in
                        Button(preset.name) {
                            app.llmConfiguration = LLMConfiguration(kind: .openAICompatible, baseURL: preset.baseURL,
                                                                    model: preset.model, acceptsImages: preset.acceptsImages)
                            loadKey()
                        }
                    }
                }
                .fixedSize()
            }
            field(L("服务地址"), text: $app.llmConfiguration.baseURL, prompt: "https://…")
            field(L("模型"), text: $app.llmConfiguration.model, prompt: L("模型名称，以服务商文档为准"))
            HStack(spacing: 10) {
                Text("API Key").frame(width: 72, alignment: .leading)
                SecureField(app.llmConfiguration.needsKey ? L("必填") : L("本机服务可不填"), text: $key)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { LLMKeychain.save(key, for: app.llmConfiguration) }
                Button("保存") { LLMKeychain.save(key, for: app.llmConfiguration) }
                    .controlSize(.small)
            }
            Toggle("模型可以识别图片", isOn: $app.llmConfiguration.acceptsImages)
                .toggleStyle(.checkbox)
                .help("描述照片需要能识别图片的模型；只能处理文字的模型仍可用于查找和修图")
            HStack(spacing: 10) {
                Button("测试连接") {
                    LLMKeychain.save(key, for: app.llmConfiguration)
                    app.testLLMConnection()
                }
                .disabled(app.llmTesting || !app.llmConfiguration.isComplete)
                if app.llmTesting { ProgressView().controlSize(.small) }
                if let result = app.llmTestResult {
                    Label(result.message, systemImage: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(result.ok ? Theme.accent : Theme.text2)
                        .font(.system(size: 12))
                        .lineLimit(2)
                }
            }
        }
        .onAppear { if !keyLoaded { loadKey() } }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        HStack(spacing: 10) {
            Text(label).frame(width: 72, alignment: .leading)
            TextField(prompt, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func loadKey() {
        key = app.llmKeyOverride ?? LLMKeychain.key(for: app.llmConfiguration) ?? ""
        keyLoaded = true
    }
}
