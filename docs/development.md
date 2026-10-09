# Developing PhotoCatalog

Building, testing, localizing and releasing PhotoCatalog, and how the code is laid out. [README](../README.md) has the overview; coding agents also read [AGENTS.md](../AGENTS.md).

## Building

Requires a Swift 6 toolchain on macOS 14+ on Apple silicon (the AI code uses `Float16`, which doesn't exist on Intel). Full Xcode is required to run XCTest; the app itself also builds with compatible Command Line Tools. You can also open `Package.swift` in Xcode and run the `PhotoCatalog` scheme.

```sh
script/build_and_run.sh build      # compile (Debug) and assemble dist/PhotoCatalog.app
script/build_and_run.sh run        # build (Release) and launch the app
script/build_and_run.sh verify     # build (Release), launch, and verify a visible window
```

Launch modes (`run`, `verify`, `logs`, `telemetry`) build the optimized Release configuration; `build`, `selfcheck` and `pipeline` use Debug because the checks rely on `assert`. Set `CONFIGURATION=debug` or `CONFIGURATION=release` to override.

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

For `swift test`, pass `--sdk /path/to/MacOSX.sdk` when the default SDK is incompatible with the active compiler; the SDK must come from a full Xcode installation.

The scale benchmark generates a synthetic catalog of the given size once (later runs reuse it), then times loading, list changes, counts and edits and reports memory. Build Release first (`CONFIGURATION=release script/build_and_run.sh build`). It edits the benchmark catalog, so never point it at a real library.

The import memory check reads the supplied image through distinct temporary symlinks, exercises the real import pipeline without the UI, and removes its temporary catalog afterward. It fails above 512 MiB at a file boundary or if growth after warm-up reaches 128 MiB. It never imports into an existing catalog or changes the original. It is a repeated-input regression check, not a full-library or all-RAW-format performance guarantee.

### Continuous integration

GitHub Actions runs on pull requests, pushes to `main` and manual dispatches, on the standard `macos-26` ARM64 runner with Xcode 26.6 from the [runner image](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md). It checks localization and that the product site is built, builds the Debug app bundle, runs XCTest, then runs the full `selfcheck` and `pipeline` commands above. Checks run one after another because they share user defaults and build output. No signing credentials or external AI service is needed.

The full selfcheck exercises Metal kernels, the bundled Core ML models and video encoding; an unsupported runner fails these checks instead of silently skipping them. This is headless regression coverage, not interactive UI, physical-camera or real-RAW acceptance. Failed runs keep their check logs for seven days. The workflow does not publish the app.

### Adding UI text

UI text is written in Chinese in the source and used as the lookup key. SwiftUI literals (`Text("…")`, `Button("…")`) localize by themselves; text built as a `String` goes through `L("…")` (`Domain/Localization.swift`), and toasts take a localizable value. The English tables live in `Resources/Localization/en.lproj`, which the build script copies into the app. `L(…, table: "Context")` carries a second English meaning of the same Chinese text (色调 is both Tone and Tint). Stored values such as capture-time sources and smart-album operators stay as they are in the catalog; only their display is translated.

1. Write it in Chinese in the code, as above.
2. Add the English to `Resources/Localization/en.lproj/Localizable.strings`, keeping the format specifiers (`%lld` for numbers, `%@` for text; `%1$@`-style positions when English reorders them).
3. If the English counts something ("%lld photos"), run `script/check_localization.py plurals`.
4. Run `script/check_localization.py`: it reports text that isn't localized or translated.

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

On a first visit, the English page sends a browser that prefers Chinese to the Chinese page; the language switch remembers the visitor's choice. Search engines crawl without that preference, so they get each page as served.

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

It needs an Apple Distribution and a Mac Installer Distribution certificate and a Mac App Store provisioning profile for the bundle identifier (`APP_SIGN_IDENTITY`, `INSTALLER_SIGN_IDENTITY`, `PROVISIONING_PROFILE`; `BUNDLE_ID` overrides `com.photocatalog.app`); the script's header shows the setup. `AD_HOC=1 script/appstore.sh <version>` signs the same sandboxed build ad hoc to try it locally. Every build's Info.plist carries the App Store category, the export-compliance answer and the Xcode and SDK versions it was built with.

In the sandbox the app reaches what the user chose and nothing else. Photo folders are reached through the security-scoped bookmarks their source roots keep in the catalog (PRD §12.1), refreshed when a folder is renamed or moved, its photos following. Catalogs, export, card-copy, tether and music locations, and places originals were relocated or moved to, are reached through bookmarks `FileAccessService` keeps in the app's settings. A memory card is read once the user allows it in an open panel the import dialog offers, and is remembered for the next time it's inserted.
