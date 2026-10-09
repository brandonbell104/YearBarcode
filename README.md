# Year Barcode

**Your year, in color.** Year Barcode turns the average color of every photo you took in a year into printable barcode art. Analysis, filtering, preview and PNG export all happen on the phone. There are no accounts, no uploads, and no servers.

This repository implements the **V1 specification (October 9, 2026)** for iPhone: steps 1–5 of the spec's implementation order. The Android port (step 6) is not started; it should reuse the same logical rules from `YearBarcodeCore`.

## Layout

```
Packages/YearBarcodeCore/    Platform-independent rules (Swift package, also builds on Linux)
  Color.swift                sRGB <-> linear light, equal-weight color sums
  YearCalendar.swift         Day partitioning in the job's saved time zone, Every-Day slots
  Snapshot.swift             Generate-time snapshot: cutoff, year range, missing/invalid dates
  FilterPolicy.swift         Conservative exclusion decisions from on-device signals
  Duplicates.swift           Fingerprints + deterministic duplicate suppression
  Grouping.swift             Every Photo capped-proportional grouping, Every Day slots, stripe boundaries
  Layout.swift               Poster geometry for 3 sizes × 2 orientations, label/watermark/photo slots
  Renderer.swift             Scanline compositor (bounded memory)
  PNGWriter.swift            Streaming PNG encoder (zlib, sRGB + 300 PPI pHYs, no EXIF)
  Report.swift               Counts, included photos, plain-language status text
  Job.swift                  Job states, interruption reasons, launch recovery
  BorderPhoto.swift          Optional border photo crop math
App/Sources/                 iOS app (SwiftUI, PhotoKit, Vision, StoreKit 2, SQLite)
  Library/                   PhotoKit enumeration, revisions, renditions (incl. iCloud)
  Analysis/                  64×64 color sample, 1024 px Vision filtering pass
  Storage/                   SQLite: generation, manifest, photo_analysis, artwork
  Engine/                    Resumable job engine + BGContinuedProcessingTask runner
  Export/                    Preview and full-resolution PNG rendering, labels, border photos
  Store/                     Non-consumable watermark removal (purchase, pending, restore, refunds)
  Views/                     Welcome, Years, Progress, Artwork, Customize/Export
project.yml                  XcodeGen project definition
```

## Building

