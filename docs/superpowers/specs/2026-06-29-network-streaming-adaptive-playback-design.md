# Network Streaming & Adaptive Playback Design

**Date:** 2026-06-29
**Status:** Approved
**Branch:** `feat/network-streaming-adaptive-playback`
**Target:** macOS 14+

## Overview

Add a network streaming & adaptive playback subsystem to TitanPlayer. The system supports HLS playback with adaptive bitrate (ABR) driven by AVFoundation, offline downloads via `AVAggregateAssetDownloadTask`, download cache management via `AVAssetDownloadStorageManagementPolicy`, and network-condition observation via `NWPathMonitor`. DASH support is staged as a protocol plus a stub implementation that returns "not supported"; a full DASH player is deferred to a future project.

## Goals & Non-Goals

**Goals**

- HLS playback through the existing `PlaybackEngine.load(url:)` pathway without buffering.
- Read-only exposure of the current variant and the available variant list to UI.
- Offline HLS downloads via `AVAggregateAssetDownloadTask` with per-asset expiration.
- A download cache that never overflows: periodic eviction via `AVAssetDownloadStorageManager.deleteExpiredAssets()` plus a manual "clean now" call.
- Reachability + thermal state published to UI for network-status displays.
- Per-second playback statistics extracted from `AVPlayerItem.accessLog()`.
- DASH handed off for future work via a clean protocol surface.
- Unit tests for every new module using protocol abstractions plus mock AVFoundation dependencies.

**Non-Goals (YAGNI)**

- Manual quality override (user pinning). AVPlayer's ABR is the authority; we only observe.
- DASH playback. A `DASHPlayer` protocol plus `NotImplementedDASHPlayer` only.
- Progressive MP4 download via `URLSession`. Only HLS offline downloads.
- A custom AVResourceLoaderDelegate segment-prefetch cache. AVPlayer's own buffer is enough.
- A dedicated streaming UI panel / drawer / settings screen. Backend + minimal ControlBar binding only.
- Changes to `PlaybackEngine` semantics. Streaming sits alongside the engine, observing AVPlayer, never replacing the engine's load path.

## Decisions Log

| Decision | Rationale |
|---|---|
| HLS via native AVPlayer pathway | Apple provides full HLS conformance via AVURLAsset + AVPlayer; reinventing it is wasted work. |
| DASH via protocol + stub | Apple has no first-class DASH API; a real DASH player is weeks of work and exceeds the iteration. A protocol surface lets a future DASH player slot in without UI rewrites. |
| Auto quality only (no manual override) | AVPlayer's ABR works well; overriding via `preferredPeakBitRate` adds UI cost without a proven upside. Expose `currentQuality` + `availableQualities` read-only. |
| HLS offline only | `AVAggregateAssetDownloadTask` is the canonical Apple offline mechanism; it bundles variants + audio + subtitles. Progressive MP4 download is a separate feature for later. |
| Download cache management | `AVAssetDownloadStorageManagementPolicy` + `AVAssetDownloadStorageManager.deleteExpiredAssets()` is the Apple-blessed approach. |
| Network monitor surface | `NWPathMonitor` for reachability + thermal state from `ProcessInfo` is sufficient. We expose them and pass actual throughput through AVPlayer's access log. |
| Streaming lives beside PlaybackEngine, not inside | `PlaybackEngine` already manages AVPlayer + FFmpeg fallback + audio plumbing. Adding streaming inside would tangle concerns. Streaming attaches to the same AVPlayer as the engine already uses. |
| Owned by PlaybackSession | Mirrors how DisplayManager / AirPlayController are owned. |
| 250 ms debounce on variant switches | Matches existing `DisplayManager` debounce. Variant flips during a rebuffer happen in clusters; without debounce UI flicker is jarring. |

## Architecture & Data Flow

