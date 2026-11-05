// ============================================================
//  Update installer — a newer release swapped in for the running app
// ============================================================
import Foundation
import Security

/// Installs a newer release in place of the running app: downloads its archive, unpacks it,
/// and takes it only when it carries this app's own signature — its designated requirement, for
/// a Developer ID app the same identifier signed by the same team — then swaps it in and opens
/// it once this process has quit.
enum UpdateInstaller {
    enum Failure: Error, Equatable {
        case download
        case unpack
        /// The archive holds no app with this identifier and version.
        case notTheApp
        /// Signed by someone else, or altered after signing.
        case untrusted
        case replace
    }

    /// What a new version has to satisfy: this app's designated requirement, as text. Nil when
    /// the app is signed ad hoc — its requirement is its own hash, which no other build can meet,
    /// so updates go through the download page instead.
    static func runningRequirement() -> String? {
        #if DEBUG
        // lets a debug build go through the whole update before a Developer ID signature exists
        if let override = ProcessInfo.processInfo.environment["PC_UPDATE_REQUIREMENT"] { return override }
        #endif
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return requirement(of: staticCode)
    }

    /// The designated requirement of the app at `url`, as text; nil when it's unsigned or signed ad hoc.
    static func requirement(ofAppAt url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        return requirement(of: code)
    }

    private static func requirement(of code: SecStaticCode) -> String? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any] else { return nil }
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        guard info[kSecCodeInfoCertificates as String] != nil, flags & SecCodeSignatureFlags.adhoc.rawValue == 0 else {
            return nil
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess else { return nil }
        return text as String?
    }

    /// Whether the app at `url` can be replaced: its folder and the app itself are writable.
    static func canReplace(_ url: URL) -> Bool {
        let files = FileManager.default
        return url.pathExtension == "app" && files.isWritableFile(atPath: url.deletingLastPathComponent().path)
            && files.isWritableFile(atPath: url.path)
    }

    /// Downloads `archive` (a zip, https or file URL) into `staging`, unpacks it and checks the
    /// app inside: `identifier`, `version`, and a valid signature meeting `requirement`. The
    /// checked app, still in `staging`.
    static func prepare(archive: URL, version: String, identifier: String, requirement: String,
                        staging: URL) async throws -> URL {
        let files = FileManager.default
        try? files.removeItem(at: staging)
        try? files.createDirectory(at: staging, withIntermediateDirectories: true)
        let zip = staging.appendingPathComponent("update.zip")
        if archive.isFileURL {
            do { try files.copyItem(at: archive, to: zip) } catch { throw Failure.download }
        } else {
            guard let (file, response) = try? await URLSession.shared.download(from: archive),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  (try? files.moveItem(at: file, to: zip)) != nil else { throw Failure.download }
        }
        let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]) else { throw Failure.unpack }
        guard let app = (try? files.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil))?
                  .first(where: { $0.pathExtension == "app" }) else { throw Failure.notTheApp }
        // nothing the app says of itself is read before its signature holds: then its
        // Info.plist is the one sealed in it
        guard let info = signedInfo(app, satisfying: requirement) else { throw Failure.untrusted }
        guard info["CFBundleIdentifier"] as? String == identifier,
              info["CFBundleShortVersionString"] as? String == version else { throw Failure.notTheApp }
        return app
    }

    /// The app's signature is intact — every file as signed — and meets `requirement`.
    static func isSigned(_ app: URL, satisfying requirement: String) -> Bool {
        signedInfo(app, satisfying: requirement) != nil
    }

    /// The Info.plist the app's signature seals, once the signature is found intact and meeting
    /// `requirement`; nil otherwise.
    private static func signedInfo(_ app: URL, satisfying requirement: String) -> [String: Any]? {
        var code: SecStaticCode?, parsed: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess, let parsed else {
            return nil
        }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode))
        var information: CFDictionary?
        guard SecStaticCodeCheckValidity(code, flags, parsed) == errSecSuccess,
              SecCodeCopySigningInformation(code, [], &information) == errSecSuccess,
              let info = information as? [String: Any] else { return nil }
        return info[kSecCodeInfoPList as String] as? [String: Any] ?? [:]
    }

    /// Puts `new` where `current` is. The running copy's files stay open until this process
    /// quits, so it carries on until then.
    static func install(_ new: URL, replacing current: URL) throws {
        do { _ = try FileManager.default.replaceItemAt(current, withItemAt: new) } catch { throw Failure.replace }
    }

    /// Opens `app` as soon as process `pid` (this one) has exited, as a fresh launch: none of this
    /// process's environment carries over. Waits `seconds` at most.
    @discardableResult
    static func relaunch(_ app: URL, after pid: Int32 = ProcessInfo.processInfo.processIdentifier,
                         waitingAtMost seconds: Int = 120) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.environment = ["PATH": "/usr/bin:/bin"]
        // gives up after `seconds`: a copy that hangs on its way out leaves no shell waiting on it
        // for ever, and opening the app then would only bring the hung copy forward
        process.arguments = ["-c", """
            n=0; while /bin/kill -0 "$1" 2>/dev/null; do
              n=$((n + 1)); [ "$n" -gt "$2" ] && exit 1; /bin/sleep 0.2
            done; /usr/bin/open "$0"
            """, app.path, String(pid), String(seconds * 5)]
        return (try? process.run()) != nil ? process : nil
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
