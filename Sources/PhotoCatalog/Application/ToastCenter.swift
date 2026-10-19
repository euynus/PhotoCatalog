// ============================================================
//  ToastCenter — transient toast feedback in its own small store
//  so appends and the 2.2 s timed removals invalidate only the
//  overlay, not every view observing AppState.
// ============================================================
import AppKit
import Observation

@MainActor
@Observable
final class ToastCenter {
    var toasts: [Toast] = []
    /// Reads a toast out to VoiceOver as it appears: it is gone after 2.2 s and is the only report of
    /// some failures. Tests swap it out to hear what would be said.
    @ObservationIgnored var announce: (_ message: String, _ priority: NSAccessibilityPriorityLevel) -> Void
        = ToastCenter.postAnnouncement

    func push(_ message: String, _ icon: String = "check") {
        let toast = Toast(message: message, icon: icon)
        toasts.append(toast)
        announce(message, icon == "warning" ? .high : .medium)   // a failure interrupts; other news waits
        Task { [weak self, toast] in
            try? await Task.sleep(for: .seconds(2.2))
            self?.toasts.removeAll { $0.id == toast.id }
        }
    }

    private static func postAnnouncement(_ message: String, priority: NSAccessibilityPriorityLevel) {
        guard let app = NSApp else { return }   // headless checks have no application
        NSAccessibility.post(element: app, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: priority.rawValue])
    }
}
