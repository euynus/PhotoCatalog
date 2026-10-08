# AGENTS.md

This file provides guidance to coding agents (Claude Code, Codex, …) when working with code in this repository.

## Commands

```sh
script/build_and_run.sh build        # compile (Debug) and assemble dist/PhotoCatalog.app
script/build_and_run.sh run          # build Release and launch (also: verify, logs, telemetry, debug)
script/build_and_run.sh selfcheck    # headless: demo dataset + every feature check (Debug, asserts)
script/build_and_run.sh pipeline     # headless: end-to-end real-import pipeline test
script/check_localization.py          # untranslated / unlocalized UI text (`plurals` regenerates plural tables)

./.build/release/PhotoCatalog --scale 500000 /tmp/scale.photolibrary          # large-catalog benchmark
./.build/debug/PhotoCatalog --import-memory-check "/path/to/sample.CR3" 200   # import memory regression
./.build/debug/PhotoCatalog --selfcheck --benchmark                           # + 100k metadata benchmark
```

Plain `swift build` / `swift run PhotoCatalog` also work, but if they fail with missing SwiftUI macro plugins the default SDK doesn't match the toolchain — the script probes for a compatible SDK (or honors `SDKROOT`). Launch modes build Release (Debug Swift is several times slower on catalog-sized filtering/sorting); `build`/`selfcheck`/`pipeline` stay Debug because the checks rely on `assert`. Override with `CONFIGURATION=debug|release`. Requires a Swift 6 toolchain on macOS 14+ (the package builds in Swift language mode v5). `--scale` edits its catalog: never point it, or any check, at a real library.

**Tests.** The suite includes two headless modes: `--selfcheck` (`Data/SelfCheck.swift`, which also runs the per-feature checks in `Data/*Check.swift` — develop, undo, faces, export, print, LLM, …) and `--pipeline` (`Data/PipelineCheck.swift`). Run both after changes to import, catalog, the demo dataset or a checked feature; add feature-level coverage as a `Data/<Feature>Check.swift` called from `SelfCheck.run()`. The XCTest target (`Tests/PhotoCatalogTests`) covers focused model, AppState, and UI-helper behavior. Run `swift test` with full Xcode, or one class with `swift test --filter SmartMatcherTests`; pass `--sdk /path/to/MacOSX.sdk` if the default SDK is incompatible with the active compiler.

`script/release.sh <version>` builds, signs (Developer ID, hardened runtime), notarizes and zips a release for GitHub; Check for Updates… looks for the asset `PhotoCatalog-<version>.zip`. `script/appstore.sh <version>` builds the sandboxed Mac App Store edition (`-D APPSTORE` → `Distribution.isAppStore` hides the updater and the crash-report prompt; entitlements in `Resources/AppStore.entitlements`); `AD_HOC=1` signs it ad hoc for local sandbox testing.

**Sandbox.** The App Store build can only touch what the user picked (panel, drop, Finder open) plus ~/Pictures. A sandboxed copy still *sees* other files (`fileExists` is true) but can't read them, so check readability with `FileAccessService.canRead`. Anything the app opens again in a later launch needs a security-scoped bookmark: photo folders keep theirs in `source_roots`; any other place the user chooses (catalog, output folder, music, card…) goes through `FileAccessService.remember(_:)` when picked and `reach(_:)` before use. Paths from `picturesDirectory` must be resolved (`FileAccessService.picturesFolder`), since the sandbox hands out the container's link.

## What this is

A native SwiftUI macOS app — a local-first, non-destructive photo manager in Lightroom's mould: a Library (catalog, import, culling, keywords, albums, smart albums, people, places, duplicates) and a Develop module (non-destructive RAW development with masks, healing, presets, history), plus export, print, book, slideshow, web gallery, HDR/panorama merge, tethering and AI features. It began as a faithful re-creation of a Claude Design prototype (HTML/React) implementing the PRD at `docs/macos_photo_manager_prd_tech.md`; the PRD is the source of truth for domain model, layering and core scope, and source comments cite its sections (e.g. "PRD §6.3").

