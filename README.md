# PhotoCatalog Mac

A native **SwiftUI macOS app** that implements the **PhotoCatalog Mac** design — a local-first, non-destructive photo-original manager in the spirit of Lightroom's Library module.

This repository realises two inputs:

- **The design** exported from Claude Design (`PhotoCatalog Mac.html` + its React/CSS prototype) — the source of truth for the visual system and interactions.
- **The PRD** (`docs/macos_photo_manager_prd_tech.md`) — the product/technical spec that defines the domain model, architecture layering, and feature scope.

The HTML/React files were prototypes; this app re-creates them faithfully in native SwiftUI/AppKit, the technology the PRD calls for (§8: Swift, SwiftUI + AppKit).

## What's implemented

A native photo workbench: system-style chrome that follows the macOS light / dark
appearance (Settings → 外观), a neutral dark photo canvas in every mode, and a blue accent:

- **Main window** — native split view: source-list sidebar, unified toolbar (view mode, filter, sort, import / export, catalog actions, search), optional filter bar, photo grid, collapsible Inspector, and a status bar carrying the thumbnail-size slider.
- **Sidebar** — 资料库 (全部 / 最近导入 / 未评分 / 精选 / 被拒绝 / 缺失·离线 / 重复文件), 文件夹, 相册, 智能相册, 关键词 — all with live counts.
- **RAW+JPEG pairs** — a RAW and its same-name JPEG/HEIC in one folder show as one photo; ratings, flags, keywords, time shifts, deletion and batch rename act on both files (Settings → 导入 to list them separately).
- **Grid view** — borderless photo tiles that fill each row, adjustable thumbnail size, offline/missing badges, color labels, flags, star ratings, accent-ring multi-select.
- **Loupe** — single-photo view with bottom HUD and a filmstrip of the current collection.
- **Compare** — 2–4 photos side by side, per-photo rating/flags, "选为最佳" winner.
- **Capture dates** — year/month/day navigation, relative-date presets, and inclusive custom date ranges that can be saved as smart albums.
- **Capture analysis** — camera, lens, focal length, aperture, shutter and ISO distributions for filtered results or selected photos; cancellable background aggregation rejects stale results and reports missing metadata separately.
- **Inspector** — header with focal length / aperture / shutter / ISO at a glance, then Info / Metadata (EXIF, GPS, maker notes) / Organize (rating, flags, color, keywords, title, caption) / History.
- **Smart Album builder** — AND/OR rule rows with a live match-count preview.
- **Duplicate detection** — exact (content-hash) & perceptual groups with keep-one resolution.
- **Import / scan** — animated scan→import progress with a 5-stat panel and a thumbnail wall.
- **First-launch / Welcome** — catalog creation card with recents.
- **Interactions** — click / ⌘-click / ⇧-click selection, live search, filter bar, sort, toasts, and keyboard shortcuts:
  `1–5` rate · `0` clear · `P/X/U` flags · `6–9` color · `G/E/C/A` views · arrows navigate · `Return` loupe · `Esc` close panels · `F` filters · `I` thumbnail info · `⌘F` search · `⌘I` inspector · `⌘N/⌘O` catalog · `⇧⌘I` import · `⌘E` export · `⇧⌘E` preview export · `⌘R` rescan · `⌘B` backup · `⌘,` settings · `⌘+/-/0` thumbnail size · `⌫` remove · `⌘⌫` trash originals.

### Real catalog backend (PRD Infrastructure layer, §11)

Beyond the UI, the app has a working file→catalog pipeline:

- **Add folder import** (toolbar 导入) — `NSOpenPanel` → recursive scan → real EXIF/GPS metadata (Image I/O) → thumbnail + preview generation (sharded disk cache) → content/quick hashing → persisted to a real `.photolibrary` catalog.
- **Import checkpoints** — session/job creation and state transitions use transactions. Persistence failures stop subsequent files and report partial saves; already-copied originals and caches are not automatically removed.
- **SQLite persistence** — a `.photolibrary` package (`catalog.sqlite` + `manifest.json` + `Cache/` + `Backups/`) via the system SQLite library; user edits (rating/flag/color/keywords/title/caption) write through and survive relaunch.
- **Exact duplicate detection** — size-bucketed SHA-256 content hashing.
- **Export** — copy selected originals to a chosen folder (preserving mtime) + JSON metadata sidecar.
- **Backup** — checkpointed catalog copy (click the status-bar backup item).
- **Missing detection** — originals are re-checked on launch and flagged `missing` if gone.
- **Managed import** — optionally copy originals into `Originals/YYYY/MM/DD` (Settings → 导入模式).
- **XMP sidecars** — read on import and written on export / on demand (rating, label, keywords, title, caption).
- **Similar-photo detection** — perceptual dHash + Hamming distance adds 疑似重复 groups.
- **FSEvents watching** — referenced folders are watched; new files import and removed files flag missing automatically.
- **FTS5 search index** + **batch rename** + **catalog health check** + **cache rebuild/clear** (Settings).
- **Places** — a MapKit view of GPS-tagged photos (sidebar 地点).
- **Vision (on-device)** — optional scene tagging + face detection on import; a 人物 collection (sidebar).
- **Offline volumes** — external-drive unmount flags assets `offline` (vs `missing`); remount restores them.
- **Batch capture-time shift** —整体平移选中照片的拍摄时间 (Settings) for timezone / camera-clock fixes.
- Security-scoped bookmarks are created for imported source roots (PRD §12.1).

