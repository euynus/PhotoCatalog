import SwiftUI

/// The library filter, in one row: rating, flag and color picked directly; camera and lens from
/// what the library holds, with how many photos each; type, date, GPS and file state under 更多.
struct FilterBar: View {
    @Environment(AppState.self) var app
    @State private var startDate = Date.now
    @State private var endDate = Date.now

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // one row when it fits; in a narrow window the menus move to a second
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    picks
                    separator
                    menus
                    Spacer(minLength: 0)
                    trailing
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        picks
                        Spacer(minLength: 0)
                        trailing
                    }
                    HStack(spacing: 12) { menus }
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
        .padding(.horizontal, 16).padding(.vertical, 8)
        .foregroundStyle(Theme.text)
        .background(Theme.bgSidebar)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line2).frame(height: 1) }
        .onAppear { syncDates() }
        .onChange(of: app.filters.dateStart) { syncDates() }
        .onChange(of: app.filters.dateEnd) { syncDates() }
        .onChange(of: startDate) {
            if startDate > endDate { endDate = startDate }
            applyDateRange()
        }
        .onChange(of: endDate) { applyDateRange() }
    }

    @ViewBuilder
    private var picks: some View {
        ratingControl
        separator
        flagControl
        separator
        colorControl
    }

    @ViewBuilder
    private var menus: some View {
        let filters = app.filters
        gearMenu(L("相机"), all: L("全部相机"), value: filters.camera, counts: app.gearCounts.cameras) {
            var filters = app.filters; filters.camera = $0; app.setFilters(filters)
        }
        gearMenu(L("镜头"), all: L("全部镜头"), value: filters.lens, counts: app.gearCounts.lenses) {
            var filters = app.filters; filters.lens = $0; app.setFilters(filters)
        }
        moreMenu
    }

    @ViewBuilder
    private var trailing: some View {
        let count = app.filters.activeCount
        if count > 0 {
            Text("\(count) 项条件")
                .font(.system(size: 11)).foregroundStyle(Theme.accent)
                .lineLimit(1).fixedSize()
        }
        ToolButton(icon: "refresh", label: L("清除筛选"), disabled: count == 0) { app.setFilters(Filters()) }
        ToolButton(icon: "close", label: L("收起筛选")) { app.toggleFilterBar() }
    }

    private var separator: some View {
        Rectangle().fill(Theme.line).frame(width: 1, height: 16)
    }

    private var ratingControl: some View {
        HStack(spacing: 0) {
            ForEach(1...5, id: \.self) { rating in
                Button {
                    var filters = app.filters
                    filters.minRating = filters.minRating == rating ? 0 : rating
                    app.setFilters(filters)
                } label: {
                    Image(systemName: app.filters.minRating >= rating ? "star.fill" : "star")
                        .font(.system(size: 12))
                        .foregroundStyle(app.filters.minRating >= rating ? Theme.rating : Theme.text3)
                        .frame(width: 18, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(rating) 星及以上")
                .accessibilityLabel("\(rating) 星及以上")
                .accessibilityAddTraits(app.filters.minRating == rating ? .isSelected : [])
            }
        }
        .fixedSize()
    }

    private var flagControl: some View {
        HStack(spacing: 2) {
            flagButton("pick", icon: "flag", selectedIcon: "flag.fill", tint: Theme.green, label: L("只看精选"))
            flagButton("reject", icon: "xmark.circle", selectedIcon: "xmark.circle.fill", tint: Theme.red,
                       label: L("只看被拒绝"))
        }
        .fixedSize()
    }

    private func flagButton(_ value: String, icon: String, selectedIcon: String, tint: Color, label: String) -> some View {
        let on = app.filters.flag == value
        return Button {
            var filters = app.filters; filters.flag = on ? "any" : value; app.setFilters(filters)
        } label: {
            Image(systemName: on ? selectedIcon : icon)
                .font(.system(size: 12))
                .foregroundStyle(on ? tint : Theme.text3)
                .frame(width: 24, height: 24)
                .background(on ? tint.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var colorControl: some View {
        HStack(spacing: 2) {
            ForEach(ColorLabel.allCases) { color in
                let on = app.filters.color == color.rawValue
                Button {
                    var filters = app.filters; filters.color = on ? "any" : color.rawValue; app.setFilters(filters)
                } label: {
                    Circle().fill(color.hex)
                        .frame(width: 11, height: 11)
                        .padding(3)
                        .overlay(Circle().strokeBorder(on ? Theme.accent : .clear, lineWidth: 1.5))
                        .frame(width: 20, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("颜色标签：\(color.name)"))
                .accessibilityLabel(L("颜色标签：\(color.name)"))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .fixedSize()
    }

    /// A camera or lens: the library's values, most used first. A value set elsewhere (a natural
    /// language search) that no photo matches exactly is listed too, so it can be seen and cleared.
    private func gearMenu(_ title: String, all: String, value: String, counts: [KeywordCount],
                          onSelect: @escaping (String) -> Void) -> some View {
        let current = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return Menu {
            Button { onSelect("") } label: { checked(all, current.isEmpty) }
            if !counts.isEmpty || !current.isEmpty { Divider() }
            if !current.isEmpty && !counts.contains(where: { $0.name == current }) {
                Button { onSelect(current) } label: { checked(current, true) }
            }
            ForEach(counts) { item in
                Button { onSelect(item.name) } label: { checked("\(item.name)  \(item.count)", current == item.name) }
            }
        } label: {
            Text(verbatim: current.isEmpty ? title : current)
        }
        .controlSize(.small)
        .fixedSize()
        .help(current.isEmpty ? all : current)
        .accessibilityLabel(title)
        .accessibilityValue(current.isEmpty ? all : current)
    }

    /// The less used filters, each a submenu; the button counts the ones set.
    private var moreMenu: some View {
        let filters = app.filters
        let active = [filters.type, filters.date, filters.gps, filters.status].filter { $0 != "any" }.count
        return Menu {
            optionMenu(L("文件类型"), value: filters.type,
                       options: [("any", L("全部类型")), ("RAW", "RAW"), ("HEIC", "HEIC"), ("VIDEO", L("视频"))]) {
                var filters = app.filters; filters.type = $0; app.setFilters(filters)
            }
            optionMenu(L("拍摄日期"), value: filters.date,
                       options: [("any", L("全部日期"))] + CaptureDates.presets + [("custom", L("自定义范围"))],
                       onSelect: setDateFilter)
            optionMenu("GPS", value: filters.gps,
                       options: [("any", L("不限")), ("yes", L("有位置")), ("no", L("无位置"))]) {
                var filters = app.filters; filters.gps = $0; app.setFilters(filters)
            }
            optionMenu(L("文件状态"), value: filters.status,
                       options: [("any", L("全部状态")), ("ready", L("正常")), ("missing", L("缺失")), ("offline", L("离线"))]) {
                var filters = app.filters; filters.status = $0; app.setFilters(filters)
            }
        } label: {
            Text(verbatim: active > 0 ? L("更多") + " · \(active)" : L("更多"))
        }
        .controlSize(.small)
        .fixedSize()
        .help("文件类型、拍摄日期、GPS 与文件状态")
        .accessibilityLabel("更多筛选条件")
    }

    /// One filter as a submenu whose title shows what it is set to.
    private func optionMenu(_ title: String, value: String, options: [(String, String)],
                            onSelect: @escaping (String) -> Void) -> some View {
        let selectedName = options.first { $0.0 == value }?.1 ?? value
        return Menu(value == "any" ? title : L("\(title)：\(selectedName)")) {
            ForEach(options, id: \.0) { option in
                Button { onSelect(option.0) } label: { checked(option.1, value == option.0) }
            }
        }
    }

    @ViewBuilder
    private func checked(_ title: String, _ on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(verbatim: title) }
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
