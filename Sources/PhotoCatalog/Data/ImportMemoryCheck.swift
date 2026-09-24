import Foundation
import Darwin

enum ImportMemoryCheck {
    static func run(arguments: [String]) -> Int32 {
        guard let path = arguments.first,
              arguments.count <= 2,
              let count = arguments.count == 2 ? Int(arguments[1]) : 40,
              (20...1000).contains(count) else {
            print("Usage: PhotoCatalog --import-memory-check <image-path> [20...1000]")
            return 2
        }
        let original = URL(fileURLWithPath: path)
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("pc-import-memory-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: directory) }
        do {
            guard fm.isReadableFile(atPath: original.path), FileScanner.isSupported(original) else {
                print("Input must be a readable image")
                return 2
            }
            let source = directory.appendingPathComponent("source")
            try fm.createDirectory(at: source, withIntermediateDirectories: true)
            let files = try (0..<count).map { index in
                let link = source.appendingPathComponent("image-\(index).\(original.pathExtension)")
                try fm.createSymbolicLink(at: link, withDestinationURL: original)
                return link
            }
            let store = try CatalogStore(packageURL: directory.appendingPathComponent("Check.photolibrary"))
            let control = ImportControl()
            var warmFootprint: UInt64 = 0
            var peakFootprint: UInt64 = 0
            var measurementFailed = false
            let imported = ImportCoordinator(store: store).importFiles(
                files, from: source, readSidecar: false, control: control
            ) { progress in
                guard progress.processed > 0 else { return }
                guard let bytes = footprint() else {
                    measurementFailed = true
                    control.cancel()
                    return
                }
                if progress.processed == 5 { warmFootprint = bytes }
                if progress.processed >= 5 { peakFootprint = max(peakFootprint, bytes) }
                if progress.processed == 1 || progress.processed % 5 == 0 {
                    print("imported=\(progress.processed) footprintMiB=\(bytes / 1_048_576)")
                    fflush(stdout)
                }
                if bytes > 512 * 1_048_576 { control.cancel() }
            }
            let growth = peakFootprint > warmFootprint ? peakFootprint - warmFootprint : 0
            let passed = !measurementFailed && imported.count == count && warmFootprint > 0
                && peakFootprint <= 512 * 1_048_576
                && growth < 128 * 1_048_576
                && imported.allSatisfy { !$0.thumb.isEmpty && !$0.preview.isEmpty && $0.contentHash != nil }
            print("\(passed ? "PASS" : "FAIL") imported=\(imported.count)/\(count) warmMiB=\(warmFootprint / 1_048_576) peakMiB=\(peakFootprint / 1_048_576) growthMiB=\(growth / 1_048_576)")
            return passed ? 0 : 1
        } catch {
            print("FAIL import memory check: \(error)")
            return 1
        }
    }

    private static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }
}