Imported real photos coexist with the built-in demo set (demo assets are clearly marked and not persisted).

## Architecture

Mirrors the PRD's layering (§11) with business logic separated from UI:

```
Sources/PhotoCatalog/
  Theme/            design tokens (ported from styles.css :root) + SF Symbol icon map
  Domain/           Asset, Album, SmartRule + matcher  (the assets/albums schema, §10)
  Data/             deterministic demo dataset (port of data.jsx) + headless self-checks
  Application/      AppState + ImportCoordinator (scan→meta→thumb→hash pipeline)
  Infrastructure/   the real backend (PRD §11):
    Database/        thin SQLite wrapper over the system library
    Catalog/         .photolibrary package + schema + asset persistence + backup
    FileAccess/      security-scoped bookmarks
    Scanner/         recursive enumeration + UTType detection
    Metadata/        Image I/O EXIF/TIFF/GPS reader + XMP sidecar read/write
    Thumbnail/       Image I/O thumbnail/preview generation + sharded cache
    Hash/            quick hash + SHA-256 (exact) + dHash (perceptual)
    Scanner/         recursive enumeration + FSEvents folder watching
    Rename/          batch rename of originals
    Export/ Backup/  copy originals / catalog backup & restore
  Presentation/
    Components/      Thumb (remote + local cache + gradient fallback), atoms, flow layout
    MainWindow/      titlebar, filter bar, status bar, main layout, root + key handling
    Sidebar/ Grid/ Inspector/ Loupe/ Compare/ Map/ Sheets/ (incl. Settings)
```

The demo dataset is a **bit-faithful port** of the prototype's generator: the same Unsplash photo IDs and the exact same seeded-RNG call sequence, so the deterministic counts match the design mock (44 photos; folders 24 / 12 / 8; smart albums 13 & 12; etc.).

The built-in demo dataset is a **bit-faithful port** of the prototype's seeded RNG so the deterministic counts match the design mock; it provides an instant, populated UI on first launch. Real imported folders are scanned, persisted, and shown alongside it.

> **Implemented vs. remaining (vs. PRD).** Done: catalog persistence (SQLite + FTS5), folder authorization + recursive scan, referenced **and** managed import, Image I/O metadata, XMP sidecar read/write, thumbnail/preview generation + cache (rebuild/clear), missing **and** offline-volume detection, exact **and** perceptual duplicate detection, on-device Vision scene tagging + face detection (人物 collection), FSEvents incremental watching, batch rename, batch capture-time shift, export, backup + health check, Places (map) view, search/filter/sort, ratings/flags/keywords/albums/smart-albums, and a Settings panel (§17). Deferred product integrations: Apple Photos import bridge, plugin system, Sparkle auto-update, and a fully-normalized keyword table (keywords are stored per-asset + FTS-indexed today).

> **Scalability status.** A 100,000-row CR3 catalog fixture is covered by real app launch, grid, indexed search, and memory checks. The current `AppState` still keeps all asset metadata resident in memory, so the PRD's 500,000-row performance tier is not yet validated; database-backed paging or projections remain required before claiming that scale.

## Build & run

Requires a Swift 6 toolchain on macOS 14+. Full Xcode is required to run XCTest;
the app itself can also build with compatible Command Line Tools.

```sh
script/build_and_run.sh build      # compile (Debug) and assemble dist/PhotoCatalog.app
script/build_and_run.sh run        # build (Release) and launch the app
script/build_and_run.sh verify     # build (Release), launch, and verify a visible window

script/build_and_run.sh selfcheck  # headless demo dataset checks
script/build_and_run.sh pipeline   # headless end-to-end import checks
./.build/debug/PhotoCatalog --selfcheck --benchmark  # optional 100k synthetic metadata benchmark
./.build/debug/PhotoCatalog --import-memory-check "/path/to/sample.CR3" 200
```

The import memory check reads the supplied image through distinct temporary
symlinks, exercises the real import pipeline without the UI, and removes its
temporary catalog afterward. It fails above 512 MiB at a file boundary or if
post-warmup growth reaches 128 MiB. It never imports into an existing catalog or
changes the original. This is a repeated-input regression check, not a full-library
or all-RAW-format performance guarantee.

Launch modes (`run`, `verify`, `logs`, `telemetry`) build the optimized Release
configuration; `build`, `selfcheck`, and `pipeline` use Debug because the checks rely on
`assert`. Set `CONFIGURATION=debug` or `CONFIGURATION=release` to override.

The script honors `SDKROOT` when set. Otherwise it probes installed macOS SDKs and
selects one compatible with the active Swift compiler, which also handles temporarily
out-of-sync Command Line Tools installations.

You can also open `Package.swift` directly in Xcode and run the `PhotoCatalog` scheme.

Photos load from the Unsplash CDN; when offline each tile shows its deterministic gradient placeholder (matching the prototype's graceful fallback).