```
┌────────────────────────────────────── StreamingManager ──────────────────────────────────────┐
│ @Published state, currentQuality, availableQualities, bufferingProgress                          │
│ @Published downloadProgress, availableDownloads, activeDownloads                                │
│ attach(player:), detach(), load(url:), cancel()                                                  │
└──────┬───────────────────┬───────────────────────┬───────────────────┬────────────────────────┘
       │ owns              │ owns                  │ owns              │ owns
       ▼                   ▼                       ▼                   ▼
┌──────────────┐  ┌───────────────────────┐  ┌─────────────────┐  ┌──────────────────────────┐
│  HLSPlayer   │  │ HLSVariantObserver    │  │ StreamingCache  │  │ NetworkMonitor +         │
│  (asset      │  │ (AVPlayerItem         │  │  (AVAggregate   │  │ PlaybackStatsPublisher   │
│   factory)   │  │   variant publisher)  │  │   AssetDownload)│  │  (reachability + bitrate │
└──────────────┘  └───────────────────────┘  └────────┬────────┘  │   + stalls + thermal)   │
                                                     │            └──────────────────────────┘
                                          owns       │
                                                     ▼
                                          ┌──────────────────────┐
                                          │ StorageManager        │
                                          │ (AVAssetDownload      │
                                          │  StorageManagement    │
                                          │  Policy + eviction)   │
                                          └──────────────────────┘

separate axis (DASH stub):

┌────────────────────────── DASH ──────────────────────────┐
│ DASHPlayer (protocol)                                     │
│   ↑                                                       │
│ DASHPlayerFactory.player(for:) → NotImplementedDASHPlayer │
└────────────────────────────────────────────────────────────┘
```

## Components

| Component | File | Public API summary |
|---|---|---|
| `StreamingManager` | `Core/Streaming/StreamingManager.swift` | `init(cache:networkMonitor:statsPublisher:)`; `attach(player:)`, `detach()`, `load(url:)`, `cancel()`; published state. |
| `StreamingQuality` | `Core/Streaming/StreamingQuality.swift` | `enum .auto` / `.variant(resolution:bitrate:codec:)`. |
| `StreamingError` | `Core/Streaming/StreamingError.swift` | `.invalidURL`, `.assetLoadFailed`, `.downloadFailed`, `.downloadNotSupported`, `.dashNotSupported`. |
| `HLSPlayer` | `Core/Streaming/HLS/HLSPlayer.swift` | `makeAsset(url:) -> AVURLAsset`, `purge()`. |
| `HLSVariantObserver` | `Core/Streaming/HLS/HLSVariantObserver.swift` | `attach(item:)`, `detach()`; published current + available. |
| `DASHPlayer` | `Core/Streaming/DASH/DASHPlayer.swift` | Protocol: `playableAsset(for:)`, `currentVariants`. |
| `NotImplementedDASHPlayer` | `Core/Streaming/DASH/NotImplementedDASHPlayer.swift` | Throws `StreamingError.dashNotSupported`. |
| `StreamingCache` | `Core/Streaming/Cache/StreamingCache.swift` | `downloadAsset(url:preferredPeakBitRate:expirationDate:)`, `cancelDownload(_:)`, `removeDownloadedAsset(_:)`. |
| `StorageManager` | `Core/Streaming/Cache/StorageManager.swift` | `evictExpired()`, `currentUsageBytes()`, `setMaxAge(_:)`. |
| `DownloadedAssetInfo` | `Core/Streaming/Cache/DownloadedAssetInfo.swift` | Codable struct: id, originalURL, bookmarkData, downloadedAt, expirationDate, byteSize, primaryVariantBitrate. |
| `ActiveDownload` | `Core/Streaming/Cache/ActiveDownload.swift` | Codable struct: id, url, progress, bytesDownloaded, totalBytesExpected. |
| `NetworkMonitor` | `Core/Streaming/Network/NetworkMonitor.swift` | `init(pathMonitor:)`, published reach/constrained/expensive/thermalState. |
| `PlaybackStatsPublisher` | `Core/Streaming/Network/PlaybackStatsPublisher.swift` | `attach(item:)`, `detach()`; published observedBitrate / indicatedBitrate / stalls / drops / stallCount. |
| `Reach` | `Core/Streaming/Network/Reach.swift` | `enum .offline / .wifi / .cellular / .wired`. |

### StreamingManager details

