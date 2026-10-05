import SwiftUI

struct DescriptionReviewSheet: View {
    @Binding var review: DescriptionReview
    /// The configuration used for this batch, not a later change in Settings.
    let configuration: LLMConfiguration
    var isRetrying = false
    let onApply: ([String: PhotoDescriber.Description]) -> Void
    let onClose: () -> Void
    let onDiscard: () -> Void
    let onRetry: ([String]) -> Void

    var body: some View {
        let successes = review.successfulItems
        let failures = review.failedItems
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("审阅 AI 描述").font(.system(size: 17, weight: .semibold))
                    Spacer()
                    if isRetrying {
                        ProgressView().controlSize(.small)
                        Text("正在生成").foregroundStyle(Theme.text2)
                    }
                }
                DescriptionDestinationFields(destination: PhotoDescriber.Destination(configuration: configuration))
                Label(review.options.includeMetadata
                      ? L("发送范围：预览图、拍摄日期、相机、位置和已有关键词")
                      : L("发送范围：仅预览图"), systemImage: "lock.shield")
                    .font(.system(size: 12)).foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .background(Theme.surface)

            Divider().overlay(Theme.line)
            HStack(spacing: 12) {
                Text("已选 \(review.selectedIDs.count) 张").monospacedDigit()
                Spacer()
                Button("全选可应用结果", systemImage: "checkmark.circle") { review.selectAll(true) }
                    .disabled(isRetrying || review.selectableIDs.isEmpty)
                Button("取消全选", systemImage: "minus.circle") { review.selectAll(false) }
                    .disabled(isRetrying || review.selectedIDs.isEmpty)
            }
            .controlSize(.small)
            .padding(.horizontal, 18).padding(.vertical, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(successes) { item in
                        DescriptionReviewItemRow(item: item, options: review.options, isSelected: selection(for: item.id))
                            .disabled(isRetrying)
                        Divider().overlay(Theme.line)
                    }
                    if !failures.isEmpty {
                        Label("未生成 \(failures.count) 张", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 6)
                        ForEach(failures) { item in
                            let message = item.failure ?? ""
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(verbatim: item.filename).fontWeight(.medium)
                                    Text(verbatim: message.isEmpty ? L("没有得到可用的描述") : message)
                                        .font(.system(size: 12)).foregroundStyle(Theme.text2)
                                        .textSelection(.enabled)
                                }
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Button("重试", systemImage: "arrow.clockwise") { onRetry([item.id]) }
                                    .labelStyle(.iconOnly)
                                    .help(L("重试此照片"))
                                    .accessibilityLabel(L("重试 \(item.filename)"))
                                    .disabled(isRetrying)
                            }
                            .padding(.horizontal, 18).padding(.vertical, 10)
                        }
                    }
                    if review.pendingCount > 0 {
                        Label("尚未生成 \(review.pendingCount) 张", systemImage: "clock")
                            .foregroundStyle(Theme.text2)
                            .padding(18)
                    }
                    if review.items.isEmpty {
                        Label("没有待审阅的结果", systemImage: "checkmark.circle")
                            .foregroundStyle(Theme.text2)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 10) {
                if !failures.isEmpty {
                    Button("重试失败项", systemImage: "arrow.clockwise", action: retryFailures)
                        .disabled(isRetrying)
                }
                Spacer()
                Button(action: onDiscard) {
                    Text(review.items.isEmpty ? L("完成") : L("放弃剩余结果"))
                }
                Button("稍后审阅", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("应用所选", systemImage: "checkmark", action: applySelected)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accentFill)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isRetrying || review.selectedIDs.isEmpty)
            }
            .sheetFooterBar(vertical: 12)
        }
        .frame(width: 760, height: 640)
        .font(.system(size: 13))
        .foregroundStyle(Theme.text)
        .background(Theme.bgPanel)
    }

    private func selection(for id: String) -> Binding<Bool> {
        Binding(get: { review.selectedIDs.contains(id) }, set: { review.setSelected($0, for: id) })
    }

    private func applySelected() {
        guard !isRetrying else { return }
        let selected = review.selectedDescriptions
        guard !selected.isEmpty else { return }
        onApply(selected)
    }

    private func retryFailures() {
        guard !isRetrying, !review.failedIDs.isEmpty else { return }
        onRetry(review.failedIDs)
    }
}

private struct DescriptionReviewItemRow: View {
    let item: DescriptionReview.Item
    let options: DescriptionReview.Options
    @Binding var isSelected: Bool

    var body: some View {
        let changes = item.changes(options: options)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                DescriptionReviewPreview(path: item.previewPath)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: item.filename)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                        .help(item.filename)
                    if changes == nil {
                        Text("无更改").font(.system(size: 12)).foregroundStyle(Theme.text3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("应用此照片", isOn: $isSelected)
                    .toggleStyle(.checkbox)
                    .disabled(changes == nil)
                    .accessibilityLabel(L("应用 \(item.filename) 的描述"))
            }
            if let proposed = item.proposed {
                HStack(alignment: .top, spacing: 12) {
                    Color.clear.frame(width: 72, height: 1).accessibilityHidden(true)
                    Text("当前").frame(maxWidth: .infinity, alignment: .leading)
                    Text("AI 建议").frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text3)
                DescriptionReviewValueRow(label: L("关键词"), existing: item.existing.keywords.joined(separator: ", "),
                                          proposed: proposed.keywords.joined(separator: ", "),
                                          changes: changes?.keywords.isEmpty == false, isAddition: true)
                DescriptionReviewValueRow(label: L("标题"), existing: item.existing.title, proposed: proposed.title,
                                          changes: changes?.title.isEmpty == false)
                DescriptionReviewValueRow(label: L("说明"), existing: item.existing.caption, proposed: proposed.caption,
                                          changes: changes?.caption.isEmpty == false)
            }
        }
        .padding(18)
    }
}

private struct DescriptionReviewValueRow: View {
    let label: String
    let existing: String
    let proposed: String
    let changes: Bool
    var isAddition = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(verbatim: label).foregroundStyle(Theme.text3).frame(width: 72, alignment: .leading)
            Text(verbatim: existing.isEmpty ? L("空") : existing)
                .foregroundStyle(Theme.text2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: proposed.isEmpty ? L("空") : proposed)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Label(changes ? (isAddition ? L("追加新关键词") : L("应用建议")) : L("保持不变"),
                      systemImage: changes ? "checkmark" : "minus")
                    .font(.system(size: 11)).foregroundStyle(Theme.text3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12))
    }
}

private struct DescriptionReviewPreview: View {
    let path: String?
    @StateObject private var loader = ThumbLoader()

    var body: some View {
        ZStack {
            Theme.canvasSurface
            if let image = loader.image {
                Color.clear.overlay {
                    Image(nsImage: image).resizable().scaledToFit()
                }
            } else {
                Image(systemName: "photo").foregroundStyle(Theme.canvasText3)
            }
        }
        .frame(width: 80, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityHidden(true)
        .task(id: path) { loader.load(path ?? "", maxPixel: 160) }
        .onDisappear { loader.cancelAndRelease() }
    }
}
