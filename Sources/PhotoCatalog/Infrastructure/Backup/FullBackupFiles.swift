import CryptoKit
import Darwin
import Foundation

/// Filesystem operations shared by backup and restore. All writes are confined to a new,
/// private staging directory; publishing uses an exclusive rename, not replacement.
enum FullBackupFiles {
    struct Fingerprint: Equatable {
        let size: Int64
        let sha256: String
    }

    static func checkCancellation(_ cancellation: CancellationFlag?) throws {
        if cancellation?.isSet == true || Task.isCancelled { throw CancellationError() }
    }

    static func validComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.contains(where: { $0 == "/" || $0 == "\\" || $0 == ":" || $0.isNewline })
            && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    static func validRelativePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { validComponent(String($0)) }
    }

    static func pathKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    static func contains(_ parent: URL, _ child: URL) -> Bool {
        // Foundation shortens existing system paths but can retain /private for a missing
        // destination. Normalize these two aliases lexically on both sides of containment.
        func comparablePath(_ url: URL) -> String {
            var path = url.standardizedFileURL.path
            if ["/private/var", "/private/tmp"].contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                path.removeFirst("/private".count)
            }
            return pathKey(path)
        }
        let base = comparablePath(parent), path = comparablePath(child)
        return path == base || path.hasPrefix(base == "/" ? base : base + "/")
    }

    /// Reject symlinks, including dangling links and intermediate path components. macOS's
    /// standard /tmp and /var aliases are the only exceptions, resolved before any I/O.
    static func checked(_ url: URL, allowMissingLeaf: Bool = false) throws -> URL {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              !url.path.utf8.contains(0) else { throw FullBackupError.unsafePath(url.path) }
        let url = url.standardizedFileURL
        var cursor = URL(fileURLWithPath: "/", isDirectory: true)
        let parts = url.pathComponents.dropFirst()
        for (index, part) in parts.enumerated() {
            cursor.appendPathComponent(part)
            guard let info = try metadata(cursor) else {
                if allowMissingLeaf && index == parts.count - 1 { return cursor }
                throw FullBackupError.missingFile(cursor.path)
            }
            if info.st_mode & S_IFMT == S_IFLNK {
                guard index == 0, ["/tmp", "/var"].contains(cursor.path) else {
                    throw FullBackupError.unsafePath(cursor.path)
                }
                let physicalPath = "/private" + cursor.path
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: cursor.path)
                let physical = URL(fileURLWithPath: physicalPath, isDirectory: true)
                // resolvingSymlinksInPath() can shorten /private/var back to /var. Inspect
                // the actual link and its two directory components without re-normalizing.
                guard [physicalPath, String(physicalPath.dropFirst())].contains(target),
                      let baseInfo = try metadata(URL(fileURLWithPath: "/private")), baseInfo.st_mode & S_IFMT == S_IFDIR,
                      let targetInfo = try metadata(physical), targetInfo.st_mode & S_IFMT == S_IFDIR else {
                    throw FullBackupError.unsafePath(cursor.path)
                }
                cursor = physical
            } else if index < parts.count - 1 && info.st_mode & S_IFMT != S_IFDIR {
                throw FullBackupError.unsafePath(cursor.path)
            }
        }
        return cursor
    }

    static func metadata(_ url: URL) throws -> stat? {
        var info = stat()
        if lstat(url.path, &info) == 0 { return info }
        if errno == ENOENT { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    static func regularFile(_ url: URL) throws -> URL {
        let url = try checked(url)
        guard let info = try metadata(url), info.st_mode & S_IFMT == S_IFREG else {
            throw FullBackupError.unsafePath(url.path)
        }
        return url
    }

    static func directory(_ url: URL) throws -> URL {
        let url = try checked(url)
        guard let info = try metadata(url), info.st_mode & S_IFMT == S_IFDIR else {
            throw FullBackupError.unsafePath(url.path)
        }
        return url
    }

    static func requireUnchanged(_ url: URL, since expected: stat) throws {
        _ = try regularFile(url)
        guard let current = try metadata(url), unchanged(expected, current) else {
            throw FullBackupError.sourceChanged(url.path)
        }
    }

    /// Foundation hides AppleDouble entries even without skipsHiddenFiles. A strict
    /// backup inventory must see every directory entry, including unexpected ._ files.
    static func entries(in root: URL) throws -> [URL] {
        let root = try directory(root)
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard let stream = fdopendir(fd) else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(fd)
            throw error
        }
        defer { closedir(stream) }
        var result: [URL] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                return result
            }
            let length = Int(entry.pointee.d_namlen) + 1
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: length) { String(validatingUTF8: $0) }
            }
            guard let name else { throw FullBackupError.unsafePath(root.path) }
            if name != "." && name != ".." { result.append(root.appendingPathComponent(name)) }
        }
    }

    static func files(in root: URL, cancellation: CancellationFlag?) throws -> [URL] {
        let root = try directory(root)
        var result: [URL] = [], pending = [root]
        while let directory = pending.popLast() {
            try checkCancellation(cancellation)
            for item in try entries(in: directory) {
                guard validComponent(item.lastPathComponent), let info = try metadata(item) else {
                    throw FullBackupError.unsafePath(item.path)
                }
                if item.lastPathComponent == ".DS_Store", info.st_mode & S_IFMT != S_IFREG {
                    throw FullBackupError.unsafePath(item.path)
                }
                switch info.st_mode & S_IFMT {
                case S_IFDIR: pending.append(try self.directory(item))
                case S_IFREG: result.append(try regularFile(item))
                default: throw FullBackupError.unsafePath(item.path)
                }
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    static func createParents(for url: URL, within root: URL) throws {
        guard contains(root, url), url.path != root.path else { throw FullBackupError.unsafePath(url.path) }
        var cursor = try directory(root)
        let relative = url.deletingLastPathComponent().path.dropFirst(root.path.count)
        for part in relative.split(separator: "/") {
            cursor.appendPathComponent(String(part))
            if try metadata(cursor) == nil {
                try FileManager.default.createDirectory(at: cursor, withIntermediateDirectories: false,
                                                       attributes: [.posixPermissions: 0o700])
            }
            _ = try directory(cursor)
        }
    }

    static func writeNew(_ data: Data, to url: URL) throws {
        _ = try directory(url.deletingLastPathComponent())
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    /// Streaming copy/hash is cancellable within a RAW/video file. HashService's URL-only
    /// API cannot pin an O_NOFOLLOW descriptor or detect a file replaced while being read.
    static func fingerprint(_ source: URL, copyingTo target: URL? = nil,
                            cancellation: CancellationFlag?) throws -> Fingerprint {
        try checkCancellation(cancellation)
        let source = try regularFile(source)
        let fd = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else {
            throw FullBackupError.unsafePath(source.path)
        }
        var output: FileHandle?
        if let target {
            _ = try directory(target.deletingLastPathComponent())
            let out = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard out >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            output = FileHandle(fileDescriptor: out, closeOnDealloc: true)
        }
        defer { try? output?.close() }
        var hasher = SHA256(), bytes: Int64 = 0
        while true {
            try checkCancellation(cancellation)
            guard let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty else { break }
            hasher.update(data: data)
            bytes += Int64(data.count)
            try output?.write(contentsOf: data)
        }
        var after = stat()
        _ = try checked(source)
        guard fstat(fd, &after) == 0, let current = try metadata(source),
              unchanged(before, after), unchanged(before, current), bytes == before.st_size else {
            throw FullBackupError.sourceChanged(source.path)
        }
        if let output {
            let times = [before.st_atimespec, before.st_mtimespec]
            guard times.withUnsafeBufferPointer({ futimens(output.fileDescriptor, $0.baseAddress) }) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try output.synchronize()
        }
        return Fingerprint(size: bytes, sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func unchanged(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_size == b.st_size
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }

    final class Staging {
        let destination: URL
        let url: URL
        private let parentFD: Int32
        private let identity: stat
        private var published = false

        init(destination: URL) throws {
            let destination = try FullBackupFiles.checked(destination, allowMissingLeaf: true)
            guard FullBackupFiles.validComponent(destination.lastPathComponent), try FullBackupFiles.metadata(destination) == nil else {
                throw FullBackupError.targetExists(destination.path)
            }
            let parent = try FullBackupFiles.directory(destination.deletingLastPathComponent())
            let fd = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let url = parent.appendingPathComponent(".pc-full-backup-" + UUID().uuidString, isDirectory: true)
            guard mkdirat(fd, url.lastPathComponent, 0o700) == 0 else {
                let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                close(fd)
                throw error
            }
            var identity = stat()
            guard fstatat(fd, url.lastPathComponent, &identity, AT_SYMLINK_NOFOLLOW) == 0 else {
                let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                unlinkat(fd, url.lastPathComponent, AT_REMOVEDIR)
                close(fd)
                throw error
            }
            self.destination = destination
            self.url = url
            self.parentFD = fd
            self.identity = identity
        }

        deinit {
            if !published, (try? validateIdentity()) != nil { try? FileManager.default.removeItem(at: url) }
            close(parentFD)
        }

        func publish() throws {
            try validateIdentity()
            guard renameatx_np(parentFD, url.lastPathComponent, parentFD,
                               destination.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST { throw FullBackupError.targetExists(destination.path) }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            published = true
            _ = fsync(parentFD)
        }

        private func validateIdentity() throws {
            let parent = try FullBackupFiles.directory(url.deletingLastPathComponent())
            var openedParent = stat()
            guard fstat(parentFD, &openedParent) == 0, let parentInfo = try FullBackupFiles.metadata(parent),
                  parentInfo.st_ino == openedParent.st_ino, parentInfo.st_dev == openedParent.st_dev,
                  let current = try FullBackupFiles.metadata(url), current.st_mode & S_IFMT == S_IFDIR,
                  current.st_ino == identity.st_ino, current.st_dev == identity.st_dev else {
                throw FullBackupError.unsafePath(url.path)
            }
        }
    }
}