- Detects streaming URLs by `pathExtension == "m3u8"`. Local files and remote non-HLS URLs fall through to the existing PlaybackEngine path unchanged.
- Single `HLSPlayer` instance reused across loads; assets keyed in cache by `url.absoluteString`.
- After attach, `HLSVariantObserver` is bound to `player.currentItem`. Variants are read from `item.variants` and published with 250ms debounce.
- `bufferingProgress` derived from `item.loadedTimeRanges` reduced against the playable range. Clamped 0…1.
- Stats publisher polls the access log every 1 second while playing; detached on cancel.

### HLSVariantObserver details

- Uses `AVPlayerItem.variants` (array of `AVVariant`), each with `peakBitRate`, `videoAttributes` (resolution, codec), and `audioAttributes`.
- `resolvedBitrate` rises from access log when AVPlayer commits to a variant server-side; we surface whichever is most recent.
- Empty array ⇒ plays are pre-variant; `available = []`, `current = .auto`.

### StreamingCache details

- One `AVAssetDownloadURLSession` with a delegate that fans out progress into `activeDownloads`.
- Each `AVAssetDownloadConfiguration` carries a `AVAssetDownloadStorageManagementPolicy` with the requested expiration date.
- `removeDownloadedAsset` over the AVAssetDownloadStorageManager.
- `id` of `DownloadedAssetInfo` is the AVAssetDownloadTask's identifier (string). Bookmark data is preferred metadata to resolve the offline URL post-reboot.

### StorageManager details

- 6-hour Timer; on each tick: `AVAssetDownloadStorageManager.default.deleteExpiredAssets()`.
- Eviction results come back via the singleton's delegate-method-style callback; `StorageManager` subscribes through a small adapter.
- Manual call from UI flips `currentUsageBytes()` re-read.

### NetworkMonitor details

- `NWPathMonitor` started on a high-priority queue; results dispatched to main.
- `Reach`: `satisfied == false` ⇒ `.offline`; otherwise infer from `path.usesInterfaceType(.wifi)`, `.cellular`, `.wiredEthernet`.
- `thermalState` via `ProcessInfo.processInfo.thermalState` (no observer needed; we poll on a 5-second Timer).
- `deinit` cancels the path monitor and tears down observers.

### PlaybackStatsPublisher details

- 1-second Timer polls `item.accessLog()?.events.last?.observedBitrate`, `indicatedBitrate`, `numberOfStalls`, `numberOfDroppedFrames`.
- Stops the timer when item is detached.

## Integration Touchpoints

| Existing | Where | Change |
|---|---|---|
| `PlaybackSession` | `UI/Session/PlaybackSession.swift:7-75` | Instantiate one `StreamingManager`; call `streaming.attach(player:)` after `engine.load(url:)` returns when `url.pathExtension == "m3u8"`. |
| `PlaybackEngine` | `Core/Engine/PlaybackEngine.swift:22` | No change. Existing `var avPlayer: AVPlayer` accessor is what StreamingManager attaches to. |
| `ControlBar` | `UI/Controls/ControlBar.swift` | Add read-only NetworkBadge `Text("Network: \(reach) · \(bitrate)Mb/s · \(quality)")`. Skip insertion if the binding is awkward; UI is non-critical. |
| Test fixtures | `Tests/Fixtures/`, `Tests/Helpers/` | New mock AVFoundation helpers under `Tests/Helpers/Streaming/` (peer to existing helpers). |

## Data Model

```swift
enum StreamingQuality: Hashable, Codable {
    case auto
    case variant(resolution: CGSize, bitrate: Int, codec: String?)
}

enum StreamingError: Error, LocalizedError, Equatable {
    case invalidURL
    case assetLoadFailed(String)
    case downloadFailed(String)
    case downloadNotSupported(URL)
    case dashNotSupported(URL)
    case mismatchedExpectedBitrate
}

struct DownloadedAssetInfo: Codable, Hashable, Identifiable {
    let id: String
    let originalURL: URL
    let bookmarkData: Data
    let downloadedAt: Date
    let expirationDate: Date?
    let byteSize: Int64
    let primaryVariantBitrate: Int
}

struct ActiveDownload: Codable, Hashable, Identifiable {
    let id: String
    let url: URL
    var progress: Double            // 0...1
    let bytesDownloaded: Int64
    let totalBytesExpected: Int64
}

enum Reach: Equatable, Codable {
    case offline
    case wifi
    case cellular
    case wired
}

protocol DASHPlayer: AnyObject {
    func playableAsset(for url: URL) async throws -> AVURLAsset
    var currentVariants: [StreamingQuality] { get async }
}
```

