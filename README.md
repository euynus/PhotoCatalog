# PhotoCatalog Mac

A native **SwiftUI macOS app** that implements the **PhotoCatalog Mac** design — a local-first, non-destructive photo-original manager in the spirit of Lightroom's Library module.

This repository realises two inputs:

- **The design** exported from Claude Design (`PhotoCatalog Mac.html` + its React/CSS prototype) — the source of truth for the visual system and interactions.
- **The PRD** (`docs/macos_photo_manager_prd_tech.md`) — the product/technical spec that defines the domain model, architecture layering, and feature scope.

The HTML/React files were prototypes; this app re-creates them faithfully in native SwiftUI/AppKit, the technology the PRD calls for (§8: Swift, SwiftUI + AppKit).

## What's implemented

A clickable, dark-mode macOS app with the amber accent (`#ff9f0a`) and the full screen set from the design:

- **Main window** — custom titlebar/toolbar, optional filter bar, translucent sidebar, photo grid, 4-tab Inspector, status bar.
- **Sidebar** — 资料库 (全部 / 最近导入 / 未评分 / 精选 / 被拒绝 / 缺失·离线 / 重复文件), 文件夹, 相册, 智能相册, 关键词 — all with live counts.
- **Grid view** — adjustable thumbnail size, RAW/HEIC & offline/missing badges, color labels, flags, star ratings, multi-select.
- **Loupe** — single-photo view with bottom HUD and a filmstrip of the current collection.
- **Compare** — 2–4 photos side by side, per-photo rating/flags, "选为最佳" winner.
- **Inspector** — Info / Metadata (EXIF + GPS map) / Organize (rating, flags, color, keywords, title, caption) / History.
- **Smart Album builder** — AND/OR rule rows with a live match-count preview.
- **Duplicate detection** — exact (content-hash) & perceptual groups with keep-one resolution.
- **Import / scan** — animated scan→import progress with a 5-stat panel and a thumbnail wall.
- **First-launch / Welcome** — catalog creation card with recents.
- **Interactions** — click / ⌘-click / ⇧-click selection, live search, filter bar, sort, toasts, and keyboard shortcuts:
  `1–5` rate · `0` clear · `P/X/U` flags · `6–9` color · `G/E/C` views · `⌘F` search · `⌘I` inspector · arrows navigate · `⌫` remove.

### Real catalog backend (PRD Infrastructure layer, §11)

Beyond the UI, the app has a working file→catalog pipeline:

- **Add folder import** (toolbar 导入) — `NSOpenPanel` → recursive scan → real EXIF/GPS metadata (Image I/O) → thumbnail + preview generation (sharded disk cache) → content/quick hashing → persisted to a real `.photolibrary` catalog.
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

> **Implemented vs. remaining (vs. PRD).** Done: catalog persistence (SQLite + FTS5), folder authorization + recursive scan, referenced **and** managed import, Image I/O metadata, XMP sidecar read/write, thumbnail/preview generation + cache (rebuild/clear), missing **and** offline-volume detection, exact **and** perceptual duplicate detection, on-device Vision scene tagging + face detection (人物 collection), FSEvents incremental watching, batch rename, batch capture-time shift, export, backup + health check, Places (map) view, search/filter/sort, ratings/flags/keywords/albums/smart-albums, and a Settings panel (§17). Remaining (genuinely external/deferred): Apple Photos import bridge, plugin system, Sparkle auto-update, and a fully-normalized keyword table (keywords are stored per-asset + FTS-indexed today).

## Build & run

Requires Xcode 16 / Swift 6 toolchain on macOS 14+.

```sh
swift build              # compile
swift run PhotoCatalog   # launch the app

swift run PhotoCatalog --selfcheck   # headless: verify the demo dataset counts
swift run PhotoCatalog --pipeline    # headless: end-to-end real-import pipeline test
```

You can also open `Package.swift` directly in Xcode and run the `PhotoCatalog` scheme.

Photos load from the Unsplash CDN; when offline each tile shows its deterministic gradient placeholder (matching the prototype's graceful fallback).
