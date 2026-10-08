// ============================================================
//  FileAccessService — security-scoped bookmarks (PRD §12.1)
//  What the Mac App Store build's sandbox requires; harmless outside it.
// ============================================================
import AppKit
import Foundation

extension NSOpenPanel {
    /// Asks for one folder, which may be made in the panel; nil when cancelled.
    @MainActor static func chooseFolder(prompt: String? = nil, message: String? = nil, start: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if let prompt { panel.prompt = prompt }
        if let message { panel.message = message }
        if let start { panel.directoryURL = start }
        return panel.runModal() == .OK ? panel.url : nil
    }
}

enum FileAccessService {
    static func createBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [.withSecurityScope],
                              includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func resolveBookmark(_ data: Data) -> (url: URL, isStale: Bool)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        return (url, stale)
    }

    /// Whether this copy runs in the App Sandbox (the Mac App Store build).
    static let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    /// Whether the app may read what's at `path`. A sandboxed copy still sees files and folders
    /// it isn't allowed to open; outside the sandbox this is just whether it's there.
    static func canRead(_ path: String) -> Bool {
        isSandboxed ? FileManager.default.isReadableFile(atPath: path) : FileManager.default.fileExists(atPath: path)
    }

    /// The user's Pictures folder. A sandboxed copy is given its container's link to it, a path
    /// that mustn't end up in the catalog or the settings.
    static var picturesFolder: URL {
        (FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures"))
            .resolvingSymlinksInPath()
    }

    // ---- places the user chose, reopened in later launches ----
    // Photo folders keep their bookmarks in the catalog, as source roots. Everything else the
    // user picks and the app goes back to is remembered here, most recent first: catalogs and the
    // folders the app writes to (exports, card copies, tethered sessions), reached by path when
    // used, and the places originals were relocated or moved to, reached all together when a
    // catalog opens.

    enum Purpose: String, Codable {
        case place, originals
    }

    private struct Remembered: Codable {
        var path: String
        var purpose: Purpose
        var bookmark: Data
    }

    private static let rememberedKey = "pc_rememberedLocations"
    private static let rememberedLimit = 64
    @MainActor private static var reached: Set<String> = []

    private static var remembered: [Remembered] {
        get {
            UserDefaults.standard.data(forKey: rememberedKey)
                .flatMap { try? JSONDecoder().decode([Remembered].self, from: $0) } ?? []
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: rememberedKey) }
    }

    /// Remembers access to `url`, which the user just chose (or the app can reach anyway).
    @MainActor static func remember(_ url: URL, for purpose: Purpose = .place) {
        let path = url.standardizedFileURL.path
        guard let bookmark = createBookmark(for: url) else { return }
        var all = remembered.filter { $0.path != path }
        all.insert(Remembered(path: path, purpose: purpose, bookmark: bookmark), at: 0)
        remembered = Array(all.prefix(rememberedLimit))
        reached.insert(path)
    }

    /// Opens access to a place remembered earlier, for the rest of this launch. Does nothing when
    /// there's nothing to open, and nothing is needed outside the sandbox.
    @MainActor static func reach(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard !reached.contains(path), let entry = remembered.first(where: { $0.path == path }) else { return }
        open(entry)
    }

    /// Opens access to every place originals were relocated or moved to.
    @MainActor static func reachOriginals() {
        for entry in remembered where entry.purpose == .originals && !reached.contains(entry.path) {
            open(entry)
        }
    }

    /// Forgets a place, e.g. a catalog dropped from the recents.
    @MainActor static func forget(_ url: URL) {
        let path = url.standardizedFileURL.path
        remembered.removeAll { $0.path == path }
    }

    @MainActor private static func open(_ entry: Remembered) {
        guard let resolved = resolveBookmark(entry.bookmark),
              resolved.url.standardizedFileURL.path == entry.path,
              resolved.url.startAccessingSecurityScopedResource() else { return }
        reached.insert(entry.path)
        // a stale bookmark still opens the place; one made now replaces it
        if resolved.isStale { remember(resolved.url, for: entry.purpose) }
    }
}