UI text is written in Chinese (the design's language) and the Chinese string is the lookup key. SwiftUI literals localize themselves; text built as a `String` goes through `L("…")` (`Domain/Localization.swift`); `L(…, table: "Context")` carries a second English meaning of the same Chinese text. English lives in `Resources/Localization/en.lproj` (keep `%lld`/`%@` specifiers; counted English nouns need `script/check_localization.py plurals`). Run the checker after changing UI text; when it can't infer an interpolation's type, add the expression to `SPEC_OVERRIDES` in the script. Stored values (smart-album operators, capture-time sources) stay as they are in the catalog; only their display is translated.

## Architecture

Layered per PRD §11, business logic separated from UI, all under `Sources/PhotoCatalog/`:

- **Theme/** — design tokens + SF Symbol icon map. Workspace tokens are light/dark pairs (`Theme.dynamic`) that follow the system or Settings → 外观; the photo canvas (`canvas*`) is always dark. Blue accent: `accent` for text/icons/rings, `accentFill` behind white labels. `--selfcheck` asserts token contrast in both appearances.
- **Domain/** — pure model types: `Asset`, `Album`, `SmartAlbumRule` + matcher, `CaptureTime`, `DevelopSettings` (and its parts: tone curve, masks/local adjustments, spot removal, color grading, history), export/print/book/slideshow settings, keyword/stack/folder-tree services.
- **Data/** — deterministic demo dataset + the headless checks. The demo generator is a **bit-faithful port** of the prototype's seeded RNG (same Unsplash IDs, same RNG call sequence) so counts match the design mock exactly — do not reorder or add RNG calls, or `--selfcheck` breaks.
- **Application/** — `AppState` (the single `@MainActor @Observable` state object holding all UI state; derived collections are cached in `@ObservationIgnored` fields invalidated in `assets.didSet` according to the edit's `AssetEditScope`, and every cached getter must touch its tracked inputs — e.g. `_ = listInputsVersion` — so cache hits register the same view dependencies as misses), `ImportCoordinator` (scan → metadata → thumbnail → hash → XMP → Asset, on a background queue, a few files in parallel; referenced and managed import modes), and `UndoSteps` (undo registered by work that finishes after its event — auto tone, mask detection — gets a group of its own instead of merging with the user's next action).
- **Infrastructure/** — the real backend:
  - `Database/` thin wrapper over the system SQLite library; `Catalog/` the `.photolibrary` package (`catalog.sqlite` + `manifest.json` + `Cache/` + `Backups/`), schema, persistence, backup, health check
  - `Metadata/` Image I/O EXIF/TIFF/GPS reader + XMP sidecar read/write; `Thumbnail/` generation + sharded disk cache; `Hash/` quick hash + SHA-256 (exact dup) + dHash (perceptual dup)
  - `Scanner/` recursive enumeration + FSEvents folder watching; `FileAccess/` security-scoped bookmarks
  - `Develop/` `DevelopRenderer` renders `DevelopSettings` with Core Image in extended linear Display P3. Adjustments Core Image lacks are Metal kernels in `DevelopKernels`, compiled from source at run time (the package has no Metal build step); a kernel that fails to compile silently drops its adjustment from the render, so check output after editing kernel source.
  - `AI/` `LLMClient` (Anthropic Messages and OpenAI-compatible chat, URLSession only; replies are validated, not trusted) and the Core ML features. The models are `.mlpackage`s in `Resources/Models`, compiled on first use; `script/models/convert.py` rebuilds them, and Python never ships. `Vision/` holds scene tagging and `FaceService` (face recognition on the bundled model).
  - `Export/`, `Print/`, `Book/`, `Slideshow/`, `Web/`, `Merge/` (HDR/panorama), `Rename/`, `Backup/`, `Updates/`, `Diagnostics/`
- **Presentation/** — SwiftUI views. `MainWindow/` is a NavigationSplitView + `.inspector`, with the toolbar (图库 | 修图 module picker + view menu), filter bar, status bar and root key handling. Alongside it are Sidebar, Grid, Loupe, Compare, Survey, Develop, Inspector, People, Map, Analysis, Slideshow, and Sheets.
  - The left column is the library `Sidebar`, or `Develop/DevelopSidebar` (presets, snapshots, history) while in Develop. The adjustments are `Develop/DevelopPanel`, in the inspector column.
  - Sheets are routed by the string `app.sheet` (switched in `MainView.sheetContent`). A sheet closes with its own buttons or Esc (RootView's key handling), never a close box.
  - Settings is a SwiftUI `Settings` scene (⌘,). Code opens it by bumping `app.settingsRequest`, which RootView turns into `openSettings`. `openSettings(category:)` opens it at a category.

Data flow: views mutate through `AppState`; catalog-backed edits (rating/flag/color/keywords/title/caption, develop settings) write through `CatalogStore` and survive relaunch. Imported real assets coexist with the in-memory demo set (demo assets are marked and never persisted).

SwiftUI pitfalls hit here before:
- A scroll view flush with the top of the inspector or sidebar column runs under the toolbar, where hit-testing is offset. Start such content a point lower (`.padding(.top, 1)`).
- Views that update themselves asynchronously (`Thumb`, `ZoomablePhoto`, `FaceAvatar`) read `AppState` as an optional environment value: SwiftUI can still update them inside a detached hosting view, where the environment is gone.

## Conventions

- Package has zero external dependencies — system frameworks only (SQLite, Image I/O, Core Image, Core ML, MapKit, Vision, CryptoKit, ImageCaptureCore). Keep it that way unless asked.
- Commits follow Conventional Commits (`feat(xmp): …`, `fix(backup): …`), one feature per commit.
- Keyboard shortcuts are centralized in `Presentation/MainWindow/` (RootView key handling + `PhotoCatalogCommands`); the full shortcut map is documented in `docs/features.md`.
- `site/` is the product page and privacy policy: static files, no build step, both languages in the markup (`lang` attributes; `site.js` flips `data-lang`). Its screenshots use Unsplash sample photos, never the user's own library.
- Document user-visible behavior in `docs/features.md` as part of the change. The docs are English, so quote menu items, buttons and settings as the English interface shows them (their `en.lproj` values), never the Chinese keys. README.md is a one-page overview: touch it only when a highlight changes. Build, test, architecture and release notes for people live in `docs/development.md`.
