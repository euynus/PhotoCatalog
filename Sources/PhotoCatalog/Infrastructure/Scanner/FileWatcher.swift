// ============================================================
//  FileWatcher — FSEvents folder watching with built-in debounce
//  (PRD §6.3 IMP-002 incremental scan, §12.8)
// ============================================================
import Foundation
import CoreServices

final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let paths: [String]
    private let latency: CFTimeInterval
    private let onChange: ([String]) -> Void

    init(paths: [String], latency: CFTimeInterval = 2.0, onChange: @escaping ([String]) -> Void) {
        self.paths = paths
        self.latency = latency
        self.onChange = onChange
    }

    /// What the stream holds on to instead of the watcher: the stream retains it for as long as
    /// it lives, and a callback already on its way when the watcher is gone finds nobody to call.
    private final class Reference {
        weak var watcher: FileWatcher?
        init(_ watcher: FileWatcher) { self.watcher = watcher }
    }

    func start() {
        guard stream == nil, !paths.isEmpty else { return }
        let reference = Reference(self)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(reference).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Reference>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<Reference>.fromOpaque(info).release()
            },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info, let watcher = Unmanaged<Reference>.fromOpaque(info).takeUnretainedValue().watcher else { return }
            let paths = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
            watcher.onChange(Array(paths.prefix(count)))
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes
        )
        // the stream takes its own retain on the reference as it's created
        let created = withExtendedLifetime(reference) {
            FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        }
        guard let s = created else { return }
        stream = s
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        FSEventStreamStart(s)
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }
}
