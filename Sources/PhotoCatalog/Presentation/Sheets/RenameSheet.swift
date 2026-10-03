// ============================================================
//  Rename photos — Lightroom's Rename Photos dialog, with a preview
// ============================================================
import SwiftUI

/// Renames the selection's originals from a token template. The new names show before
/// anything moves; a RAW's paired JPEG takes the same name.
struct RenameSheet: View {
    @Environment(AppState.self) private var app
    /// The photos a rename reaches, one per file, in list order.
    let targets: [Asset]

    @State private var template: String
    @State private var start = 1
    /// The files already in the photos' folders, listed once: new names that another file
    /// has will get a _1 suffix.
    private let folders: RenameService.FolderNames

    private static let tokens: [(token: String, title: String)] = [
        ("{original}", L("原文件名")), ("{seq}", L("序号")), ("{date}", L("拍摄日期")), ("{time}", L("拍摄时间")),
        ("{camera}", L("相机")), ("{title}", L("标题")), ("{rating}", L("评分")),
    ]

    init(targets: [Asset], template: String) {
        self.targets = targets
        _template = State(initialValue: template)
        folders = RenameService.FolderNames(for: targets)
    }

    /// A plain prefix numbers the photos after it, as renaming does.
    private var effectiveTemplate: String {
        let trimmed = template.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("{") ? trimmed : "\(trimmed)_{seq}"
    }

    private var canConfirm: Bool {
        !template.trimmingCharacters(in: .whitespaces).isEmpty && !targets.isEmpty
    }

    var body: some View {
        let plan = RenameService.plan(targets, template: effectiveTemplate, start: start, folders: folders)
        VStack(spacing: 0) {
            HStack {
                Text("重命名照片").font(.system(size: 17, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Theme.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }

            VStack(alignment: .leading, spacing: 14) {
                Text("将重命名 \(targets.count) 张照片的磁盘原件，并更新目录库中的路径。RAW+JPEG 配对的 JPEG 一起改名，扩展名保持不变。")
                    .font(.system(size: 12)).foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("命名模板").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text2)
                    TextField("如 {date}_{seq}", text: $template)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                    FlowRow(spacing: 6) {
                        ForEach(Self.tokens, id: \.token) { token in
                            Button(token.title) { template += token.token }
                                .controlSize(.small)
                                .help(token.token)
                        }
                    }
                }
                HStack(spacing: 8) {
                    Text("起始序号").font(.system(size: 12)).foregroundStyle(Theme.text2)
                    TextField("起始序号", value: $start, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .labelsHidden()
                    Stepper("起始序号", value: $start, in: 0...999_999).labelsHidden()
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("预览").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text2)
                    ForEach(plan.names.prefix(6), id: \.id) { name in
                        HStack(spacing: 6) {
                            Text(name.from).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
                            Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(Theme.text3)
                            Text(name.to).lineLimit(1).truncationMode(.middle)
                        }
                        .font(.system(size: 12, design: .monospaced))
                    }
                    if plan.names.count > 6 {
                        Text("…还有 \(plan.names.count - 6) 张").font(.system(size: 11)).foregroundStyle(Theme.text3)
                    }
                    if plan.clashes > 0 {
                        Label("\(plan.clashes) 个新文件名重复，将依次加上 _1、_2 区分；可加入 {seq} 避免",
                              systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11)).foregroundStyle(Theme.text2)
                    }
                    if plan.taken > 0 {
                        Label("\(plan.taken) 个新文件名已被文件夹中的其他文件使用，将加上 _1、_2 区分",
                              systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11)).foregroundStyle(Theme.text2)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(18)

            HStack(spacing: 9) {
                Spacer()
                ghostButton(nil, L("取消")) { app.sheet = nil }
                Button(action: confirm) {
                    Text("重命名 \(targets.count) 张")
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
        .frame(width: 480)
        .font(.system(size: 13))
        .foregroundStyle(Theme.text)
        .background(Theme.bgPanel)
    }

    private func confirm() {
        guard canConfirm else { return }
        app.sheet = nil
        app.renameOriginals(template: template, start: start, targets: targets)
    }
}
