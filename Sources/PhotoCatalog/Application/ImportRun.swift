// ============================================================
//  ImportRun — user-visible import progress state
// ============================================================
import Foundation

enum ImportPhase: String, Sendable {
    case scanning, importing, paused, complete, failed

    var isActive: Bool {
        self == .scanning || self == .importing || self == .paused
    }

    var isFinished: Bool {
        self == .complete || self == .failed
    }
}

struct ImportRun: Identifiable, Equatable, Sendable {
    let id: UUID
    let sourcePath: String
    let sourceName: String
    let mode: ImportMode
    let startedAt: Date
    var phase: ImportPhase
    var total: Int
    var processed: Int
    var failed: Int
    var skipped: Int
    var recentAssets: [Asset]
    var failures: [ImportFailure]
    var finishedAt: Date?
    var errorMessage: String?

    init(source: URL, mode: ImportMode) {
        id = UUID()
        sourcePath = source.path
        sourceName = source.lastPathComponent
        self.mode = mode
        startedAt = .now
        phase = .scanning
        total = 0
        processed = 0
        failed = 0
        skipped = 0
        recentAssets = []
        failures = []
        finishedAt = nil
        errorMessage = nil
    }

    var scanned: Int {
        phase == .scanning && total == 0 ? 0 : total
    }

    var imported: Int {
        max(0, processed - skipped)
    }

    var pending: Int {
        max(0, total - processed - failed)
    }

    var percent: Int {
        guard total > 0 else { return phase.isFinished ? 100 : 0 }
        let value = Double(processed + failed) / Double(total) * 100
        return min(100, max(0, Int(value.rounded())))
    }
}

extension ImportMode {
    var displayName: String {
        switch self {
        case .managed: return "托管式"
        case .referenced: return "引用式"
        }
    }
}
