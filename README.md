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

## Architecture

Mirrors the PRD's layering (§11) with business logic separated from UI:

```
Sources/PhotoCatalog/
  Theme/            design tokens (ported from styles.css :root) + SF Symbol icon map
  Domain/           Asset, Album, SmartRule + matcher  (the assets/albums schema, §10)
  Data/             deterministic demo dataset (port of data.jsx) + headless self-check
  Application/      AppState — selection, filters, sort, mutations, keyboard
  Presentation/
    Components/      cached remote Thumb (gradient fallback), atoms, flow layout
    MainWindow/      titlebar, filter bar, status bar, main layout, root + key handling
    Sidebar/ Grid/ Inspector/ Loupe/ Compare/ Sheets/
```

The demo dataset is a **bit-faithful port** of the prototype's generator: the same Unsplash photo IDs and the exact same seeded-RNG call sequence, so the deterministic counts match the design mock (44 photos; folders 24 / 12 / 8; smart albums 13 & 12; etc.).

> Scope note: like the prototype, this is the **presentation + interaction layer** over an in-memory demo catalog. The PRD's infrastructure (GRDB/SQLite persistence, security-scoped bookmarks, real FSEvents scanning, Quick Look thumbnailing) is intentionally stubbed with realistic demo data — the domain models and `AppState` are shaped so those services can be dropped in behind the same interfaces.

## Build & run

Requires Xcode 16 / Swift 6 toolchain on macOS 14+.

```sh
swift build              # compile
swift run PhotoCatalog   # launch the app

swift run PhotoCatalog --selfcheck   # headless: verify the demo dataset counts
```

You can also open `Package.swift` directly in Xcode and run the `PhotoCatalog` scheme.

Photos load from the Unsplash CDN; when offline each tile shows its deterministic gradient placeholder (matching the prototype's graceful fallback).
