// ============================================================
//  People — faces found on device, grouped for naming
// ============================================================
import SwiftUI
import ImageIO

struct PeopleView: View {
    @Environment(AppState.self) private var app
    @State private var detail: Detail?
    @State private var showSingles = false

    enum Detail: Equatable {
        case person(String)
        case cluster(String)
    }

    var body: some View {
        Group {
            if let detail {
                PeopleDetailView(detail: detail) { self.detail = $0 }
            } else {
                overview
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgContent)
    }

    private var overview: some View {
        let people = app.people
        let clusters = app.faceClusters
        let shown = showSingles ? clusters : clusters.filter { $0.faceIds.count > 1 }
        let singles = clusters.count - clusters.filter { $0.faceIds.count > 1 }.count
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                AnalysisBanner()
                if !people.isEmpty {
                    section("人物 · \(people.count)") {
                        ForEach(people) { person in
                            PersonTile(person: person) { detail = .person(person.name) }
                        }
                    }
                }
                if !shown.isEmpty {
                    section("未命名 · \(shown.count) 组") {
                        ForEach(shown) { cluster in
                            ClusterTile(cluster: cluster) { detail = .cluster(cluster.id) }
                        }
                    }
                }
                if singles > 0 {
                    Button(showSingles ? "隐藏只出现一次的人脸" : "显示 \(singles) 个只出现一次的人脸") {
                        showSingles.toggle()
                    }
                    .buttonStyle(.link)
                }
                if people.isEmpty && clusters.isEmpty && app.faceAnalysis == nil && app.faceScannedCount > 0 {
                    ContentUnavailableView("没有找到人脸", systemImage: "person.crop.rectangle")
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(20)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text2)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 16)], alignment: .leading, spacing: 18) {
                content()
            }
        }
    }
}

/// Analysis state: offer to start, show progress, or report what was covered.
private struct AnalysisBanner: View {
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.rectangle.stack").font(.system(size: 22)).foregroundStyle(Theme.accent)
            if let progress = app.faceAnalysis {
                VStack(alignment: .leading, spacing: 4) {
                    Text("正在分析人脸 \(progress.done.formatted()) / \(progress.total.formatted())")
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                        .tint(Theme.accent).frame(maxWidth: 320)
                }
                Spacer()
                Button("停止") { app.cancelFaceAnalysis() }
            } else if app.faceUnscannedCount > 0 {
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.faceScannedCount == 0 ? "找出照片中的人物" : "还有 \(app.faceUnscannedCount.formatted()) 张照片未分析")
                        .font(.system(size: 13, weight: .semibold))
                    Text("用 Vision 在本机识别人脸并按人分组，照片不会上传，原件不会改动。")
                        .font(.system(size: 12)).foregroundStyle(Theme.text3)
                }
                Spacer()
                Button("分析 \(app.faceUnscannedCount.formatted()) 张照片") { app.startFaceAnalysis() }
                    .buttonStyle(.borderedProminent)
            } else {
                Text("已分析 \(app.faceScannedCount.formatted()) 张照片 · 分组按相貌相似度给出，命名前请检查；确认后这个人的照片会带上“人物/名字”关键词。")
                    .font(.system(size: 12)).foregroundStyle(Theme.text3)
                Spacer()
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
    }
}

private struct PersonTile: View {
    @Environment(AppState.self) private var app
    let person: AppState.PersonSummary
    let open: () -> Void
    @State private var renaming = false

