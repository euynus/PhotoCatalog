import SwiftUI

struct CaptureAnalysisView: View {
    @Environment(AppState.self) private var app
    @State private var selectedOnly = false

    var body: some View {
        let request = app.captureStatisticsRequest(selectedOnly: selectedOnly)
        let statistics = app.captureStatistics(for: request)
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 12) {
                        Label("拍摄参数分析", systemImage: "chart.bar.xaxis")
                            .font(.system(size: 17, weight: .semibold))
                        Spacer(minLength: 0)
                        Picker("分析范围", selection: $selectedOnly) {
                            Text("当前结果").tag(false)
                            Text("已选照片").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 208)
                    }

                    if app.isLoadingCatalog {
                        ProgressView(L("正在加载目录库…"))
                            .frame(maxWidth: .infinity, minHeight: 200)
                    } else if let statistics {
                        if statistics.totalCount == 0 {
                            ContentUnavailableView(selectedOnly ? "尚未选择照片" : "没有符合条件的照片",
                                                   systemImage: "chart.bar.xaxis")
                                .frame(maxWidth: .infinity, minHeight: 240)
                        } else {
                            summary(statistics, width: geometry.size.width)
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 28, alignment: .top),
                                                     count: max(1, min(3, Int(geometry.size.width / 400)))),
                                      alignment: .leading, spacing: 28) {
                                ForEach(statistics.distributions) { distribution in
                                    CaptureDistributionView(distribution: distribution, totalCount: statistics.totalCount)
                                }
                            }
                        }
                    } else {
                        ProgressView(L("正在分析拍摄参数…"))
                            .frame(maxWidth: .infinity, minHeight: 240)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .foregroundStyle(Theme.text)
        .background(Theme.bgContent)
        .task(id: request) { await app.loadCaptureStatistics(for: request) }
    }

    private func summary(_ statistics: CaptureStatistics, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading),
                                     count: max(1, min(4, Int(width / 200)))), alignment: .leading, spacing: 16) {
                metric(L("分析照片"), value: statistics.totalCount, color: Theme.accent)
                metric(L("拍摄天数"), value: statistics.dayCount, color: Theme.green)
                metric(L("参数齐全"), value: statistics.completeCount, color: Theme.text)
                    .help("相机、镜头、焦距、光圈、快门和 ISO 均有有效记录的照片数。")
                metric(L("文件日期回退"), value: statistics.fileDateCount, color: Theme.yellow)
                    .help("缺少拍摄日期，目录改用文件创建或修改日期的照片数。")
            }
            if let first = statistics.firstDate, let last = statistics.lastDate {
                Label("\(DateFmt.shortCapture(first)) 至 \(DateFmt.shortCapture(last))", systemImage: "calendar")
                    .font(.system(size: 12)).foregroundStyle(Theme.text2)
            }
        }
        .padding(.bottom, 20)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line2).frame(height: 1) }
    }

    private func metric(_ title: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.text2)
            Text(value, format: .number).font(.system(size: 22, weight: .semibold)).monospacedDigit()
                .foregroundStyle(color)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CaptureDistributionView: View {
    let distribution: CaptureDistribution
    let totalCount: Int
    @State private var expanded = false

    private var tint: Color {
        switch distribution.parameter {
        case .camera, .shutter: return Theme.accent
        case .lens, .focal: return Theme.green
        case .aperture, .iso: return Theme.yellow
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(distribution.parameter.title).font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 4)
                Text("已记录 \(distribution.knownCount) · 缺失 \(distribution.missingCount)")
                    .font(.system(size: 11)).foregroundStyle(Theme.text3)
            }
            .accessibilityAddTraits(.isHeader)

            if distribution.values.isEmpty {
                Text("没有可用的\(distribution.parameter.title)数据")
                    .font(.system(size: 13)).foregroundStyle(Theme.text3)
                    .frame(maxWidth: .infinity, minHeight: 126, alignment: .center)
            } else {
                ForEach(expanded ? distribution.values : Array(distribution.values.prefix(6))) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(distribution.parameter.label(for: item.value))
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(2)
                                .help(distribution.parameter.label(for: item.value))
                            Spacer(minLength: 0)
                            Text("\(item.count) 张 · \((Double(item.count) / Double(totalCount)).formatted(.percent.precision(.fractionLength(1))))")
                                .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.text2)
                                .fixedSize()
                        }
                        ProgressView(value: Double(item.count), total: Double(totalCount))
                            .tint(tint).accessibilityHidden(true)
                    }
                    .accessibilityElement(children: .combine)
                }
                if distribution.values.count > 6 {
                    Button {
                        expanded.toggle()
                    } label: {
                        Label(expanded ? "收起" : "全部 \(distribution.values.count) 项",
                              systemImage: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent)
                    .accessibilityLabel(expanded ? "\(distribution.parameter.title)：收起" : "\(distribution.parameter.title)：显示全部参数")
                }
            }
        }
        .padding(.top, 14)
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}
