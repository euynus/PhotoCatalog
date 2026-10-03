// ============================================================
//  AI describe dialog — titles, captions and keywords from the language model
// ============================================================
import SwiftUI

struct DescribeSheet: View {
    @Environment(AppState.self) private var app
    let targets: [Asset]

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            HStack {
                Text("AI 描述照片").font(.system(size: 17, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Theme.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }

            VStack(alignment: .leading, spacing: 12) {
                Text(L("让 AI 看 \(targets.count) 张照片的预览图（缩小到 1024 像素），写出下面选中的内容。关键词添加到已有的之中；可以撤销。"))
                    .font(.system(size: 12)).foregroundStyle(Theme.text3)
                    .help(serviceName)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("关键词", isOn: $app.describeOptions.keywords)
                Toggle("标题", isOn: $app.describeOptions.title)
                Toggle("说明", isOn: $app.describeOptions.caption)
                Toggle("替换已有的标题和说明", isOn: $app.describeOptions.replace)
                    .disabled(!app.describeOptions.title && !app.describeOptions.caption)
                    .padding(.leading, 20)
                if !app.isLLMReady || !app.llmConfiguration.acceptsImages {
                    HStack(spacing: 8) {
                        Label(app.llmConfiguration.acceptsImages ? L("还没有设置 AI 服务") : L("所选模型不能识别图片"),
                              systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12)).foregroundStyle(Theme.text2)
                        Button("打开设置") { app.openSettings(category: "ai") }.controlSize(.small)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .padding(18)

            HStack(spacing: 9) {
                Spacer()
                ghostButton(nil, L("取消")) { app.sheet = nil }
                Button {
                    app.sheet = nil
                    app.describePhotos()
                } label: {
                    Text("开始")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 17).padding(.vertical, 8)
                        .background(Theme.accentFill).clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(!canStart)
                .opacity(canStart ? 1 : 0.5)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Theme.bgSidebar)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        }
        .frame(width: 480)
        .font(.system(size: 13))
        .foregroundStyle(Theme.text)
        .background(Theme.bgPanel)
    }

    private var canStart: Bool { !app.describeOptions.isEmpty && app.isLLMReady && app.llmConfiguration.acceptsImages }

    private var serviceName: String {
        let model = app.llmConfiguration.model.trimmingCharacters(in: .whitespaces)
        return model.isEmpty ? app.llmConfiguration.kind.title : model
    }
}
