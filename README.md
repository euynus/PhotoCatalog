# PhotoCatalog

A native macOS photo manager and RAW editor in the mould of Lightroom Classic: a catalog to cull, organize and search your photos and videos, non-destructive RAW development, and delivery as exports, prints, slideshows, web galleries and photo books.

- **Your files stay yours.** Photos are referenced where they are, or copied into dated folders or into the catalog. Edits never touch the original files: develop settings live in the catalog, and ratings, keywords and captions also go to XMP sidecars that Lightroom, Bridge and Camera Raw read.
- **Runs on this Mac.** Face recognition, the AI masks, depth, denoise, super resolution and object removal run on Core ML models bundled in the app. Only the optional AI assistant talks to a language-model service: one you choose, and only when you use it (see [Privacy](#privacy)).
- **Native and self-contained.** SwiftUI and AppKit on system frameworks only, with no third-party code.
- **Built for large libraries.** A 500,000-photo catalog is usable about five seconds after launch.

## Highlights

- **Library** — grid, loupe, compare and survey views for culling with ratings, flags and color labels; RAW+JPEG pairs shown as one photo, stacks and auto-stacking, virtual copies, smart albums, album sets and a capture-analysis view.
- **Organizing** — keywords, people (on-device face recognition, 99.4% on the LFW benchmark), places with a map and GPX matching, exact and similar duplicates, batch rename and capture-time shifts, and XMP sidecars that round-trip with Lightroom and Bridge.
- **Import** — folders (referenced or managed), memory cards, cameras and iPhones, videos and tethered capture; imports commit in checkpoints and resume after an interruption.
- **Develop** — non-destructive RAW development on the system RAW engine: profiles, black and white, tone curve, color mixer and grading, LUTs, calibration, detail, lens corrections, lens blur, masks (gradients, brush, subject, sky, people, objects, landscape, color and luminance ranges), healing and AI object removal, crop and Upright, soft proofing, snapshots, history, and presets that exchange with Lightroom.
- **Merge and enhance** — HDR and panorama merges, AI denoise and super resolution, and round trips to Photoshop and other editors.
- **Output** — export with presets, output sharpening and watermarks; printing with printer profiles; slideshows, also as MP4 video; web galleries; photo books as PDF.
- **AI assistant** (optional) — describe photos, search with a sentence, and develop from a described look, through Anthropic, any OpenAI-compatible service, or Ollama / LM Studio on this Mac.
- **Catalog safety** — a SQLite catalog where every edit writes through and can be undone, catalog snapshots, verified full backups that restore into a new library, a task center and a health check.

Every feature in detail, and all keyboard shortcuts: [docs/features.md](docs/features.md).

## Requirements

macOS 14 or later on Apple silicon. The interface is in Simplified Chinese and English: it follows the system language (English for any language other than Chinese), or the choice in Settings → General → Language after a relaunch.

No release has been published yet; build PhotoCatalog from source as below. `script/release.sh` makes the signed, notarized release for GitHub, which updates itself, and `script/appstore.sh` the sandboxed Mac App Store edition (see [Releasing](docs/development.md#releasing)).

## Privacy

PhotoCatalog has no account, analytics or tracking, and it sends nothing about your library anywhere on its own. The network is used only for:

- **The AI assistant**, when you use it: requests go to the service set in Settings → AI. Photos are sent only as 1024-pixel previews, describing photos asks first and shows what will be sent, and AI Adjust asks before it first sends a photo off this Mac. A service on this Mac (Ollama, LM Studio) keeps everything local.
- **Maps**: the Places view and the location picker load Apple Maps and search places through MapKit.
- **Update checks** in the GitHub edition: PhotoCatalog → Check for Updates…, or once a day unless Settings → General → Check for Updates Automatically is off, reads the latest release from GitHub's API. The Mac App Store edition leaves updating to the App Store.

Faces, scene tags, masks and enhancements are computed on this Mac. API keys are kept in the login keychain. Crash reports that macOS saves stay on the Mac. `Resources/PrivacyInfo.xcprivacy` declares no tracking and no collected data.

## Building

Requires a Swift 6 toolchain; full Xcode is needed to run XCTest.

```sh
script/build_and_run.sh run        # build (Release) and launch the app
script/build_and_run.sh build      # compile (Debug) and assemble dist/PhotoCatalog.app
script/build_and_run.sh selfcheck  # headless demo-dataset and per-feature checks
script/build_and_run.sh pipeline   # headless end-to-end import checks
swift test                         # model, AppState and UI-helper tests
```

Tests and benchmarks, continuous integration, adding UI text, the architecture, the bundled models and releasing are covered in [docs/development.md](docs/development.md); coding agents start from [AGENTS.md](AGENTS.md).

## License

Copyright © 2026 euynus. PhotoCatalog is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License, version 3, as published by the Free Software Foundation. It comes with no warranty; see [LICENSE](LICENSE) for the full terms.

The Core ML models bundled in `Resources/Models` keep their own licenses (BSD 3-Clause and Apache 2.0); see [Resources/Models/LICENSES.md](Resources/Models/LICENSES.md). The website's screenshots show sample photos from Unsplash under the Unsplash License; see [site/shots/CREDITS.md](site/shots/CREDITS.md).
