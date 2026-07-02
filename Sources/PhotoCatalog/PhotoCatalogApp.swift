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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
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
    @State private var app = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .frame(minWidth: 1080, minHeight: 680)
                .preferredColorScheme(.dark)
                .onAppear {
                    delegate.openCatalogURL = { url in
                        app.openCatalog(at: url)
                    }
                    app.openLaunchCatalogIfNeeded()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            PhotoCatalogCommands(app: app)
        }
    }
}
