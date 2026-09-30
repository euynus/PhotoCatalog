// ============================================================
//  PhotoCatalog Mac — application entry point
// ============================================================
import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var openCatalogURL: ((URL) -> Void)? {
        didSet { flushPendingCatalogURLs() }
    }
    private var pendingCatalogURLs: [URL] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        // before the first window draws, so a saved light/dark choice doesn't flash
        AppAppearance.stored.apply()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // decoded photos are drawn for the screen the window is on (see DisplayBitmap)
        DisplayBitmap.use(NSScreen.main)
        for name in [NSApplication.didChangeScreenParametersNotification, NSWindow.didChangeScreenNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { DisplayBitmap.use(NSApp.mainWindow?.screen ?? NSScreen.main) }
            }
        }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        receiveCatalogURL(URL(fileURLWithPath: filename))
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { receiveCatalogURL(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    private func receiveCatalogURL(_ url: URL) {
        guard url.pathExtension == "photolibrary" else { return }
        if let openCatalogURL {
            openCatalogURL(url)
        } else {
            pendingCatalogURLs.append(url)
        }
    }

    private func flushPendingCatalogURLs() {
        guard let openCatalogURL else { return }
        let urls = pendingCatalogURLs
        pendingCatalogURLs = []
        for url in urls { openCatalogURL(url) }
    }
}

struct PhotoCatalogApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppState(deferCatalogLoading: true)

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .frame(minWidth: 1080, minHeight: 680)
                .onAppear {
                    app.startDeferredCatalogLoadingIfNeeded()
                    app.startDeviceBrowsing()
                    app.checkForCrashReport()
                    app.checkForUpdatesAutomatically()
                    delegate.openCatalogURL = { url in
                        app.openCatalogFromSystem(url)
                    }
                }
        }
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified)
        .commands {
            PhotoCatalogCommands(app: app)
        }
    }
}
