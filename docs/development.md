# Developing PhotoCatalog

Building, testing, localizing and releasing PhotoCatalog, and how the code is laid out. [README](../README.md) has the overview; coding agents also read [AGENTS.md](../AGENTS.md).

## Building

Requires a Swift 6 toolchain on macOS 14+ on Apple silicon (the AI code uses `Float16`, which doesn't exist on Intel). Full Xcode is required to run XCTest; the app itself also builds with compatible Command Line Tools. You can also open `Package.swift` in Xcode and run the `PhotoCatalog` scheme.

```sh
script/build_and_run.sh build      # compile (Debug) and assemble dist/PhotoCatalog.app
script/build_and_run.sh run        # build (Release) and launch the app
script/build_and_run.sh verify     # build (Release), launch, and verify a visible window
```

Launch modes (`run`, `verify`, `logs`, `telemetry`) build the optimized Release configuration; `build`, `selfcheck` and `pipeline` use Debug because the checks rely on `assert`, which Release compiles out. Set `CONFIGURATION=debug` or `CONFIGURATION=release` to override.

The script honors `SDKROOT` when set. Otherwise it probes the installed macOS SDKs and selects one compatible with the active Swift compiler, which also handles temporarily out-of-sync Command Line Tools installations.

### Tests and checks

```sh
script/build_and_run.sh selfcheck       # headless demo-dataset and per-feature checks
script/build_and_run.sh pipeline        # headless end-to-end import checks
script/check_localization.py            # untranslated or unlocalized UI text
swift test                              # model, AppState and UI-helper tests (full Xcode)
swift test --filter SmartMatcherTests   # one XCTest class

./.build/debug/PhotoCatalog --full-backup-check          # backup and restore, with temporary fixtures
./.build/debug/PhotoCatalog --task-center-check          # task history and lifecycle
./.build/debug/PhotoCatalog --description-review-check   # AI consent and review, with synthetic images and a loopback service
./.build/debug/PhotoCatalog --selfcheck --benchmark      # adds a 100k synthetic metadata benchmark
./.build/debug/PhotoCatalog --import-memory-check "/path/to/sample.CR3" 200
./.build/release/PhotoCatalog --scale 500000 /tmp/scale.photolibrary   # large-catalog benchmark
```

The selfcheck and the `--…-check` modes verify with `assert`, so they need a Debug build: a Release binary refuses them with exit status 2 rather than report a pass it never checked. `--pipeline`, `--import-memory-check` and `--scale` judge their own results and run in either configuration.

For `swift test`, pass `--sdk /path/to/MacOSX.sdk` when the default SDK is incompatible with the active compiler; the SDK must come from a full Xcode installation.

Test runs and the headless modes (`--selfcheck`, `--pipeline`, `--scale`, `--import-memory-check` and the other `--…-check` modes) keep away from the user's settings and library (`IsolatedRun` in `Infrastructure/Preferences/AppDefaults.swift`):
- Their preferences (`UserDefaults.app`) are a suite of their own, `PhotoCatalogTests` for XCTest and `PhotoCatalogChecks.<mode>` for a check, emptied as each run starts. They never reach the test runner's domain, which every `swift test` on the Mac shares, nor what an app run reads (a `swift run` of the unbundled binary reads the `PhotoCatalog` domain, the app bundle `com.photocatalog.app`). A second run at the same time, in another checkout or the same one, takes the next suite (`….2`, `….3`); each run holds a lock file in the temporary folder until it ends. A suite still reads a key set in the global domain for every app, so a test that depends on a setting sets it.
- Their Pictures folder (`FileAccessService.picturesFolder`) is a stand-in in the temporary folder (`<suite>.Pictures`), emptied as each run starts. The default catalog is in Pictures, and so are the default export, card-copy and tether folders: a test or check that falls back on one of them never reaches the user's library. Tests that made an `AppState()` with the launch settings left alone once opened the user's catalog and backed it up: a `pc_onboarded` in the global domain made every run start onboarded, and the last catalog opened by default was the default one.
- Every run starts from the app's defaults: set a preference for one run with an argument, which any suite reads, e.g. `--scale 500000 /tmp/scale.photolibrary -pc_pairRawJpeg NO -pc_autoStackSeconds '<real>5</real>'` (a plain `5` would be read as text).
- Within a run, a test puts back what it changes: `preservingPreferences(_:)` for the settings it sets, `preservingAllPreferences()` for one that opens catalogs, which also remembers each catalog and folder and dates each automatic backup (`CatalogTestCase` and the other catalog test classes do it in `setUp`). An `AppState()` made in a test opens the last catalog unless `pc_openLast` is off: `openingNoCatalogAtLaunch()` starts it on the demo photos.

The scale benchmark generates a synthetic catalog of the given size once (later runs reuse it), then times loading, list changes, counts and edits and reports memory. Build Release first (`CONFIGURATION=release script/build_and_run.sh build`). It edits the benchmark catalog, so never point it at a real library.

The import memory check reads the supplied image through distinct temporary symlinks, exercises the real import pipeline without the UI, and removes its temporary catalog afterward. It fails above 512 MiB at a file boundary or if growth after warm-up reaches 128 MiB. It never imports into an existing catalog or changes the original. It is a repeated-input regression check, not a full-library or all-RAW-format performance guarantee.

### Continuous integration

GitHub Actions runs on pull requests, pushes to `main` and manual dispatches, on the standard `macos-26` ARM64 runner with Xcode 26.6 from the [runner image](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md). It checks localization and that the product site is built, builds the Debug app bundle, builds Release with warnings treated as errors, runs XCTest, then runs the full `selfcheck` and `pipeline` commands above. Checks run one after another because they share build output. No signing credentials or external AI service is needed.

The full selfcheck exercises Metal kernels, the bundled Core ML models and video encoding; an unsupported runner fails these checks instead of silently skipping them. This is headless regression coverage, not interactive UI, physical-camera or real-RAW acceptance. Failed runs keep their check logs for seven days. The workflow does not publish the app.

### Adding UI text

UI text is written in Chinese in the source and used as the lookup key. SwiftUI literals (`Text("…")`, `Button("…")`) localize by themselves; text built as a `String` goes through `L("…")` (`Domain/Localization.swift`), and toasts take a localizable value. The English tables live in `Resources/Localization/en.lproj`, which the build script copies into the app. `L(…, table: "Context")` carries a second English meaning of the same Chinese text (色调 is both Tone and Tint). Stored values such as capture-time sources and smart-album operators stay as they are in the catalog; only their display is translated.

1. Write it in Chinese in the code, as above.
2. Add the English to `Resources/Localization/en.lproj/Localizable.strings`, keeping the format specifiers (`%lld` for numbers, `%@` for text; `%1$@`-style positions when English reorders them).
3. If the English counts something ("%lld photos"), run `script/check_localization.py plurals`.
4. Run `script/check_localization.py`: it reports text that isn't localized or translated, and a counted noun ("Print %lld Photos") whose singular the plural tables don't have yet.

## Architecture

PhotoCatalog began as a native re-creation of two inputs: a design exported from Claude Design (`PhotoCatalog Mac.html` and its React/CSS prototype), the source of truth for the visual system and interactions, and the PRD (`docs/macos_photo_manager_prd_tech.md`), which defines the domain model, layering and core scope in the technology it calls for (§8: Swift, SwiftUI + AppKit). It has since grown into the Develop module and delivery features; `docs/roadmap.md` tracks that work.

The code follows the PRD's layering (§11), with business logic separated from the UI:

```
Sources/PhotoCatalog/
  Theme/            design tokens (light / dark pairs, ported from the prototype's styles.css) + SF Symbol icon map
  Domain/           Asset, Album, SmartAlbumRule + matcher, CaptureTime, DevelopSettings and its parts,
                    export / print / book / slideshow settings, keyword / stack / folder-tree services
  Data/             deterministic demo dataset (port of the prototype's data.jsx) + the headless checks
  Application/      AppState (all UI state), ImportCoordinator (scan → metadata → thumbnail → hash → XMP), undo
  Infrastructure/   the real backend:
    Database/         thin wrapper over the system SQLite library
    Catalog/          .photolibrary package, schema, persistence, health check
    FileAccess/       security-scoped bookmarks
    Scanner/          recursive enumeration + FSEvents folder watching
    Import/           memory cards, cameras and iPhones (ImageCaptureCore), tethering
    Metadata/         Image I/O EXIF / TIFF / GPS reader + XMP sidecar read / write
    Thumbnail/        thumbnail and preview generation + sharded disk cache
    Hash/             quick hash + SHA-256 (exact) + dHash (perceptual)
    Develop/          Core Image renderer + Metal kernels compiled at run time
    AI/               language-model client (Anthropic and OpenAI-compatible, URLSession only) + Core ML features
    Vision/           scene tagging, face recognition
    Merge/            HDR and panorama
    Export/ Print/ Book/ Slideshow/ Web/
    Rename/ Backup/ Updates/ Diagnostics/
  Presentation/     SwiftUI views:
    MainWindow/       split view, toolbar, filter bar, status bar, root key handling, menu commands
    Sidebar/ Grid/ Loupe/ Compare/ Survey/ Develop/ Inspector/ People/ Map/ Analysis/ Slideshow/
    Components/       Thumb, shared atoms, flow layout
    Sheets/           dialogs, including Settings
```

`AppState.swift` holds AppState's stored properties, `init` and `deinit` (the `@Observable` macro needs the stored properties in the class body); its methods and computed properties live in `extension AppState` files beside it, one per area: `AppState+DerivedCaches` (asset edits and the derived caches they patch), `+Sidebar` and `+Stacks` (sidebar lists and counts, stacks and RAW+JPEG pairs), `+Filtering` (base collection, filter bar, search, sort), `+Navigation` (navigation, selection, compare, survey, keyboard), `+Mutations` (edits with undo, quick collection, album sets), `+ViewOptions` (panels, sheets, toasts, thumbnail size, onboarding), `+Settings` (settings, updates, crash reports, language), `+Develop`, `+DevelopMasks`, `+DevelopPresets` and `+DevelopHistory`, `+Catalog` (open / load) and `+CatalogMaintenance` (health, cache, backup), `+Import`, `+Tether`, `+FolderWatch`, `+Sidecars` (capture-time shift, XMP sidecars, editing in another app), `+Merge`, `+AI`, `+VirtualCopiesRename`, `+Export` and `+Output` (slideshow, web gallery, book, print), `+Duplicates`, `+Places`, `+People`, plus `+TaskCenter`, `+FullBackup` and `+DescriptionReview`.

`CatalogStore` is laid out the same way: `CatalogStore.swift` holds the class, its stored properties and `init`; the record types it hands out are in `CatalogRecords.swift`; and its methods are in `CatalogStore+Schema` (migrations), `+Assets` (columns, upserts, column updates, loading), `+AssetQueries` (search, paged queries), `+SourceRoots`, `+Albums` (albums, smart albums, album sets), `+Develop` (settings, sidecar sync times, history, snapshots), `+Faces`, `+Import` (import sessions, jobs), `+Package` (package paths, backup, manifest) and `+Rows` (row ⇄ Asset). The Develop panel's `DevelopPanel.swift` holds the view's state and `body`; its sections are in `DevelopPanel+Sections` (their order), `+Header`, `+Tools`, `+Masks`, `+Adjustments` and `+Editing` (slider, draft and commit helpers), and its building blocks in `DevelopSection`, `DevelopSlider`, `DevelopHistogramView` and `DevelopByTextField`.

`DevelopRenderer` is split by render stage: `DevelopRenderer.swift` holds the shared Core Image context, color spaces, `render` and the histogram; `DevelopRenderer+Source` the decoded photo and its pipeline; `+Geometry`, `+Color` (lens, profile, calibration, tone, curve, mixer, LUT, presence), `+Local` (masks, spots, overlays, lens blur) and `+Detail` (sharpening, noise reduction, effects) its stages; `DevelopRenderWorker.swift` the background render queue. The develop check is `DevelopCheck.swift` (`run()` and shared helpers) with its checks in `DevelopCheck+<Area>` files. The pipeline check's `run()` in `PipelineCheck.swift` makes a `PipelineCheck.Run`, whose properties are the state its steps share, and calls the steps in order; the steps are methods in `PipelineCheck+<Area>` files, each documented with its step number.

The demo dataset is a **bit-faithful port** of the prototype's generator: the same Unsplash photo IDs and the exact same seeded-RNG call sequence, so its deterministic counts match the design mock (44 photos; folders 24 / 12 / 8; smart albums 13 & 12; etc.). The headless checks run against it; it is never saved to a catalog.

Still deferred from the PRD: an Apple Photos import bridge, a plugin system, and a fully normalized keyword table (keywords are stored per asset and indexed by FTS5). The optional auto-update it suggests Sparkle for shipped as the app's own updater instead (see [Releasing](#releasing)).

### Bundled AI models

`Resources/Models` holds the Core ML packages the app bundles, compiled on first use and kept in Application Support:

| Package | Model | License |
| --- | --- | --- |
| `SuperResolution` | Real-ESRGAN | BSD 3-Clause |
| `Denoise` | SCUNet | Apache 2.0 |
| `Inpaint` | LaMa (plain convolutions quantized to 8 bits) | Apache 2.0 |
| `Depth` | Depth Anything V2 Small | Apache 2.0 |
| `Segmentation` | DETR ResNet-50 semantic segmentation | Apache 2.0 |
| `ObjectEncoder` / `ObjectPrompt` / `ObjectDecoder` | SAM 2.1 Tiny | Apache 2.0 |
| `FaceRecognition` | SFace | Apache 2.0 |

`Depth`, `Segmentation` and the `Object` models are Apple's own Core ML conversions, used as published; `Resources/Models/LICENSES.md` has the licenses and what was changed. `script/models/convert.py` rebuilds the others from the authors' released weights and fetches Apple's packages (each checked by SHA-256), with PyTorch and coremltools in a throwaway virtual environment; nothing Python ships, and the app still has no third-party code dependency.

## Product site

The product page and privacy policy, served at https://photocatalog.gooday.dev, are static files in `site/`; the host needs no build step. The pages are written once in `site-src/` with both languages side by side, each element marked `lang="en"` or `lang="zh-Hans"`. `script/build_site.py` writes one page per language: English at the root (the default), Chinese under `zh/`, each in a directory of its own (`privacy/`). It also writes each page's canonical and hreflang links and Open Graph tags, plus `robots.txt`, `sitemap.xml` and `llms.txt` (from `site-src/llms.txt`). The domain is `SITE` at the top of the script. Run it after editing `site-src/`; CI runs `--check`. Preview with `python3 -m http.server --directory site`. Cloudflare Workers Builds deploys `site/` from `main` as static assets, configured by `wrangler.jsonc` (no Worker code); the Worker is named `photocatalog` and serves the custom domain. Cloudflare Web Analytics counts visits through the beacon script in each page's head (site `photocatalog.gooday.dev`, set up with a JS snippet).

On a first visit, the English page sends a browser that prefers Chinese to the Chinese page; the language switch remembers the visitor's choice. Its English link carries `?lang=en`, so opening it in a new tab counts as choosing English too, and a visitor coming from another page of the site is never sent, which keeps English working where storage is blocked. Search engines crawl without that preference, so they get each page as served.

## Releasing

### GitHub

`script/release.sh <version>` builds the Release app with that version, signs it with the hardened runtime, notarizes and staples it, and leaves `dist/PhotoCatalog-<version>.zip` to publish as a GitHub release (`gh release create v<version> …`). It needs a Developer ID Application certificate (`DEVELOPER_ID`) and a notarytool keychain profile (`NOTARY_PROFILE`); the script's header shows the one-time setup.

**Updates.** PhotoCatalog → Check for Updates…, and once a day shortly after launch unless Settings → General → Check for Updates Automatically is off, compares the running version with the latest GitHub release. A Developer ID-signed copy offers Install and Relaunch: it downloads the release's `PhotoCatalog-<version>.zip`, installs it only if the app inside is that version and meets the running app's own designated requirement (same identifier, same team; an altered or differently signed app is refused), swaps it in and relaunches. A copy signed ad hoc, or one in a folder it can't write, offers the download page instead. `PC_UPDATE_FEED` (an https or file URL of a release in GitHub's format) points the check elsewhere for testing; Debug builds also take `PC_UPDATE_REQUIREMENT` in place of the running app's requirement.