    var body: some View {
        VStack(spacing: 6) {
            FaceAvatar(faceId: person.coverFaceId, size: 96, circle: true)
                .overlay(alignment: .topTrailing) {
                    if person.unconfirmed > 0 {
                        Text("\(person.unconfirmed)")
                            .font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.accentFill, in: Capsule())
                            .help("\(person.unconfirmed) 张自动识别的人脸待确认")
                    }
                }
            Text(person.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Text("\(person.photoCount) 张").font(.system(size: 11)).foregroundStyle(Theme.text3)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .contextMenu {
            Button("显示照片") { app.showPhotos(of: person.name) }
            Button("重命名…") { renaming = true }
            Divider()
            Button("删除人物", role: .destructive) { app.deletePerson(person.name) }
        }
        .popover(isPresented: $renaming) {
            NamePopover(initial: person.name) { app.renamePerson(person.name, to: $0) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

private struct ClusterTile: View {
    @Environment(AppState.self) private var app
    let cluster: FaceCluster
    let open: () -> Void
    @State private var naming = false

    var body: some View {
        VStack(spacing: 6) {
            FaceAvatar(faceId: cluster.id, size: 96, circle: true)
                .onTapGesture(perform: open)
            Text("\(cluster.faceIds.count) 张人脸").font(.system(size: 11)).foregroundStyle(Theme.text3)
            Button("命名") { naming = true }
                .controlSize(.small)
                .popover(isPresented: $naming) {
                    NamePopover(initial: "") { app.nameFaces(cluster.faceIds, as: $0) }
                }
        }
        .frame(maxWidth: .infinity)
    }
}

/// A name field with the existing people as one-click choices (picking one merges).
struct NamePopover: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let initial: String
    let submit: (String) -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("名字", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(done)
            let matches = app.people.map(\.name).filter { name.isEmpty || $0.localizedStandardContains(name) }.prefix(8)
            if !matches.isEmpty {
                Text("已有的人物").font(.system(size: 11)).foregroundStyle(Theme.text3)
                ForEach(Array(matches), id: \.self) { existing in
                    Button(existing) {
                        name = existing
                        done()
                    }
                    .buttonStyle(.link)
                }
            }
            HStack {
                Spacer()
                Button("完成", action: done)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .frame(width: 240)
        .onAppear { name = initial }
    }

    private func done() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        submit(trimmed)
        dismiss()
    }
}

/// The faces of one person or one unnamed group.
private struct PeopleDetailView: View {
    @Environment(AppState.self) private var app
    let detail: PeopleView.Detail
    let navigate: (PeopleView.Detail?) -> Void
    @State private var naming = false
    /// Faces unticked before naming a group: groups are suggestions, so they get a review.
    @State private var excluded: Set<String> = []

    private var faceIds: [String] {
        _ = app.facesRevision
        switch detail {
        case .person(let name):
            return app.people.first { $0.name == name }?.faceIds
                .sorted { (app.face($0)?.quality ?? 0) > (app.face($1)?.quality ?? 0) } ?? []
        case .cluster(let id):
            return app.faceClusters.first { $0.id == id || $0.faceIds.contains(id) }?.faceIds ?? []
        }
    }

    var body: some View {
        let ids = faceIds
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { navigate(nil) } label: { Label("人物", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                Divider().frame(height: 16)
                Text(title).font(.system(size: 15, weight: .semibold))
                Text("\(ids.count) 张人脸").foregroundStyle(Theme.text3)
                Spacer()
                actions(ids)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Theme.bgTitlebar)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
            if ids.isEmpty {
                ContentUnavailableView("这里没有人脸了", systemImage: "person.crop.rectangle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                        ForEach(ids, id: \.self) { id in faceCell(id) }
                    }
                    .padding(16)
                }
            }
        }
    }

    private var title: String {
        switch detail {
        case .person(let name): name
        case .cluster: "未命名"
        }
    }

    @ViewBuilder
    private func actions(_ ids: [String]) -> some View {
        switch detail {
        case .person(let name):
            let unconfirmed = ids.filter { app.face($0)?.confirmed == false }.count
            if unconfirmed > 0 {
                Button("确认 \(unconfirmed) 张自动识别") { app.confirmFaces(of: name) }
            }
            Button("显示照片") { app.showPhotos(of: name) }
            Button("重命名…") { naming = true }
                .popover(isPresented: $naming) {
                    NamePopover(initial: name) { newName in
                        app.renamePerson(name, to: newName)
                        navigate(.person(FaceClustering.cleanName(newName)))
                    }
                }
        case .cluster:
            let chosen = ids.filter { !excluded.contains($0) }
            Text("取消勾选不是同一人的人脸").font(.system(size: 12)).foregroundStyle(Theme.text3)
            Button("命名 \(chosen.count) 张…") { naming = true }
                .buttonStyle(.borderedProminent)
                .disabled(chosen.isEmpty)
                .popover(isPresented: $naming) {
                    NamePopover(initial: "") { newName in
                        app.nameFaces(chosen, as: newName)
                        excluded = []
                        navigate(.person(FaceClustering.cleanName(newName)))
                    }
                }
        }
    }

    private func faceCell(_ id: String) -> some View {
        let face = app.face(id)
        let isCluster = if case .cluster = detail { true } else { false }
        let ticked = !excluded.contains(id)
        return FaceAvatar(faceId: id, size: 96, circle: false)
            .opacity(isCluster && !ticked ? 0.4 : 1)
            .overlay(alignment: .topLeading) {
                if isCluster {
                    Image(systemName: ticked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(ticked ? Color.white : Color.white.opacity(0.85), Theme.accentFill)
                        .shadow(radius: 1)
                        .padding(5)
                }
            }
            .overlay(alignment: .topTrailing) {
                if face?.person != nil && face?.confirmed == false {
                    Image(systemName: "questionmark.circle.fill")
                        .foregroundStyle(.white, Theme.accentFill)
                        .padding(4)
                        .help("自动识别，尚未确认")
                }
            }
            .onTapGesture(count: 2) { if let face { app.openLoupe(face.assetId) } }
            .onTapGesture {
                guard isCluster else { return }
                if ticked { excluded.insert(id) } else { excluded.remove(id) }
            }
            .contextMenu {
                if let face {
                    Button("打开照片") { app.openLoupe(face.assetId) }
                    if let person = face.person {
                        if !face.confirmed {
                            Button("确认是\(person)") { app.confirmFaces(of: person, ids: [id]) }
                        }
                        Button("不是此人") { app.removeFaceFromPerson(id) }
                    }
                }
            }
            .help(isCluster ? "点按勾选或取消 · 双击打开照片" : "双击打开照片")
    }
}

/// A face cut from its photo's cached preview.
struct FaceAvatar: View {
    @Environment(AppState.self) private var app
    let faceId: String
    let size: CGFloat
    let circle: Bool
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Theme.canvasSurface
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Image(systemName: "person.fill").font(.system(size: size * 0.35)).foregroundStyle(Theme.text4)
            }
        }
        .frame(width: size, height: size)
        .clipShape(circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 8, style: .continuous)))
        .task(id: faceId) {
            guard let face = app.face(faceId), let asset = app.asset(id: face.assetId) else { return }
            let hasPreview = !asset.preview.isEmpty && !asset.preview.hasPrefix("http")
                && FileManager.default.fileExists(atPath: asset.preview)
            let source = hasPreview ? asset.preview : (asset.localPath ?? "")
            // without a cached preview, a RAW's embedded JPEG is what the face was found in
            image = await FaceCropLoader.shared.crop(faceId: faceId, box: face.box, source: source,
                                                     embeddedPreview: !hasPreview && asset.isRaw)
        }
    }
}

