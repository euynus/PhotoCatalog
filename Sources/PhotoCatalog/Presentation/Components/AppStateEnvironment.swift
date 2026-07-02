// ============================================================
//  Unobserved AppState environment — lets leaf views (e.g. every
//  grid Thumb) call into AppState without subscribing to its
//  objectWillChange, so unrelated publishes (import progress,
//  toasts, selection) don't re-render hundreds of tiles.
// ============================================================
import SwiftUI

private struct AppStateRefKey: EnvironmentKey {
    static let defaultValue: AppState? = nil
}

/// The preview pixel budget mirrored out of AppState as a plain value, so
/// views that only need this one setting re-render exactly when it changes.
private struct PreviewMaxPixelKey: EnvironmentKey {
    static let defaultValue: Int = 2048
}

extension EnvironmentValues {
    /// AppState without observation — reads never subscribe to objectWillChange.
    var appStateRef: AppState? {
        get { self[AppStateRefKey.self] }
        set { self[AppStateRefKey.self] = newValue }
    }
    var previewMaxPixel: Int {
        get { self[PreviewMaxPixelKey.self] }
        set { self[PreviewMaxPixelKey.self] = newValue }
    }
}