**Crash reports.** After an unexpected quit, the next launch offers to show the crash report macOS saved; it stays on the Mac.

### Mac App Store

`script/appstore.sh <version>` builds the Mac App Store edition:

- compiled with `-D APPSTORE`: no Check for Updates…, no automatic update check and no crash-report prompt, since the App Store does both;
- signed with the App Sandbox entitlements in `Resources/AppStore.entitlements` (folders and files the user picks, their bookmarks, ~/Pictures, outgoing network, printing, USB cameras), carrying its provisioning profile;
- wrapped in an installer package, `dist/PhotoCatalog-<version>.pkg`, to upload with Transporter or `xcrun altool --upload-package`.

It needs an Apple Distribution and a Mac Installer Distribution certificate and a Mac App Store provisioning profile for the bundle identifier (`APP_SIGN_IDENTITY`, `INSTALLER_SIGN_IDENTITY`, `PROVISIONING_PROFILE`; `BUNDLE_ID` overrides `com.photocatalog.app`); the script's header shows the setup. `AD_HOC=1 script/appstore.sh <version>` signs the same sandboxed build ad hoc to try it locally. Every build's Info.plist (`script/info_plist.sh`) carries the App Store category, the export-compliance answer, the catalog document type and the Xcode and SDK versions it was built with.

In the sandbox the app reaches what the user chose and nothing else. Photo folders are reached through the security-scoped bookmarks their source roots keep in the catalog (PRD §12.1), refreshed when a folder is renamed or moved, its photos following. Catalogs, export, card-copy, tether and music locations, and places originals were relocated or moved to, are reached through bookmarks `FileAccessService` keeps in the app's settings. A memory card is read once the user allows it in an open panel the import dialog offers, and is remembered for the next time it's inserted.
