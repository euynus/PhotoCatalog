import SwiftUI

/// Embedded by the consent sheet; this control neither persists consent nor starts a request.
struct DescriptionConsentFields: View {
    let configuration: LLMConfiguration
    @Binding var includeMetadata: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DescriptionDestinationFields(destination: PhotoDescriber.Destination(configuration: configuration))

            VStack(alignment: .leading, spacing: 6) {
                Label("发送内容", systemImage: "arrow.up.doc")
                    .font(.system(size: 12, weight: .semibold))
                Text("照片预览图（最长边 1024 像素，不发送原文件）")
                    .font(.system(size: 12)).foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("同时发送拍摄日期、相机、位置和已有关键词", isOn: $includeMetadata)
                    .toggleStyle(.checkbox)
                    .fixedSize(horizontal: false, vertical: true)
                if includeMetadata {
                    Label("位置可能包含 GPS 坐标；只发送目录库中已有的这些字段。", systemImage: "location")
                        .font(.system(size: 12)).foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("不附加目录库中的拍摄日期、相机、位置和已有关键词。")
                        .font(.system(size: 12)).foregroundStyle(Theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .foregroundStyle(Theme.text)
    }
}

struct DescriptionDestinationFields: View {
    let destination: PhotoDescriber.Destination

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("服务").foregroundStyle(Theme.text3)
                Text(verbatim: destination.provider)
            }
            GridRow {
                Text("连接类型").foregroundStyle(Theme.text3)
                if destination.endpoint == nil {
                    Text("未设置")
                } else {
                    Label(destination.isLoopback ? L("本机服务") : L("网络服务"),
                          systemImage: destination.isLoopback ? "desktopcomputer" : "network")
                }
            }
            GridRow {
                Text("模型").foregroundStyle(Theme.text3)
                Text(verbatim: destination.model.isEmpty ? L("未设置") : destination.model)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            GridRow(alignment: .top) {
                Text("服务地址").foregroundStyle(Theme.text3)
                Text(verbatim: destination.endpoint ?? L("未设置"))
                    .font(Theme.mono)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
