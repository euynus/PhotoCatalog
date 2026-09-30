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
        checkUpdates()
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

    /// A release names the archive the release script publishes, and a newer version is only
    /// installed when it's the version it claims to be and carries the running app's signature.
    static func checkUpdates() {
        let json = #"{"tag_name":"v2.0","html_url":"https://github.com/x/y/releases/tag/v2.0","assets":[{"name":"notes.txt","browser_download_url":"https://example.com/notes.txt"},{"name":"PhotoCatalog-2.0.zip","browser_download_url":"https://example.com/PhotoCatalog-2.0.zip"}]}"#
        let release = try? JSONDecoder().decode(UpdateChecker.Release.self, from: Data(json.utf8))
        assert(release?.archive?.downloadURL.absoluteString == "https://example.com/PhotoCatalog-2.0.zip",
               "a release's archive is the app's zip")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pc-update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let identifier = "com.photocatalog.updatecheck"
        /// A minimal app bundle, signed ad hoc under `identifier`.
        func makeApp(_ url: URL, version: String) {
            let contents = url.appendingPathComponent("Contents")
            try? FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
            let info: NSDictionary = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version,
                                      "CFBundleExecutable": "PhotoCatalog", "CFBundlePackageType": "APPL"]
            info.write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
            try? FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: contents.appendingPathComponent("MacOS/PhotoCatalog").path)
            try? Data("resources".utf8).write(to: contents.appendingPathComponent("Resources/note.txt"))
            UpdateInstaller.run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", identifier, url.path])
        }
        func zip(_ app: URL, _ name: String) -> URL {
            let url = folder.appendingPathComponent(name)
            UpdateInstaller.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, url.path])
            return url
        }
        func prepare(_ archive: URL, version: String = "2.0", requirement: String) -> Result<URL, UpdateInstaller.Failure> {
            let semaphore = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var result: Result<URL, UpdateInstaller.Failure> = .failure(.download)
            Task.detached {
                do {
                    result = .success(try await UpdateInstaller.prepare(
                        archive: archive, version: version, identifier: identifier, requirement: requirement,
                        staging: folder.appendingPathComponent("staging-\(UUID().uuidString)")))
                } catch {
                    result = .failure(error as? UpdateInstaller.Failure ?? .download)
                }
                semaphore.signal()
            }
            semaphore.wait()
            return result
        }
        let requirement = "identifier \"\(identifier)\""
        let built = folder.appendingPathComponent("build/PhotoCatalog.app")
        makeApp(built, version: "2.0")
        let archive = zip(built, "PhotoCatalog-2.0.zip")
        let prepared = try? prepare(archive, requirement: requirement).get()
        assert(prepared != nil && UpdateInstaller.isSigned(built, satisfying: requirement),
               "a signed update of the right version is taken")
        assert(prepare(archive, version: "2.1", requirement: requirement) == .failure(.notTheApp),
               "an archive of another version is refused")
        assert(prepare(archive, requirement: "identifier \"com.example.other\"") == .failure(.untrusted),
               "an app signed as something else is refused")
        try? Data("altered".utf8).write(to: built.appendingPathComponent("Contents/Resources/note.txt"))
        assert(prepare(zip(built, "altered.zip"), requirement: requirement) == .failure(.untrusted),
               "an app altered after signing is refused")
        assert(UpdateInstaller.requirement(ofAppAt: built) == nil && UpdateInstaller.runningRequirement() == nil,
               "a copy signed ad hoc can't vouch for an update, so it offers the download page")

        // installing: the new version takes the old one's place
        let current = folder.appendingPathComponent("Applications/PhotoCatalog.app")
        makeApp(current, version: "1.0")
        if let prepared {
            assert(UpdateInstaller.canReplace(current) && (try? UpdateInstaller.install(prepared, replacing: current)) != nil,
                   "the update replaces the app")
            let installed = NSDictionary(contentsOf: current.appendingPathComponent("Contents/Info.plist"))
            assert(installed?["CFBundleShortVersionString"] as? String == "2.0", "the new version is where the old one was")
        }
    }
}
