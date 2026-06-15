// ============================================================
//  Filter bar
// ============================================================
import SwiftUI

struct FilterBar: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        HStack(spacing: 14) {
            ratingGroup
            sep
            flagGroup
            sep
            colorGroup
            sep
            typeGroup
            if app.filters.activeCount > 0 {
                Spacer()
                Button {
                    app.setFilters(Filters())
                } label: {
                    Text("清除筛选").font(.system(size: 12)).foregroundStyle(Theme.accent)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: Theme.filterbarH)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "#232326"))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var label: some View { EmptyView() }
    private func label(_ t: String) -> some View {
        Text(t).font(.system(size: 11, weight: .semibold)).tracking(0.3)
            .foregroundStyle(Theme.text3).textCase(.uppercase)
    }
    private var sep: some View { Rectangle().fill(Theme.line2).frame(width: 1, height: 18) }

    private var ratingGroup: some View {
        HStack(spacing: 8) {
            label("评分")
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { n in
                    FBStar(on: app.filters.minRating >= n) {
                        var f = app.filters
                        f.minRating = (f.minRating == n) ? 0 : n
                        app.setFilters(f)
                    }
                }
                Text(app.filters.minRating > 0 ? "\(app.filters.minRating)★ 及以上" : "不限")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.text2)
                    .padding(.leading, 5)
            }
        }
    }

    private var flagGroup: some View {
        HStack(spacing: 8) {
            label("旗标")
            Segmented(
                options: [
                    SegOption(value: "any", label: "全部"),
                    SegOption(value: "pick", label: "精选"),
                    SegOption(value: "reject", label: "拒绝"),
                ],
                value: app.filters.flag,
                onChange: { v in var f = app.filters; f.flag = v; app.setFilters(f) },
                size: "sm")
        }
    }

    private var colorGroup: some View {
        HStack(spacing: 8) {
            label("颜色")
            HStack(spacing: 4) {
                Button {
                    var f = app.filters; f.color = "any"; app.setFilters(f)
                } label: {
                    Text("全部").font(.system(size: 11.5))
                        .foregroundStyle(app.filters.color == "any" ? Theme.text : Theme.text2)
                        .padding(.horizontal, 8).frame(height: 20)
                        .background(app.filters.color == "any" ? Theme.surfaceHi : .clear)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line2, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }.buttonStyle(.plain)

                ForEach(ColorLabel.allCases) { c in
                    let on = app.filters.color == c.rawValue
                    Button {
                        var f = app.filters; f.color = on ? "any" : c.rawValue; app.setFilters(f)
                    } label: {
                        Circle().fill(c.hex).frame(width: 11, height: 11)
                            .frame(width: 22, height: 20)
                            .background(on ? Color.white(0.06) : .clear)
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(on ? c.hex : .clear, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private struct FBStar: View {
        let on: Bool
        let action: () -> Void
        @State private var hover = false
        var body: some View {
            Button(action: action) {
                Image(systemName: on ? "star.fill" : "star")
                    .font(.system(size: 14))
                    .foregroundStyle(on ? Theme.accent : (hover ? Theme.accent2 : Theme.text4))
                    .padding(2)
            }.buttonStyle(.plain).onHover { hover = $0 }
        }
    }

    private var typeGroup: some View {
        HStack(spacing: 8) {
            label("类型")
            Segmented(
                options: [
                    SegOption(value: "any", label: "全部"),
                    SegOption(value: "RAW", label: "RAW"),
                    SegOption(value: "HEIC", label: "HEIC"),
                ],
                value: app.filters.type,
                onChange: { v in var f = app.filters; f.type = v; app.setFilters(f) },
                size: "sm")
        }
    }
}
