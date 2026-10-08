// ============================================================
//  Distribution — how this copy reached the Mac
// ============================================================

enum Distribution {
    /// The Mac App Store build (`script/appstore.sh`, compiled with `-D APPSTORE`): sandboxed,
    /// updated by the App Store and its crashes reported through it, so the app neither offers
    /// updates of its own nor looks for crash reports.
    #if APPSTORE
    static let isAppStore = true
    #else
    static let isAppStore = false
    #endif
}
