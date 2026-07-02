// ============================================================
//  ToastCenter — transient toast feedback in its own small store
//  so appends and the 2.2 s timed removals invalidate only the
//  overlay, not every view observing AppState.
// ============================================================
import Foundation
import Observation

@MainActor
@Observable
final class ToastCenter {
    var toasts: [Toast] = []

    func push(_ message: String, _ icon: String = "check") {
        let toast = Toast(message: message, icon: icon)
        toasts.append(toast)
        Task { [weak self, toast] in
            try? await Task.sleep(for: .seconds(2.2))
            self?.toasts.removeAll { $0.id == toast.id }
        }
    }
}
