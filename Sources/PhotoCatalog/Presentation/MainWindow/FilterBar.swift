import SwiftUI

struct FilterBar: View {
    @Environment(AppState.self) var app
    @State private var cameraText = ""
    @State private var lensText = ""
    @State private var startDate = Date.now
    @State private var endDate = Date.now

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("筛选").font(.system(size: 12, weight: .semibold))
                if app.filters.activeCount > 0 {
                    Text("\(app.filters.activeCount) 项条件")
                        .font(.system(size: 11)).foregroundStyle(Theme.accent)
                }
                Spacer()
                ToolButton(icon: "refresh", label: L("清除筛选"),
                           disabled: app.filters.activeCount == 0 && cameraText.isEmpty && lensText.isEmpty) {
                    cameraText = ""
                    lensText = ""
                    app.setFilters(Filters())
                }
                ToolButton(icon: "close", label: L("收起筛选")) { app.toggleFilterBar() }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 12, alignment: .leading)],
                      alignment: .leading, spacing: 12) {
                field(L("最低评分")) { ratingControl }
                filterMenu(L("旗标"), value: app.filters.flag,
                           options: [("any", L("全部")), ("pick", L("精选", table: "Context")), ("reject", L("拒绝", table: "Context"))]) {
                    var filters = app.filters; filters.flag = $0; app.setFilters(filters)
                }
                field(L("颜色标签")) {
                    Menu {
                        Button("全部颜色") { setColor("any") }
                        ForEach(ColorLabel.allCases) { color in
                            Button { setColor(color.rawValue) } label: {
                                Label {
                                    Text(color.name)
                                } icon: {
                                    Image(systemName: "circle.fill").foregroundStyle(color.hex)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if let color = ColorLabel(rawValue: app.filters.color) {
                                Circle().fill(color.hex).frame(width: 9, height: 9)
                            }
                            menuTitle(ColorLabel(rawValue: app.filters.color)?.name ?? L("全部颜色"))
                        }
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .accessibilityLabel("颜色标签")
                    .accessibilityValue(ColorLabel(rawValue: app.filters.color)?.name ?? L("全部颜色"))
                }
                filterMenu(L("文件类型"), value: app.filters.type,
                           options: [("any", L("全部类型")), ("RAW", "RAW"), ("HEIC", "HEIC")]) {
                    var filters = app.filters; filters.type = $0; app.setFilters(filters)
                }
                field(L("相机")) { metadataField(L("全部相机"), label: L("相机"), text: $cameraText) }
                field(L("镜头")) { metadataField(L("全部镜头"), label: L("镜头"), text: $lensText) }
                filterMenu(L("拍摄日期"), value: app.filters.date,
                           options: [("any", L("全部日期"))] + CaptureDates.presets + [("custom", L("自定义范围"))],
                           onSelect: setDateFilter)
                filterMenu("GPS", value: app.filters.gps,
                           options: [("any", L("不限")), ("yes", L("有位置")), ("no", L("无位置"))]) {
                    var filters = app.filters; filters.gps = $0; app.setFilters(filters)
                }
                filterMenu(L("文件状态"), value: app.filters.status,
                           options: [("any", L("全部状态")), ("ready", L("正常")), ("missing", L("缺失")), ("offline", L("离线"))]) {
                    var filters = app.filters; filters.status = $0; app.setFilters(filters)
                }
            }
            if app.filters.date == "custom" {
                HStack(spacing: 16) {
                    DatePicker("起始日期", selection: $startDate, displayedComponents: .date)
                    DatePicker("结束日期", selection: $endDate, in: startDate..., displayedComponents: .date)
                    Spacer(minLength: 0)
                }
                .controlSize(.small)
                .environment(\.calendar, Calendar.captureWallClock)
                .environment(\.timeZone, TimeZone.captureWallClock)
                .help("包括起止两天；时间以目录记录的拍摄时间为准。")
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 14).padding(.top, 4)
        .foregroundStyle(Theme.text)
        .background(Theme.bgSidebar)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line2).frame(height: 1) }
        .onAppear {
            cameraText = app.filters.camera
            lensText = app.filters.lens
            syncDates()
        }
        .onChange(of: app.filters.dateStart) { syncDates() }
        .onChange(of: app.filters.dateEnd) { syncDates() }
        .onChange(of: startDate) {
            if startDate > endDate { endDate = startDate }
            applyDateRange()
        }
        .onChange(of: endDate) { applyDateRange() }
        .onChange(of: app.filters.camera) { if app.filters.camera != cameraText { cameraText = app.filters.camera } }
        .onChange(of: app.filters.lens) { if app.filters.lens != lensText { lensText = app.filters.lens } }
        .task(id: cameraText) {
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard cameraText != app.filters.camera else { return }
            var filters = app.filters; filters.camera = cameraText; app.setFilters(filters)
        }
        .task(id: lensText) {
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard lensText != app.filters.lens else { return }
            var filters = app.filters; filters.lens = lensText; app.setFilters(filters)
        }
    }

    private var ratingControl: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { rating in
                Button {
                    var filters = app.filters
                    filters.minRating = filters.minRating == rating ? 0 : rating
                    app.setFilters(filters)
                } label: {
                    Image(systemName: app.filters.minRating >= rating ? "star.fill" : "star")
                        .font(.system(size: 13))
                        .foregroundStyle(app.filters.minRating >= rating ? Theme.rating : Theme.text3)
                        .frame(width: 20, height: 28)
                }
                .buttonStyle(.plain)
                .help("\(rating) 星及以上")
                .accessibilityLabel("\(rating) 星及以上")
                .accessibilityAddTraits(app.filters.minRating == rating ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.text2)
            content()
                .padding(.horizontal, 8)
                .frame(height: 28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line, lineWidth: 1))
        }
    }

    private func filterMenu(_ title: String, value: String, options: [(String, String)],
                            onSelect: @escaping (String) -> Void) -> some View {
        field(title) {
            Menu {
                ForEach(options, id: \.0) { option in
                    Button { onSelect(option.0) } label: {
                        if value == option.0 {
                            Label(option.1, systemImage: "checkmark")
                        } else {
                            Text(option.1)
                        }
                    }
                }
            } label: {
                menuTitle(options.first { $0.0 == value }?.1 ?? value)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .accessibilityLabel(title)
            .accessibilityValue(options.first { $0.0 == value }?.1 ?? value)
        }
    }

    private func menuTitle(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 2)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.text3)
        }
        .foregroundStyle(Theme.text)
    }

    private func metadataField(_ placeholder: String, label: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain).font(.system(size: 12))
            .accessibilityLabel(label)
    }

    private func setColor(_ color: String) {
        var filters = app.filters; filters.color = color; app.setFilters(filters)
    }

    private func setDateFilter(_ value: String) {
        var filters = app.filters
        filters.date = value
        if value == "custom" {
            filters.dateStart = filters.dateStart ?? Calendar.captureWallClock.startOfDay(for: app.primary?.date ?? .now)
            filters.dateEnd = filters.dateEnd ?? filters.dateStart
        }
        app.setFilters(filters)
    }

    private func syncDates() {
        startDate = app.filters.dateStart ?? Calendar.captureWallClock.startOfDay(for: app.primary?.date ?? .now)
        endDate = app.filters.dateEnd ?? startDate
    }

    private func applyDateRange() {
        guard app.filters.date == "custom" else { return }
        var filters = app.filters
        filters.dateStart = startDate
        filters.dateEnd = endDate
        if filters != app.filters { app.setFilters(filters) }
    }
}