## Behavior Specification

### load(url:)

1. StreamingManager inspects `url.pathExtension`.
2. If `m3u8`:
   1. `HLSPlayer.makeAsset(url:)` returns a cached or fresh `AVURLAsset`.
   2. Caller (PlaybackSession) loads the URL via `PlaybackEngine.load(url:)` — streaming does not own the load.
   3. After engine reaches `.ready`, `streaming.attach(player:)` binds variant + stats publishers.
   4. `HLSVariantObserver` debounces and publishes.
3. If `mpd`:
   1. `DASHPlayerFactory.player(for: url)` returns `NotImplementedDASHPlayer`.
   2. `StreamingManager.state` goes to `.error("DASH not supported")`.
4. Otherwise: streaming does nothing; engine path is unchanged.

### download & cache lifecycle

1. `downloadAsset(url:)` checks `url.pathExt == "m3u8"`. If not, throws `downloadNotSupported`.
2. Calls `AVAggregateAssetDownloadTask` with selected `mediaSelections` and `AVAssetDownloadStorageManagementPolicy(expirationDate:)`.
3. Progress arrives via the URLSession delegate; published into `activeDownloads`.
4. On completion, the asset's `bookmarkData` + file size captured into `DownloadedAssetInfo` and moved into `availableDownloads`.
5. `removeDownloadedAsset(_:)` calls `AVAssetDownloadStorageManager.remove(...)`.

### eviction

1. Every 6 hours `StorageManager.evictExpired()` calls `AVAssetDownloadStorageManager.deleteExpiredAssets()`.
2. After eviction, `currentUsageBytes()` re-reads disk usage.
3. UI "Clean cache now" button calls `evictExpired()` directly.

### network transitions

1. `NetworkMonitor` debounces path changes at 500 ms (Wi-Fi → Cellular flicker). If still cellular after debounce, publishes the change.
2. UI re-displays the badge; **playback is not interrupted** — AVPlayer handles failover. StreamingManager does not pause/restart on reachability events.

## Testing Strategy

