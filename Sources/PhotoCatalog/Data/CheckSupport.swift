import Foundation

// Fixtures the headless checks share.

extension AppState {
    /// A fixture showing `photos` from `store` as opening the catalog would, running no background
    /// maintenance: for checks that reload a scratch catalog of their own.
    static func selfCheckFixture(store: CatalogStore, loading photos: [Asset]) -> AppState {
        let app = selfCheckFixture(store: store)
        app.runsBackgroundMaintenance = false
        app.applyLoadedCatalogForScaleCheck(photos, from: store)
        return app
    }
}