Requirements: Xcode 26 (iOS 26 SDK), [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate
open YearBarcode.xcodeproj
```

The `YearBarcode` scheme uses `App/StoreKit/Products.storekit`, so you can test the purchase locally without App Store Connect. Change `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` and the product ID in `PurchaseManager.swift` to match your App Store Connect setup.

Core rules have their own tests:

```sh
cd Packages/YearBarcodeCore
swift test
```

CI (`.github/workflows/ci.yml`) runs the core tests on Linux and macOS and builds the app for the iOS Simulator.

## Installing without a Mac (TestFlight)

`.github/workflows/testflight.yml` builds the app on a GitHub-hosted Mac, signs it with an Apple-managed (cloud) distribution certificate and uploads it to App Store Connect. Set the four secrets listed at the top of that file, run the **TestFlight** workflow from the Actions tab, then install the build with the TestFlight app on your iPhone.

## How the spec maps to code

| Spec requirement | Where |
| --- | --- |
| Snapshot at Generate: cutoff, time zone, settings, manifest with revisions; later photos never join | `SnapshotBuilder.build`, `GenerationEngine.createGeneration`, `manifest` table |
| Capture date only; missing/invalid dates skipped and counted; no future years | `SnapshotBuilder`, `availableYears` |
| Deleted/edited before analysis → unavailable/changed, reported | `GenerationEngine.analyze`, `GenerationCounts` |
| Every Photo: one stripe per photo, or exactly K groups, never across days, capped proportional allocation, largest remainders with chronological ties | `Grouper.everyPhoto`, `Grouper.allocate`, `Grouper.partition` |
| Every Day: 365/366 slots or Jan 1 to cutoff; empty days white | `YearCalendar.daySlots`, `Grouper.everyDay` |
| Linear-light averaging with sums and counts | `ColorSum`, `ColorAverager` |
| Barcode 90% × 75%, K = floor(length / 2), stripes ≥ 2 px | `PosterLayout`, `StripeGeometry.boundaries` |
| Year top, count bottom, watermark below barcode, 0–4 photo slots, no overlap in either orientation | `PosterLayout.photoSlots`, `RenderTests` |
| Change mode/size/orientation from cached analysis | `GenerationReport.barcode(for:)`, `ArtworkSession.update` |
| Preview first; full PNG only on Save/Share; sRGB + 300 PPI; no source metadata; bounded memory | `ArtworkRenderer`, `ScanlineRenderer`, `StreamingPNGWriter` |
| Filters: screenshots, bursts, documents, memes, downloaded, duplicates; still images only | `PhotoAnalyzer`, `FilterPolicy`, `DuplicateResolver`, `PhotoLibraryService.stillImageOptions` |
| Cache by asset, revision, analysis version | `photo_analysis` table, `Versions.analysis` |
| Resumable job, checkpoints, pause/cancel/resume, truthful interruption states | `GenerationEngine`, `JobRunner`, `JobTransitions` |
| iOS 26 BGContinuedProcessingTask, submitted from the foreground on Generate | `JobRunner.submitContinuedProcessing` |
| Watermark unlock: non-consumable, verified entitlement, pending, restore, refunds | `PurchaseManager` |

## Decisions and known limitations

- **Capture date** is `PHAsset.creationDate`. PhotoKit sets it from the photo's original capture metadata when present; there is no public flag that tells capture time apart from import time.
- **Revision.** PhotoKit has no public revision number. The app uses adjustments, pixel size and (for edited photos) modification date. Favoriting an unedited photo is not treated as an edit.
- **Filtering is best effort.** No trained model is bundled. Documents use Vision text coverage, document segmentation and `VNClassifyImageRequest`. Memes need a classifier, so without one they are rarely excluded. To use a model, drop `YearBarcodeFilter.mlmodelc` (labels such as `photo`, `document`, `meme`, `screenshot`) into the app bundle and `BundledClassifier` loads it. Tune the thresholds in `FilterPolicy` against a varied test set from people who have agreed to share their photos.
- **Downloaded images.** iOS has no reliable provenance flag. Camera EXIF counts as proof of a camera. Missing EXIF plus a web format (GIF or WebP) is the only combination strong enough to exclude a photo. Files that are only in iCloud keep `unknown` provenance, so these photos are kept.
- **Duplicates** use exact sample hashes anywhere in the year, or a near-identical difference hash plus color within 2 minutes. The earliest photo, then the lowest asset ID, is kept.
- **Layout constants** (border proportions, label heights, slot sizes) are the spec's proposed V1 values. They are tunable in `PosterLayout`. Landscape border photos sit in one row between the watermark and the count. Portrait border photos alternate left and right in the side borders.
- **Price.** The local StoreKit config uses US$1.99, the nearest standard price point to $2. The app always shows the store's localized price.
- **Android** (Compose/MediaStore/ML Kit/WorkManager) and the choice of server for verifying Play payments are not started yet.

## Device QA checklist (from the spec's acceptance criteria)

- [ ] Take a photo after tapping Generate: it must not appear. Missing-date and limited-access counts are visible.
- [ ] 2024 Every Day has 366 slots. The current year ends at the cutoff day. Empty days are white.
- [ ] A library of more than 4,860 photos on 24×36 shows "Some photos were grouped to fit this poster."
- [ ] Exported PNG sizes: 5400×3600, 7200×5400, 10800×7200 (and portrait). Labels, watermark and 4 cropped photos do not overlap.
- [ ] Interrupt with airplane mode, revoking access, locking the device, cancelling from the system UI, and force-quitting. Each must show a truthful state and Resume must continue from the checkpoint.
- [ ] Measure peak memory and battery during a 24×36 export on the lowest-memory supported iPhone.
- [ ] Purchase, Ask to Buy (pending), refund (revocation) and restore. The watermark disappears from new renders without rescanning photos.