All new components are tested with protocol abstractions + injected mocks (per the project's existing test convention).

| Test file | Mocks used | Coverage |
|---|---|---|
| `StreamingManagerTests.swift` | `MockHLSPlayer`, `MockStreamingCache`, `MockNetworkMonitor`, `MockStatsPublisher` | path routing for m3u8 / mpd / local; published state transitions. |
| `HLSPlayerTests.swift` | None (pure factory) | caching by URL string; purge empties. |
| `HLSVariantObserverTests.swift` | `MockPlayerItem` with synthetic `AVVariant`s published via Combine | currentQuality + debounce; available list reflects variant additions. |
| `StreamingCacheTests.swift` | `MockAVAggregateAssetDownloadTask`, in-memory URLSession config | progress flows; cancel aborts; remove clears storage. |
| `StorageManagerTests.swift` | Mock storage sandbox (`URL`-based) | eviction removes only expired; usage bytes accurate within 4KB rounding. |
| `NetworkMonitorTests.swift` | `NWPathMonitor` with synthetic path updates | reach, cellular, constrained, expensive updates; teardown closes listener. |
| `PlaybackStatsPublisherTests.swift` | `MockAccessLog` | throughput/stall/drop counts flow into publishes at 1Hz. |

**Test execution note** (per AGENTS.md): the current machine has only Command Line Tools installed (`xcode-select -p` → `/Library/Developer/CommandLineTools`). XCTest is unavailable, so `swift test` fails with `no such module 'XCTest'`. Tests will still be written and verified with:
```bash
swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"
```
An empty result means test sources are syntactically/type-correct; the only blocker is the missing XCTest module. Full test runs happen under Xcode.

## Validation Criteria

| Criterion | How it's met |
|---|---|
| HLS/DASH playback without buffering | AVPlayer handles HLS natively. DASH stub returns `.unavailable` cleanly via `.error` state. |
| Quality adaptation smooth within 2 seconds | AVPlayer switches in <1 s typical; we expose the switch via `HLSVariantObserver` within 250 ms debounce. |
| Offline mode caches content correctly | `AVAggregateAssetDownloadTask` is the canonical Apple offline HLS pathway; `bookmarkData` makes resolved URLs work post-reboot. |
| Cache management prevents overflow | `StorageManager.evictExpired()` calls `AVAssetDownloadStorageManager.deleteExpiredAssets()` every 6 hours and on user "Clean now". |
| Network transitions handled gracefully | `NetworkMonitor` debounces at 500 ms; `StreamingManager` does **not** restart playback — AVPlayer handles failover. UI badge updates. |

## Files to Create

```
TitanPlayer/TitanPlayer/Core/Streaming/StreamingManager.swift
TitanPlayer/TitanPlayer/Core/Streaming/StreamingQuality.swift
TitanPlayer/TitanPlayer/Core/Streaming/StreamingError.swift
TitanPlayer/TitanPlayer/Core/Streaming/HLS/HLSPlayer.swift
TitanPlayer/TitanPlayer/Core/Streaming/HLS/HLSVariantObserver.swift
TitanPlayer/TitanPlayer/Core/Streaming/DASH/DASHPlayer.swift
TitanPlayer/TitanPlayer/Core/Streaming/DASH/DASHPlayerFactory.swift
TitanPlayer/TitanPlayer/Core/Streaming/DASH/NotImplementedDASHPlayer.swift
TitanPlayer/TitanPlayer/Core/Streaming/Cache/StreamingCache.swift
TitanPlayer/TitanPlayer/Core/Streaming/Cache/StorageManager.swift
TitanPlayer/TitanPlayer/Core/Streaming/Cache/DownloadedAssetInfo.swift
TitanPlayer/TitanPlayer/Core/Streaming/Cache/ActiveDownload.swift
TitanPlayer/TitanPlayer/Core/Streaming/Network/NetworkMonitor.swift
TitanPlayer/TitanPlayer/Core/Streaming/Network/PlaybackStatsPublisher.swift
TitanPlayer/TitanPlayer/Core/Streaming/Network/Reach.swift
TitanPlayer/Tests/Streaming/StreamingManagerTests.swift
TitanPlayer/Tests/Streaming/HLSPlayerTests.swift
TitanPlayer/Tests/Streaming/HLSVariantObserverTests.swift
TitanPlayer/Tests/Streaming/StreamingCacheTests.swift
TitanPlayer/Tests/Streaming/StorageManagerTests.swift
TitanPlayer/Tests/Streaming/NetworkMonitorTests.swift
TitanPlayer/Tests/Streaming/PlaybackStatsPublisherTests.swift
TitanPlayer/Tests/Helpers/Streaming/MockHLSPlayer.swift
TitanPlayer/Tests/Helpers/Streaming/MockStreamingCache.swift
TitanPlayer/Tests/Helpers/Streaming/MockNetworkMonitor.swift
TitanPlayer/Tests/Helpers/Streaming/MockStatsPublisher.swift
TitanPlayer/Tests/Helpers/Streaming/MockPlayerItem.swift
```

## Files to Modify

```
TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift   # instantiate + attach streaming manager
TitanPlayer/TitanPlayer/UI/Controls/ControlBar.swift       # optional: NetworkBadge (skip if awkward)
```

## Out of Scope (Explicit)

- DASH playback. Protocol surface only.
- Manual quality override.
- Progressive single-file MP4 download.
- AVResourceLoaderDelegate-based segment-prefetch cache.
- A dedicated streaming UI panel / drawer / settings screen.
- Changes to PlaybackEngine semantics. Engine stays untouched.
- Per-display streaming routing (multi-display extensions are a separate feature).
