# DASH AVPlayer Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add AVPlayer fallback for DASH (.mpd) streams so a malformed/unplayable manifest falls back to AVPlayer instead of hard-erroring.

**Architecture:** Wrap the existing DASH pipeline (DASHPlayerFactory → DASHStreamSession → MediaPipeline.openStream) in a do/catch. On failure, fall back to the same AVPlayer-based loading path used for local files (AVURLAsset → AVPlayerItem → replaceCurrentItem). Also exercise StreamingManager's HLS/AVPlayer support for the fallback path. Record telemetry on fallback.

**Tech Stack:** Swift, AVFoundation, Combine, os.Logger

---

## File Map

| File | Change |
|------|--------|
| `TitanPlayer/TitanPlayer/Core/Engine/PlaybackEngine.swift:83-91` | Wrap `.mpd` branch in do/catch; add AVPlayer fallback |
| `TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift:298-301` | Extend streaming attach to also cover DASH fallback |

---

## Task 1: Add do/catch and AVPlayer fallback to PlaybackEngine's .mpd branch

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Engine/PlaybackEngine.swift:83-91`

- [ ] **Step 1: Replace the unprotected .mpd block with a do/catch that falls back to AVPlayer**

Replace lines 83-91:

```swift
if url.pathExtension.lowercased() == "mpd" {
    decoderLogger.info("DASH stream detected, creating DASHPlayer for: \(url.path, privacy: .public)")
    let dashPlayer = DASHPlayerFactory.player(for: url)
    let session = try await dashPlayer.streamSession(for: url)
    decoderLogger.info("DASH stream session opened, opening stream in MediaPipeline")
    await mediaPipeline?.openStream(session: session)
    self.mediaInfo = mediaPipeline?.mediaInfo
    decoderLogger.info("DASH stream loaded, state set to ready")
    self.state = .ready
}
```

With:

```swift
if url.pathExtension.lowercased() == "mpd" {
    decoderLogger.info("DASH stream detected, creating DASHPlayer for: \(url.path, privacy: .public)")
    do {
        let dashPlayer = DASHPlayerFactory.player(for: url)
        let session = try await dashPlayer.streamSession(for: url)
        decoderLogger.info("DASH stream session opened, opening stream in MediaPipeline")
        await mediaPipeline?.openStream(session: session)
        self.mediaInfo = mediaPipeline?.mediaInfo
        decoderLogger.info("DASH stream loaded, state set to ready")
        self.state = .ready
    } catch {
        decoderLogger.warning("DASH pipeline failed (\(error.localizedDescription, privacy: .public)), falling back to AVPlayer compatibility mode")
        self.mediaPipelineError = error
        self.mediaInfo = nil
        self.compatibilityMode = true
        TelemetryManager.shared.record(.compatibilityModeActivated(
            reason: error.localizedDescription,
            source: .dash
        ))

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        guard !videoTracks.isEmpty || !audioTracks.isEmpty else {
            decoderLogger.error("No playable tracks found in DASH fallback for: \(url.path, privacy: .public)")
            throw PlaybackError.noPlayableTracks
        }

        let durationValue = try await asset.load(.duration)
        self.duration = CMTimeGetSeconds(durationValue)

        self.currentLoadURL = url
        self.itemStatusCancellable = item.publisher(for: \.status)
            .removeDuplicates()
            .sink { [weak self] status in
                guard let self else { return }
                switch status {
                case .readyToPlay:
                    guard self.state != .ready else { return }
                    self.duration = CMTimeGetSeconds(item.duration)
                    self.decoderLogger.info("AVPlayerItem.status became .readyToPlay for DASH fallback \(url.path, privacy: .public)")
                    self.state = .ready
                case .failed:
                    let error = item.error as NSError?
                    let osStatus = OSStatus(error?.code ?? -1)
                    self.decoderLogger.error("""
                    AVPlayerItem.status became .failed for DASH fallback \(url.path, privacy: .public):
                      NSError: \(error?.description ?? "nil", privacy: .public)
                      UserInfo: \(error?.userInfo.description ?? "nil", privacy: .public)
                      OSStatus: \(osStatus)
                    """)
                    self.state = .error("Cannot Open: OSStatus \(osStatus)")
                    self.lastError = .assetLoadFailedWithStatus(
                        osStatus,
                        error ?? NSError(domain: "PlaybackEngine", code: -1)
                    )
                    TelemetryManager.shared.record(.playbackFailed(
                        codec: "unknown",
                        resolution: "unknown",
                        errorCode: "OSStatus \(osStatus)",
                        source: .dash
                    ))
                default:
                    break
                }
            }
        self.player.replaceCurrentItem(with: item)
        decoderLogger.info("DASH fallback: AVPlayerItem set on AVPlayer")
    }
}
```

- [ ] **Step 2: Verify build compiles**

Run: `cd TitanPlayer && swift build 2>&1 | tail -20`
Expected: Build succeeds with no errors.

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Engine/PlaybackEngine.swift
git commit -m "feat: add AVPlayer fallback for DASH .mpd streams

Wrap the DASH pipeline in do/catch. On failure, fall back to
AVURLAsset/AVPlayerItem with compatibilityMode = true. Records
telemetry via .compatibilityModeActivated with .dash source."
```

---

## Task 2: Extend PlaybackSession streaming attach for DASH fallback

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift:298-301`

- [ ] **Step 1: Add streaming.load and streaming.attach for DASH fallback**

Replace lines 298-301:

```swift
if url.pathExtension.lowercased() == "m3u8" {
    streaming.load(url: url)
    streaming.attach(player: engine.avPlayer)
}
```

With:

```swift
if url.pathExtension.lowercased() == "m3u8" || engine.compatibilityMode {
    streaming.load(url: url)
    streaming.attach(player: engine.avPlayer)
}
```

- [ ] **Step 2: Verify build compiles**

Run: `cd TitanPlayer && swift build 2>&1 | tail -20`
Expected: Build succeeds with no errors.

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift
git commit -m "feat: exercise streaming attach for DASH fallback path

When compatibilityMode is active (DASH fallback to AVPlayer),
also call streaming.load(url:) and streaming.attach(player:)
so HLS/manifest AVPlayer support is exercised."
```

---

## Verification

After both tasks:

1. `swift build` passes cleanly
2. A malformed .mpd URL triggers the fallback path (visible in logs: "DASH pipeline failed … falling back to AVPlayer compatibility mode")
3. `compatibilityMode` is `true` after fallback
4. Telemetry `.compatibilityModeActivated` is recorded with `.dash` source
5. The existing successful DASH path remains untouched (no regression)
