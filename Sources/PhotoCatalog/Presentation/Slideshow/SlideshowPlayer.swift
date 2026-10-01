// ============================================================
//  Slideshow player — the photos full screen, fading one into the next
// ============================================================
import AppKit
import AVFoundation
import ImageIO
import SwiftUI

/// A borderless window over the whole screen. It takes its own keys: Esc ends the show,
/// Space pauses, the arrows go back or on a photo.
final class SlideshowWindow: NSWindow {
    var onKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
}

/// Plays a slideshow: the photos as Develop shows them, with the music.
@MainActor
final class SlideshowPlayer {
    private let app: AppState
    let model: SlideshowModel
    private var window: SlideshowWindow?
    private var presentation: NSApplication.PresentationOptions = []

    init(app: AppState, assets: [Asset], settings: SlideshowSettings, slideSeconds: Double) {
        self.app = app
        model = SlideshowModel(assets: assets, settings: settings, slideSeconds: slideSeconds)
    }

    func show() {
        guard let screen = NSApp.keyWindow?.screen ?? NSScreen.main else { return }
        let window = SlideshowWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = NSColor(white: model.settings.backdrop.gray, alpha: 1)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        window.onKey = { [weak self] event in self?.key(event) ?? false }
        window.contentView = NSHostingView(rootView: SlideshowView(model: model) { [weak self] in self?.close() }
            .environment(app))
        presentation = NSApp.presentationOptions
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = window
        model.start()
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    func close() {
        guard let window else { return }
        model.stop()
        NSApp.presentationOptions = presentation
        window.orderOut(nil)
        self.window = nil
        app.slideshowEnded()
    }

    private func key(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: close()                  // Esc
        case 49: model.togglePause()      // Space
        case 123: model.step(-1)          // ←
        case 124: model.step(1)           // →
        default: return false
        }
        model.showControls()
        return true
    }
}

/// The show's clock, its photos as they load, and its music.
@MainActor @Observable
final class SlideshowModel {
    let assets: [Asset]
    let settings: SlideshowSettings
    let timeline: SlideshowTimeline
    private(set) var images: [Int: CGImage] = [:]
    private(set) var paused = false
    /// The controls show until this moment.
    private(set) var controlsUntil = Date.distantPast
    @ObservationIgnored private var started = Date()
    @ObservationIgnored private var pausedAt: Date?
    @ObservationIgnored private var music: AVAudioPlayer?
    @ObservationIgnored private var loading: Set<Int> = []

    init(assets: [Asset], settings: SlideshowSettings, slideSeconds: Double) {
        self.assets = assets
        self.settings = settings
        timeline = SlideshowTimeline(count: assets.count, slide: slideSeconds, fade: settings.fadeSeconds, repeats: settings.repeats)
    }

