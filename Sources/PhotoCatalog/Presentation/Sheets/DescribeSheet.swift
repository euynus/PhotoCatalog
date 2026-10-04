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
                Text("\(targets.count) 张照片").foregroundStyle(Theme.text2).monospacedDigit()
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(Theme.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }

            VStack(alignment: .leading, spacing: 16) {
                DescriptionConsentFields(configuration: app.descriptionConfiguration,
                                         includeMetadata: $app.describeOptions.includeMetadata)
                Divider().overlay(Theme.line)
                VStack(alignment: .leading, spacing: 8) {
                    Text("生成内容").font(.system(size: 12, weight: .semibold))
                    HStack(spacing: 20) {
                        Toggle("关键词", isOn: $app.describeOptions.keywords)
                        Toggle("标题", isOn: $app.describeOptions.title)
                        Toggle("说明", isOn: $app.describeOptions.caption)
                    }
                    Toggle("替换已有的标题和说明", isOn: $app.describeOptions.replace)
                        .disabled(!app.describeOptions.title && !app.describeOptions.caption)
                }
                if let error = app.descriptionReviewContext?.configurationError {
                    HStack(alignment: .top, spacing: 8) {
                        Label(error.message, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12)).foregroundStyle(Theme.text2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("打开设置") {
                            app.invalidateDescriptionReview()
                            app.openSettings(category: "ai")
                        }
                        .controlSize(.small)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .padding(18)

            HStack(spacing: 9) {
                Spacer()
                Button("取消") { app.invalidateDescriptionReview() }
                    .keyboardShortcut(.cancelAction)
                Button("发送并生成", systemImage: "arrow.up") { app.describePhotos() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accentFill)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!app.canStartDescribingPhotos)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(Theme.bgSidebar)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        }
        .frame(width: 600)
        .font(.system(size: 13))
        .foregroundStyle(Theme.text)
        .background(Theme.bgPanel)
    }
}