@MainActor
final class FaceCropLoader {
    static let shared = FaceCropLoader()
    private let cache: NSCache<NSString, ImageBox> = {
        let cache = NSCache<NSString, ImageBox>()
        cache.countLimit = 2000
        return cache
    }()

    func crop(faceId: String, box: CGRect, source: String, embeddedPreview: Bool = false) async -> CGImage? {
        if let hit = cache.object(forKey: faceId as NSString) { return hit.image }
        guard !source.isEmpty else { return nil }
        let result = await ThumbnailRepairQueue.run(.visible) { () -> ImageBox? in
            let fromImage = embeddedPreview ? kCGImageSourceCreateThumbnailFromImageIfAbsent
                                            : kCGImageSourceCreateThumbnailFromImageAlways
            guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: source) as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                      fromImage: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: FaceService.analysisMaxPixel,
                  ] as CFDictionary) else { return nil }
            let width = CGFloat(image.width), height = CGFloat(image.height)
            let side = max(box.width * width, box.height * height) * 1.6
            let rect = CGRect(x: box.midX * width - side / 2, y: box.midY * height - side / 2, width: side, height: side)
                .intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
            return image.cropping(to: rect).map(ImageBox.init)
        } ?? nil
        if let result { cache.setObject(result, forKey: faceId as NSString) }
        return result?.image
    }
}
