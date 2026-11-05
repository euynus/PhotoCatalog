import XCTest
@testable import PhotoCatalog

/// Check for Updates: what a release feed may point the app at, and the relaunch after installing.
final class UpdateTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pc-update-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        unsetenv("PC_UPDATE_FEED")
        if let root { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    /// The release a feed at `root/feed.json` describes, read through `check`.
    private func check(htmlURL: String, downloadURL: String) async throws -> UpdateChecker.Outcome {
        let feed = root.appendingPathComponent("feed.json")
        let json = """
        {"tag_name":"v99.0","html_url":"\(htmlURL)",
         "assets":[{"name":"PhotoCatalog-99.0.zip","browser_download_url":"\(downloadURL)"}]}
        """
        try Data(json.utf8).write(to: feed)
        setenv("PC_UPDATE_FEED", feed.absoluteString, 1)
        return await UpdateChecker.check(currentVersion: "1.0")
    }

    func testReleasePageMustBeHTTPS() async throws {
        let outcome = try await check(htmlURL: "file:///System/Applications/Calculator.app",
                                      downloadURL: "https://example.com/PhotoCatalog-99.0.zip")
        XCTAssertEqual(outcome, .unavailable, "a release page the app would open that isn't a web page")
    }

    func testArchiveOverPlainHTTPIsNotInstalled() async throws {
        let outcome = try await check(htmlURL: "https://github.com/euynus/PhotoCatalog/releases/tag/v99.0",
                                      downloadURL: "http://example.com/PhotoCatalog-99.0.zip")
        guard case .newer(let release) = outcome else { return XCTFail("the release wasn't offered: \(outcome)") }
        XCTAssertNil(release.archive, "an archive fetched over plain HTTP is offered for installing")
    }

    func testArchiveBesideAFileFeedIsInstalled() async throws {
        let archive = root.appendingPathComponent("PhotoCatalog-99.0.zip").absoluteString
        let outcome = try await check(htmlURL: "https://github.com/euynus/PhotoCatalog/releases/tag/v99.0",
                                      downloadURL: archive)
        guard case .newer(let release) = outcome else { return XCTFail("the release wasn't offered: \(outcome)") }
        XCTAssertEqual(release.archive?.downloadURL.absoluteString, archive, "a feed tried from disk names its archive there")
    }

    /// The relaunch waits for this process to quit, but not for ever: a copy that hangs on its
    /// way out leaves no shell behind waiting on it.
    func testRelaunchStopsWaitingForAProcessThatDoesNotQuit() throws {
        let waiting = try XCTUnwrap(UpdateInstaller.relaunch(root.appendingPathComponent("Missing.app"),
                                                             after: ProcessInfo.processInfo.processIdentifier,
                                                             waitingAtMost: 1))
        let deadline = Date().addingTimeInterval(10)
        while waiting.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertFalse(waiting.isRunning, "the relaunch is still waiting for a process that never quits")
        if waiting.isRunning { waiting.terminate() }
    }
}
