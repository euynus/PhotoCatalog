import Foundation

/// Crash reports are found for this app only, and only when they are new crashes.
enum DiagnosticsCheck {
    static func run() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pc-crash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let mark = Date(timeIntervalSinceNow: -60)
        func report(_ name: String, header: String, age: TimeInterval) {
            let url = folder.appendingPathComponent(name)
            try? Data((header + "\n{\"procPath\":\"/x\"}\n").utf8).write(to: url)
            try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)],
                                                   ofItemAtPath: url.path)
        }
        report("PhotoCatalog-new.ips", header: #"{"bug_type":"309","bundleID":"com.photocatalog.app"}"#, age: 5)
        report("PhotoCatalog-newer.ips", header: #"{"bug_type":"309","bundleID":"com.photocatalog.app"}"#, age: 1)
        report("PhotoCatalog-old.ips", header: #"{"bug_type":"309","bundleID":"com.photocatalog.app"}"#, age: 600)
        report("PhotoCatalog-cli.ips", header: #"{"bug_type":"309","app_name":"PhotoCatalog"}"#, age: 5)
        report("PhotoCatalog-hang.ips", header: #"{"bug_type":"298","bundleID":"com.photocatalog.app"}"#, age: 5)
        report("Other-app.ips", header: #"{"bug_type":"309","bundleID":"com.example.other"}"#, age: 5)
        report("PhotoCatalog-note.txt", header: #"{"bug_type":"309","bundleID":"com.photocatalog.app"}"#, age: 5)
        let found = CrashReports.find(bundleID: "com.photocatalog.app", since: mark, in: folder).map(\.lastPathComponent)
        assert(found == ["PhotoCatalog-newer.ips", "PhotoCatalog-new.ips"],
               "only this app's new crash reports are found, newest first")
        checkVersions()
        print("--- diagnostics assertions passed ---")
    }
}

extension DiagnosticsCheck {
    /// Release versions compare number by number, whatever their length or "v" prefix.
    static func checkVersions() {
        assert(UpdateChecker.isNewer("1.10", than: "1.9") && UpdateChecker.isNewer("2", than: "1.9.9")
               && UpdateChecker.isNewer("1.0.1", than: "1.0") && !UpdateChecker.isNewer("1.0", than: "1")
               && !UpdateChecker.isNewer("1.2", than: "1.10"), "release versions compare numerically")
        let release = UpdateChecker.Release(tagName: "v1.3", htmlURL: URL(string: "https://example.com")!)
        assert(release.version == "1.3", "a leading v is not part of the version")
    }
}