    func start() {
        started = Date()
        if !settings.musicPath.isEmpty, let player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: settings.musicPath)) {
            player.numberOfLoops = settings.repeats ? -1 : 0
            player.play()
            music = player
        }
    }

    func stop() {
        music?.stop()
        music = nil
    }

    func time(at date: Date) -> Double { (pausedAt ?? date).timeIntervalSince(started) }

    func togglePause() {
        let now = Date()
        if let pausedAt {
            started += now.timeIntervalSince(pausedAt)
            self.pausedAt = nil
            paused = false
            music?.play()
        } else {
            pausedAt = now
            paused = true
            music?.pause()
        }
    }

    /// To the start of the photo `delta` away (round the ends when the show repeats).
    func step(_ delta: Int) {
        let now = Date()
        let current = timeline.frame(at: time(at: now)).index
        var target = current + delta
        if settings.repeats { target = (target % assets.count + assets.count) % assets.count }
        target = min(max(0, target), assets.count - 1)
        let offset = Double(target) * timeline.slide + 0.001
        started = (pausedAt ?? now).addingTimeInterval(-offset)
    }

    func showControls() { controlsUntil = Date().addingTimeInterval(2) }

    /// Loads the photos showing and coming up, and lets go of the ones gone by.
    func prefetch(around index: Int, app: AppState) async {
        let wanted = Set([index, (index + 1) % max(assets.count, 1), (index + 2) % max(assets.count, 1)])
        images = images.filter { wanted.contains($0.key) || $0.key == (index - 1 + assets.count) % assets.count }
        for position in [index, (index + 1) % assets.count, (index + 2) % assets.count]
        where images[position] == nil && !loading.contains(position) {
            loading.insert(position)
            let asset = assets[position]
            let source = await app.visibleImageSource(for: asset, requestedSource: asset.preview, kind: .preview2048)
            let image = await Task.detached(priority: .userInitiated) { Self.load(source) }.value
            loading.remove(position)
            if let image { images[position] = image }
        }
    }

    private nonisolated static func load(_ source: String) -> CGImage? {
        let url = source.hasPrefix("http") ? URL(string: source) : URL(fileURLWithPath: source)
        guard let url, let image = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(image, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    func caption(_ index: Int) -> String { SlideshowModel.caption(assets[index], settings.caption) }

    static func caption(_ asset: Asset, _ caption: SlideshowSettings.Caption) -> String {
        switch caption {
        case .none: ""
        case .title: asset.title
        case .filename: asset.filename
        case .caption: asset.caption
        }
    }
}

struct SlideshowView: View {
    @Environment(AppState.self) private var app
    let model: SlideshowModel
    let close: () -> Void

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: model.paused)) { context in
            let frame = model.timeline.frame(at: model.time(at: context.date))
            GeometryReader { proxy in
                ZStack {
                    Color(white: model.settings.backdrop.gray)
                    slide(frame.index, progress: frame.progress, alpha: 1, captionAlpha: frame.captionAlpha, size: proxy.size)
                    if let next = frame.next {
                        slide(next, progress: 0, alpha: frame.blend, captionAlpha: frame.nextCaptionAlpha, size: proxy.size)
                    }
                    if context.date < model.controlsUntil || model.paused { controls(frame.index, height: proxy.size.height) }
                }
            }
            .task(id: frame.index) { await model.prefetch(around: frame.index, app: app) }
            .onChange(of: frame.finished) { if frame.finished { close() } }
        }
        .ignoresSafeArea()
        .onContinuousHover { phase in if case .active = phase { model.showControls() } }
    }

    @ViewBuilder
    private func slide(_ index: Int, progress: Double, alpha: Double, captionAlpha: Double, size: CGSize) -> some View {
        if let image = model.images[index] {
            let motion = model.settings.panAndZoom
                ? SlideshowTimeline.panAndZoom(index: index, progress: progress) : (scale: 1, offset: .zero)
            let rect = SlideshowLayout.rect(imageSize: CGSize(width: image.width, height: image.height), in: size,
                                            scale: motion.scale, offset: motion.offset)
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .opacity(alpha)
            let caption = model.caption(index)
            if !caption.isEmpty {
                Text(caption)
                    .font(.system(size: size.height * 0.03))
                    .foregroundStyle(Color(white: model.settings.backdrop.captionGray))
                    .shadow(color: model.settings.backdrop == .white ? .white : .black, radius: size.height * 0.008)
                    .position(x: size.width / 2, y: size.height * 0.95)
                    .opacity(captionAlpha)
            }
        }
    }

    /// Above the caption, so neither hides the other.
    private func controls(_ index: Int, height: CGFloat) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 18) {
                Button { model.step(-1); model.showControls() } label: { Image(systemName: "backward.fill") }
                Button { model.togglePause(); model.showControls() } label: {
                    Image(systemName: model.paused ? "play.fill" : "pause.fill")
                }
                Button { model.step(1); model.showControls() } label: { Image(systemName: "forward.fill") }
                Text("\(index + 1) / \(model.assets.count)").monospacedDigit()
                Button { close() } label: { Image(systemName: "xmark") }
                    .help("结束放映 (Esc)")
            }
            .buttonStyle(.plain)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(.bottom, height * 0.12)
        }
    }
}
