// ============================================================
//  Moving a finished temporary file into place
// ============================================================
import Foundation

extension FileManager {
    /// Puts `temporary` (written beside `target`) at `target`, replacing a file already there,
    /// so a reader only ever sees the old file or the whole new one. When that fails the
    /// temporary file is removed before the error is thrown.
    func moveIntoPlace(_ temporary: URL, at target: URL) throws {
        do {
            if fileExists(atPath: target.path) {
                _ = try replaceItemAt(target, withItemAt: temporary)
            } else {
                try moveItem(at: temporary, to: target)
            }
        } catch {
            try? removeItem(at: temporary)
            throw error
        }
    }
}
