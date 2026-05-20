# Smart Picks

An on-device iOS app that finds duplicate and near-duplicate photos in your library and helps you keep the best one — guided by your personal taste, learned from your Favorites album.

Everything runs on the device. No photos, fingerprints, or metadata ever leave the phone.

## What it does

1. Reads your Favorites album to learn what you like — categorized by subject (selfies, group photos, pets, nature, food, documents, misc).
2. Scans the rest of your library in batches and computes a compact visual fingerprint for every image.
3. Groups visually similar photos into "stacks" — burst shots, near-duplicates, retries of the same scene.
4. Ranks every photo in a stack by sharpness (Laplacian variance) and how closely it matches your taste profile in its category.
5. Surfaces one **AI Pick** per stack and lets you keep it (and delete the rest) or override the pick.

## Features

- **AI Pick badge** — gradient sparkle indicator on the photo the model thinks is best.
- **Full-screen viewer** — tap the hero to open a pinch-zoom, double-tap-to-zoom, swipe-between-photos viewer at high resolution.
- **Override + restore** — tap any thumbnail to choose your own best shot; a single tap restores the AI's pick.
- **Blur warning** — orange triangle on photos below a sharpness threshold.
- **Quality readouts** — sharpness and taste-match bars on every photo.
- **Batched scanning** — 250 photos at a time so RAM never spikes on large libraries.
- **Resume between batches** — the app keeps results from earlier batches as you scan more.
- **Haptic feedback** on every meaningful action.

## How it works

### Taste profile
On first run, the app samples up to 100 photos from the Favorites album. For each one it runs `VNDetectFaceRectanglesRequest`, `VNClassifyImageRequest`, and `VNGenerateImageFeaturePrintRequest` in a single `VNImageRequestHandler.perform([...])` call — three models, one pixel decode. Photos are bucketed by category, and the feature prints become the per-category reference set.

### Scoring
A candidate photo is classified into the same category scheme, then scored against only its own bucket using **min-distance** to the closest favorite. A great selfie is no longer penalized for being unlike a landscape favorite.

### Clustering
Fingerprints are clustered with a union-find pass over a sliding chronological window (default 10 photos) using a distance threshold (default 0.35). The library is already chronologically sorted, so this captures burst sequences cheaply without an O(n²) comparison.

### Memory model
Only fingerprints (≈2 KB each) stay resident between batches. Full CGImages are loaded only for photos that survive clustering, so a 10 000-photo library uses roughly 20 MB of fingerprint state instead of gigabytes of pixel buffers.

## Project structure

```
favoritePics/
├── favoritePicsApp.swift     // App entry point
├── PermissionsView.swift     // First-run onboarding + photo access gate
├── SmartStackView.swift      // Main browser, card UI, full-screen viewer
├── SmartStackViewModel.swift // Orchestrates scanning, clustering, ranking
├── PhotoAnalyzer.swift       // Vision pipeline: classify, fingerprint, score
└── Assets.xcassets           // App icon, accent color
```

## Requirements

- iOS 26.4 or later
- Xcode 17 or later
- Swift 5
- A device or simulator with photos in the library (the simulator's stock images work fine for a smoke test)

## Build

1. Open `favoritePics.xcodeproj` in Xcode.
2. Select a simulator or a connected device.
3. Run.

On first launch the app asks for Photos read/write access. Granting **Limited Access** works — the app respects whatever scope you give it.

## Privacy

- No analytics. No network calls. No third-party SDKs.
- Photo access is read/write (write is needed to perform deletions through `PHAssetChangeRequest.deleteAssets`, which itself surfaces a system confirmation sheet).
- The taste profile and fingerprints are in-memory only — they are recomputed on each launch and never persisted to disk.
