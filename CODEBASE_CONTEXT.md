# CODEBASE_CONTEXT.md

## 1. Project Identity
- Last verified: 2026-07-03
- One-sentence purpose: macOS video player with HDR rendering, spatial audio, adaptive performance management, and real-time video analysis tools.
- Domain / industry: Media playback / video player
- Target users: macOS power users interested in HDR playback, spatial audio, and video analysis (histogram/vectorscope/waveform)
- Primary languages: Swift (100%), Metal Shading Language
- Frameworks & major libraries: SwiftUI (AppKit/NSViewRepresentable), AVFoundation, Metal, AVFAudio, CoreAudio, Accelerate, NWPathMonitor, simd, Combine, FFmpeg (via external `FFmpegBuild` package providing Libavcodec/libavformat/libavutil/libswscale)
- Build / package tooling: SwiftPM 5.9, XcodeGen (`project.yml`), Fastlane (`fastlane/`)
- Repo root path / name: `<local clone path>/TitanPlayer` — TitanPlayer

## 2. Repository Map
- `Benchmarks/` — Standalone SwiftPM package for benchmarking (has own `Tests/` and `Sources/`) [Benchmarks/Package.swift]
- `Tests/` — Top-level (non-SwiftPM) test directory containing `AudioTests/`, `Integration/`, `Unit/` [Tests/]
- `docs/` — Design specs and plans under `superpowers/specs/` and `superpowers/plans/` [docs/superpowers/]
- `scripts/` — Build/CI helper scripts [scripts/]
- `.github/` — GitHub Actions CI workflow definitions [.github/workflows/]
- `fastlane/` — Fastlane iOS/macOS deployment configuration [fastlane/]
- `TitanPlayer/` — SwiftPM package root:
  - `Package.swift` — Defines executable target `TitanPlayer` and test target `TitanPlayerTests`
  - `TitanPlayer/` — Main app source: `Core/`, `UI/`, `Subtitles/`, `Resources/`
  - `Resources/` — Metal shaders (`Shaders/`), asset catalog, app icon
  - `Tests/` — Unit and integration tests with fixture media
- `TitanPlayerUITests/` — UI integration tests (`UI/`, `Helpers/`)
- `TitanPlayer.xcodeproj/` — Xcode project (XcodeGen-generated)

## 3. Entry Points
- `TitanPlayerApp` | TitanPlayer/TitanPlayerApp.swift:4 | SwiftUI `@main` App struct — launches main window with `ContentView`, mini player window, and library window; registers `PlaybackSession` as environment object. Triggered by macOS app launch.
- `AppDelegate.application(_:open:)` | UI/AppDelegate.swift:5 | Handles file-open events from macOS (double-click media file, drag to dock icon). Triggered by macOS `open` URL event.

## 4. Architecture Overview
- Architectural style: Modular monolith (single macOS app, strongly separated internal modules via protocols)
- Component list:
  - **PlaybackSession** — Central observable facade owned by the SwiftUI view hierarchy; owns the engine, renderer, display manager, streaming manager, analysis manager, performance optimizer, keyboard shortcuts. [UI/Session/PlaybackSession.swift:7]
  - **PlaybackEngine** — AVPlayer-based playback with time observation, pause/play/seek/rate, AVPlayerItem lifecycle, audio clock sync. [Core/Engine/PlaybackEngine.swift:7]
  - **MediaPipeline** — Alternative (non-AVPlayer) pipeline: demuxes via FFmpeg or AVFoundation, decodes frames, routes to video/audio renderers. [Core/Engine/MediaPipeline.swift:6]
  - **MetalRenderer** — MTKView delegate; full-screen-quad rendering with HDR tone mapping (compute shader), YCbCr->RGB conversion, ICC profile color transform, resolution caps. [Core/Renderers/MetalRenderer.swift:6]
  - **AudioEngine** — Spatial audio engine built on AVAudioEngine with head tracking, HRTF processing, room simulation, custom CoreAudio bridge. [Core/Engine/Audio/AudioEngine.swift:65]
  - **AVAudioEngineRenderer** — Simple AudioRenderer conformer wrapping AVAudioEngine+AVAudioPlayerNode. [Core/Engine/AudioRenderer.swift:15]
  - **AdaptiveDecoderManager** — Manages HW (VideoToolbox) vs SW (FFmpeg) decoder selection and runtime switching based on performance metrics. [Core/Decoders/VideoDecoder/Manager/AdaptiveDecoderManager.swift:14]
  - **HDRMetadataProcessor** — Parses Dolby Vision & HDR10+ metadata from sample buffers, generates per-frame tone-mapping params with transition smoothing. [Core/Renderers/HDRMetadataProcessor.swift:7]
  - **PerformanceOptimizer** — Receives system state (CPU, thermal, battery, network), feeds `AdaptiveQualityController`, applies `QualityAction` decisions to renderer/decoder/streaming. [Core/Performance/PerformanceOptimizer.swift:6]
  - **StreamingManager** — HLS playback manager wrapping AVPlayer, variant bitrate observation, streaming cache, network monitor, stats publishing. [Core/Streaming/StreamingManager.swift:26]
  - **VideoAnalysisManager** — Owns `AnalysisGPURunner` (Metal compute) and `LFSAudioMeter` (BS.1770); publishes histogram/vectorscope/waveform/color-picker. [Core/Analysis/VideoAnalysisManager.swift:11]
  - **SubtitleManager** — Parses SRT/ASS/WebVTT, tracks active subtitles, filters events by current time. [Subtitles/SubtitleManager.swift:5]
  - **DisplayManager** — Observes screen changes, detects HDR/EDR capabilities, persists display config. [UI/Session/Displays/DisplayManager.swift:50]
  - **AirPlayController** — Monitors AVPlayer external playback, computes audio delay offset. [UI/Session/Displays/AirPlayController.swift:34]
  - **KeyboardShortcutManager** — UserDefaults-backed customizable key bindings for 30 player actions. [UI/Shortcuts/KeyboardShortcutManager.swift:5]
- Request/data flow:
  1. User drops/opens file → `ContentView.handleDrop(_:)` or `AppDelegate.application(_:open:)` → `PlaybackSession.openFile(url:)` [UI/Views/ContentView.swift:23, UI/AppDelegate.swift:5]
  2. `PlaybackSession` calls `PlaybackEngine.load(url:)` which creates AVURLAsset, loads tracks, sets AVPlayerItem [Core/Engine/PlaybackEngine.swift:68]
  3. Engine dispatches to `MediaPipeline.openFile(url:)` which probes with FFmpeg, selects AVFoundation or FFmpeg backend for demuxing/decoding [Core/Engine/MediaPipeline.swift:30]
  4. Decoded frames pass through `MediaPipeline.processFrame(_:)` → `MetalRenderer.render(_:)` which writes to `FrameStore` and draws via MTKView delegate [Core/Engine/MediaPipeline.swift:112]
  5. MetalRenderer applies tone mapping (HDR compute shader), ICC color transform, brightness/contrast/saturation via fragment shader [Core/Renderers/MetalRenderer.swift]
  6. PlaybackSession bindings propagate engine state → SwiftUI views re-render; subtitle manager updates [UI/Session/PlaybackSession.swift:220]
  7. PerformanceOptimizer periodically reads system state, evaluates `AdaptiveQualityController` rules, applies actions to renderer/decoder [Core/Performance/PerformanceOptimizer.swift:54]

## 5. Core Modules
### Module: PlaybackSession
- Responsibility: Central observable state coordinator; owns all subsystems and presents a unified facade to the UI layer.
- Location (dir or primary file): UI/Session/PlaybackSession.swift:7
- Public API:
  - `openFile(url:)` — loads file, sets up streaming if m3u8, kicks playback [PlaybackSession.swift:105]
  - `play()` / `pause()` / `togglePlayPause()` — delegates to engine [PlaybackSession.swift:152-162]
  - `seek(to:)` / `seekForward(seconds:)` / `seekBackward(seconds:)` — time seek [PlaybackSession.swift:164-177]
  - `setVolume(_:)` / `toggleMute()` — audio control [PlaybackSession.swift:179-183]
  - `setPlaybackRate(_:)` / `setAudioDelay(_:)` — engine config [PlaybackSession.swift:185-186]
  - `setSubtitleTrack(_:)` / `loadExternalSubtitle(url:)` — subtitle control [PlaybackSession.swift:188-194]
  - `stop()` — tears down engine and subtitle manager [PlaybackSession.swift:196-201]
- Internal collaborators: PlaybackEngine, MediaPipeline, MetalRenderer, StreamingManager, VideoAnalysisManager, PerformanceOptimizer, DisplayManager, AirPlayController, SubtitleManager, KeyboardShortcutManager
- Persistence: N/A — all state is in-memory
- External calls: N/A
- Side effects: Window title updates [PlaybackSession.swift:256]; key event monitoring [PlaybackSession.swift:319]

### Module: AudioEngine (Spatial)
- Responsibility: Spatial audio playback with head tracking, HRTF processing, room simulation, multi-channel audio object management
- Location (dir or primary file): Core/Engine/Audio/AudioEngine.swift:65
- Public API:
  - `startEngine()` / `stop()` / `pause()` — lifecycle [AudioEngine.swift]
  - `setListenerPosition(_:)` / `setListenerOrientation(_:)` — head tracking [AudioEngine.swift]
  - `addAudioObject(_:)` / `removeAudioObject(_:)` / `updateAudioObject(_:position:)` — spatial source management [AudioEngine.swift]
- Internal collaborators: AudioBufferPool, CoreAudioBridge, HRTFProcessor, RoomSimulation, HeadTrackingManager, AirPodsTracker, ExternalTracker, SoftwareTracker
- Persistence: N/A
- External calls: CoreAudio via CoreAudioBridge
- Side effects: Audio session lifecycle; AVAudioEngine graph mutations

### Module: HDR Rendering Pipeline
- Responsibility: Detect HDR metadata, parse Dolby Vision/HDR10+/HLG, compute per-frame tone mapping parameters with transition smoothing, pass uniforms to Metal shaders
- Location (dir or primary file): Core/Renderers/ (HDRTypes.swift, HDRMetadataProcessor.swift, DolbyVisionParser.swift, HDR10PlusParser.swift, MetadataPassthrough.swift, ShaderTypes.swift)
- Public API:
  - `HDRMetadataProcessor.processMetadata(from:)` — parse sample buffer attachments, return `MetadataUpdate` [HDRMetadataProcessor.swift:65]
  - `HDRMetadataProcessor.updateMetalRendererUniforms(_:)` — push params to MetalRenderer [HDRMetadataProcessor.swift:282]
  - `HDRMetadataProcessor.applyMetadata(to:frameTime:)` — set fragment/vertex bytes on render pass [HDRMetadataProcessor.swift:326]
  - `DolbyVisionParser.parseMetadata(from:profile:)` — parse Dolby Vision from CMSampleBuffer [DolbyVisionParser.swift:8]
  - `HDR10PlusParser.parseMetadata(from:)` — parse HDR10+ from CMSampleBuffer [HDR10PlusParser.swift:8]
- Internal collaborators: MetalRenderer, DisplayCapabilityDetector, MetadataPassthroughManager
- Persistence: N/A
- External calls: N/A
- Side effects: Updates MetalRenderer uniforms; sends passthrough metadata to external displays

### Module: Performance System
- Responsibility: Adaptive quality management — monitor CPU/thermal/battery/network, predict resource needs, apply actions (decoder preference, resolution cap, bitrate limit, audio complexity, prefetch deferral)
- Location (dir or primary file): Core/Performance/ (PerformanceOptimizer.swift, AdaptiveQualityController.swift, ResourcePredictor.swift, PowerMode.swift, QualityAction.swift, PlaybackHistory.swift, EnginePerformanceProbe.swift, SubsystemAdapters.swift)
- Public API:
  - `PerformanceOptimizer.optimizeForCurrentState()` — evaluate rules, apply actions [PerformanceOptimizer.swift:54]
  - `PerformanceOptimizer.observe(settings:)` — register current playback settings [PerformanceOptimizer.swift:46]
  - `AdaptiveQualityController.evaluate(systemState:prediction:metrics:mode:settings:)` — stateless rule engine returning `[QualityAction]` [AdaptiveQualityController.swift:8]
- Internal collaborators: PerformanceMonitor, NetworkMonitor, PlaybackHistory, ResourcePredictor, AdaptiveDecoderManager, MetalRenderer (via RenderAdapter), AdaptiveQualityController
- Persistence: PlaybackHistory in-memory buffer
- External calls: N/A
- Side effects: Mutates decoder preference (`forcePreference`), renderer resolution cap (`setResolutionCap`), streaming bitrate (via HLSVariantObserver)

### Module: Streaming
- Responsibility: HLS playback, bitrate observation, streaming cache (download/delete HLS assets), network monitor, stats publishing
- Location (dir or primary file): Core/Streaming/ (StreamingManager.swift, HLS/, Cache/, Network/)
- Public API:
  - `StreamingManager.load(url:)` — open HLS asset [StreamingManager.swift:79]
  - `StreamingManager.switchToQuality(_:)` — change variant bitrate [StreamingManager.swift]
  - `StreamingCache.downloadAsset(url:preferredPeakBitRate:expirationDate:)` — download HLS for offline [StreamingCache.swift:43]
  - `NetworkMonitor` — publishes NWPath status and thermal state [Core/Streaming/Network/NetworkMonitor.swift]
- Internal collaborators: HLSPlayer, HLSCachingAssetLoader, StreamingCache, NetworkMonitor, PlaybackStatsPublisher
- Persistence: StreamingCache downloads HLS assets (key chain + file system via AVAssetDownloadURLSession)
- External calls: HTTP network requests for HLS segments; AVAssetDownloadURLSession for caching
- Side effects: Downloads media for offline playback; publishes playback stats

### Module: Subtitles
- Responsibility: Parse subtitle formats (SRT, ASS, WebVTT), manage track selection, emit current events for UI overlay
- Location (dir or primary file): Subtitles/ (SubtitleManager.swift, SubtitleParser.swift, SubtitleTypes.swift)
- Public API:
  - `SubtitleManager.loadSubtitle(url:)` — parse file and register track [SubtitleManager.swift:17]
  - `SubtitleManager.setActiveTrack(_:)` — select active track [SubtitleManager.swift:40]
  - `SubtitleManager.update(for:)` — filter events by current playback time [SubtitleManager.swift:44]
  - `SRTParser.parse(data:)` / `ASSParser.parse(data:)` / `WebVTTParser.parse(data:)` — format parsers [SubtitleParser.swift]
- Internal collaborators: N/A
- Persistence: N/A
- External calls: N/A
- Side effects: N/A

### Module: Video Analysis
- Responsibility: GPU-accelerated histogram, vectorscope, waveform, and color picker analysis on decoded frames; BS.1770-4 loudness metering
- Location (dir or primary file): Core/Analysis/ (VideoAnalysisManager.swift, AnalysisGPURunner.swift, AnalysisTypes.swift, LFSAudioMeter.swift, AudioMeteringData.swift)
- Public API:
  - `VideoAnalysisManager` — toggle analysis modes, published results [VideoAnalysisManager.swift:11]
  - `AnalysisGPURunner.runHistogram(texture:)` / `runVectorscope(texture:)` / `runWaveform(texture:)` — dispatch Metal compute kernels [AnalysisGPURunner.swift]
  - `LFSAudioMeter.consume(frame:)` — feed PCM audio, get BS.1770 loudness [LFSAudioMeter.swift]
  - `ColorSample` — single-pixel color analysis with HSV/YCbCr conversion [AnalysisTypes.swift:73]
- Internal collaborators: FrameStore, MetalRenderer
- Persistence: N/A
- External calls: N/A
- Side effects: N/A

### Module: Display Management
- Responsibility: Detect connected displays and their HDR/EDR/color-gamut capabilities, persist display configs, react to display changes
- Location (dir or primary file): UI/Session/Displays/ (DisplayManager.swift, AirPlayController.swift, ScreenLookup.swift) + Core/Renderers/Displays/
- Public API:
  - `DisplayManager` — publish `displays` list and `activeDisplay` [DisplayManager.swift:50]
  - `DisplayCapabilityDetector.detectCapabilities(for:)` — determine HDR/EDR/gamut per NSScreen [Core/Renderers/DisplayCapabilities.swift:7]
  - `AirPlayController` — monitor external playback, compute audio delay offset [AirPlayController.swift:34]
  - `PersistedDisplayConfig` — save/load display config from UserDefaults [PersistedDisplayConfig.swift:4]
- Internal collaborators: SystemScreenDetector, DisplayCapabilityDetector, MetalRenderer
- Persistence: UserDefaults (`titanplayer.displays.config.v1`)
- External calls: N/A
- Side effects: Pushes display capability changes to MetalRenderer

## 6. Data Model
- Entities:
  - `MediaInfo` — `duration (CMTime)`, `videoTracks`, `audioTracks`, `subtitleTracks`, `format` | [Core/Decoders/Protocols/SharedTypes.swift:5]
  - `VideoTrackInfo` — `codec`, `width`, `height`, `frameRate`, `isHDR`, `extradata` | [SharedTypes.swift:13]
  - `AudioTrackInfo` — `codec`, `sampleRate`, `channels`, `language` | [SharedTypes.swift:22]
  - `MediaPacket` — `streamIndex`, `data`, `timestamp`, `duration`, `isKeyFrame` | [SharedTypes.swift:35]
  - `MediaFrame` — enum: `case video(VideoFrame)`, `case audio(AudioFrame)`, `case subtitle(SubtitleData)` | [SharedTypes.swift:43]
  - `VideoFrame` — `pixelBuffer`, `timestamp`, `duration`, `colorSpace` | [SharedTypes.swift:49]
  - `AudioFrame` — `buffer`, `format`, `timestamp`, `duration` | [SharedTypes.swift:62]
  - `PlaybackState` — enum: idle/loading/ready/playing/paused/ended/seeking/error(String) with `canTransition(to:)` | [Core/Engine/PlayState.swift:3]
  - `HDRMode` — enum: sdr/hdr10(HDR10Metadata)/hlg | [Core/Renderers/HDRTypes.swift:4]
  - `ExtendedHDRMode` — enum: sdr/hdr10/hdr10Plus/dolbyVision/hlg; has `isDynamic` | [HDRTypes.swift:199]
  - `DisplayCapabilities` — `supportsHDR`, `supportsEDR`, `maxEDRLuminance`, `colorGamut` | [HDRTypes.swift:32]
  - `HDR10Metadata` — display primaries, white point, luminance levels, CLL/FALL | [HDRTypes.swift:10]
  - `DolbyVisionMetadata` — profile, video signal info, RPU metadata | [HDRTypes.swift:106]
  - `ExternalDisplayConfig` — stableID, displayName, colorSpaceName, colorGamut, refreshRate, hdrSupported, maxEDRLuminance, lastSeenAt | [Core/Renderers/Displays/ExternalDisplayConfig.swift:4]
  - `SystemState` — thermalState, cpuUsage, gpuUsage, batteryLevel, batteryState, isLowPowerMode, isHardwareAvailable | [Core/Decoders/VideoDecoder/Utilities/PerformanceMonitor.swift:8]
  - `PerformanceMetrics` — averageDecodeTime, frameDropRate, isDegraded | [PerformanceMonitor.swift:28]
  - `SubtitleEvent` — startTime, endTime, text (AttributedString), position, style | [Subtitles/SubtitleTypes.swift:3]
  - `SubtitleTrack` — name, language, isDefault, events | [SubtitleTypes.swift:45]
- Relationships:
  - PlaybackSession 1:1→ PlaybackEngine | [UI/Session/PlaybackSession.swift:44]
  - PlaybackEngine 1:1→ MediaPipeline | [Core/Engine/PlaybackEngine.swift:35, created at line 186]
  - MediaPipeline 1:1→ MediaDemuxing + 1:1→ MediaDecoding | [Core/Engine/MediaPipeline.swift:11-12]
  - PlaybackSession 1:1→ MetalRenderer (via FrameRendering protocol) | [PlaybackSession.swift:20]
  - MetalRenderer 1:1→ FrameStore | [Core/Renderers/MetalRenderer.swift:51]
  - VideoAnalysisManager 1:1→ FrameStore (observation) | [Core/Analysis/VideoAnalysisManager.swift:42-49]
  - PlaybackSession 1:1→ PerformanceOptimizer | [PlaybackSession.swift:40]
  - PerformanceOptimizer 1:N→ AdaptiveSubsystemAdapting (DecoderAdapter, RenderAdapter, etc.) | [Core/Performance/PerformanceOptimizer.swift:19]
  - AdaptiveDecoderManager 1:1→ DecoderSelector | [Core/Decoders/VideoDecoder/Manager/AdaptiveDecoderManager.swift:21-22]
  - AdaptiveDecoderManager 1:1→ PerformanceMonitor | [AdaptiveDecoderManager.swift:23]
  - PlaybackSession 1:1→ DisplayManager | [PlaybackSession.swift:37]
  - DisplayManager 1:N→ ExternalDisplayConfig | [UI/Session/Displays/DisplayManager.swift:51]
  - PlaybackSession 1:1→ AirPlayController | [PlaybackSession.swift:38]
  - SubtitleManager 1:N→ SubtitleTrack | [Subtitles/SubtitleManager.swift:6-7]
  - AudioEngine 1:N→ AudioObject (spatial audio sources) | [Core/Engine/Audio/AudioEngine.swift:82]
- Migrations location: N/A — no database/schema migrations

## 7. External Dependencies
- Dependency | version | used for | used in
- `FFmpegBuild` (Libavcodec, Libavformat, Libavutil, Libswscale) | branch `main` | FFmpeg demuxing/decoding as fallback when AVFoundation insufficient | [Package.swift:8, Core/Decoders/FFmpeg/]
- `AVFoundation` (system) | macOS SDK | AVPlayer playback, AVAsset, HLS, audio routing | [Core/Engine/PlaybackEngine.swift:2, Core/Streaming/HLS/]
- `Metal` (system) | macOS SDK | GPU rendering, compute shaders (tone mapping, analysis) | [Core/Renderers/MetalRenderer.swift:1]
- `AVFAudio` (system) | macOS SDK | Audio engine, spatial audio, AVAudioEngine | [Core/Engine/Audio/AudioEngine.swift:1]
- `Accelerate` (system) | macOS SDK | vDSP for audio metering | [LFSAudioMeter.swift:3]
- `Network` / `NWPathMonitor` (system) | macOS SDK | Network reachability monitoring | [Core/Streaming/Network/NetworkMonitor.swift:3]

## 8. Cross-Cutting Concerns
- Authentication: N/A — no user authentication
- Authorization: Sandbox entitlements restrict access: movies read-write, audio-input, network client/server | [TitanPlayer.entitlements]
- Logging: `os.log` via `Logger(subsystem:category:)` — used across multiple modules:
  - `com.titanplayer.audio`: AudioEngine, FormatNegotiator, Diagnostics
  - `com.titanplayer.app`: PlaybackSession (FileOpen)
  - `com.titanplayer`: MediaPipeline, PlaybackEngine, MetalRenderer, MetalShaders, HDRMetadataProcessor, PixelBufferPool, SeekCoordinator, AudioDeviceMonitor, MetadataPassthrough, AdaptiveDecoderManager, ShortcutConflictChecker, SandboxBookmarkManager
- Error handling: `PlaybackError` enum with `code` and `errorDescription`; caught in `PlaybackEngine.load()`, propagated via state machine | [Core/Engine/PlaybackError.swift:3, PlaybackEngine.swift:68-97]
  - `DecoderError` with severity (transient/persistent) | [Core/Decoders/VideoDecoder/Protocols/VideoDecoding.swift:7]
  - `RendererError` with `errorDescription` | [Core/Renderers/FrameRendering.swift:13]
  - `StreamingError` with `errorDescription` | [Core/Streaming/StreamingError.swift:3]
  - `MediaError` with `ErrorCode` | [Core/Decoders/Protocols/SharedTypes.swift:93]
  - `AudioEngineError` | [Core/Engine/Audio/AudioEngine.swift:12]
- Configuration loading: UserDefaults for `KeyboardShortcutManager` key `titanplayer.keybindings` and `PersistedDisplayConfig` key `titanplayer.displays.config.v1` | [UI/Shortcuts/KeyboardShortcutManager.swift:6, PersistedDisplayConfig.swift:5]
- Validation: `PlaybackState.canTransition(to:)` — state machine guards; `MediaPipeline.shouldUseAVFoundation(for:)` — supported codec list | [Core/Engine/PlayState.swift:26, MediaPipeline.swift:131]
- Caching: `HLSPlayer.cachedAssets` (in-memory AVURLAsset cache); `StreamingCache` (HLS download for offline); `FFmpegBridge` stubbed | [Core/Streaming/HLS/HLSPlayer.swift:10, Core/Streaming/Cache/StreamingCache.swift]

## 9. Key Flows
### Flow: Open and play a local video file
1. User drops file on ContentView → `onDrop(of:)` → `session.openFile(url:)` | [UI/Views/ContentView.swift:18]
2. `PlaybackSession.openFile(url:)` starts security-scoped resource access, calls `engine.load(url:)` | [UI/Session/PlaybackSession.swift:105-117]
3. `PlaybackEngine.load(url:)` creates AVURLAsset, loads tracks, sets AVPlayerItem, probes with `MediaPipeline.openFile(url:)` | [Core/Engine/PlaybackEngine.swift:68-97]
4. `MediaPipeline.openFile(url:)` probes with `FFmpegDemuxer`, selects backend (AVFoundation vs FFmpeg), opens selected demuxer | [Core/Engine/MediaPipeline.swift:30-58]
5. `PlaybackSession` calls `play()`, which triggers `engine.play()` → AVPlayer starts; `MediaPipeline` starts packet-reading loop | [PlaybackSession.swift:152, PlaybackEngine.swift:99, MediaPipeline.swift:60]
6. `MediaPipeline.startPacketReading()` loops: `demuxer.nextPacket()` → `decoder.decode(packet)` → `processFrame(frame)` → `renderer?.render(videoFrame)` | [MediaPipeline.swift:94-119]
7. `MetalRenderer.render(_:)` writes to `FrameStore`, which updates through `MTKView` delegate `draw(in:)` | [MetalRenderer.swift]
8. SubtitleManager receives periodic time updates, filters active events | [Subtitles/SubtitleManager.swift:44]
9. PerformanceOptimizer.optimizeForCurrentState() runs on state changes, applying quality actions | [UI/Session/PlaybackSession.swift:137]

### Flow: HDR playback with dynamic tone mapping
1. MetalRenderer receives a decoded video frame; detects HDR from pixel buffer attachments | [MetalRenderer.swift]
2. `HDRMetadataProcessor.processMetadata(from:)` parses CMSampleBuffer, identifies HDR10/HDR10+/Dolby Vision/HLG | [HDRMetadataProcessor.swift:65]
3. Processor generates `AppliedHDRParams` (knee point, compression ratio, saturation, brightness) based on format and display capabilities | [HDRMetadataProcessor.swift:341-421]
4. If dynamic metadata (HDR10+/DV), params update per-frame with bezier-based transition smoothing over ~83ms | [HDRMetadataProcessor.swift:438-468]
5. `HDRMetadataProcessor.updateMetalRendererUniforms(_:)` pushes `HDRUniforms` to MetalRenderer | [HDRMetadataProcessor.swift:282-318]
6. Metal compute shader `hdrToneMapping` converts PQ/HLG to linear, applies color matrix, runs dynamic or ACES tone mapping, applies saturation/brightness, optionally converts to sRGB | [Resources/Shaders/HDR.metal:4-38]
7. Fragment shader `fragmentShader` applies ICC color matrix, brightness, contrast, saturation | [Resources/Shaders/Video.metal:4-22]

### Flow: Adaptive quality optimization
1. `PerformanceOptimizer.optimizeForCurrentState()` reads `PerformanceMonitor.currentSystemState` (CPU, thermal, battery) and `recentMetrics` (decode time, frame drops) | [PerformanceOptimizer.swift:54-58]
2. `ResourcePredictor.predict(history:currentSystemState:)` computes CPU trend (mean+1.5σ), memory estimate, and thermal risk score from `PlaybackHistory` | [Core/Performance/ResourcePredictor.swift:30-50]
3. `AdaptiveQualityController.evaluate()` applies 5 rule sets: decoder bias, render resolution cap, streaming bitrate cap, audio complexity, prefetch deferral | [Core/Performance/AdaptiveQualityController.swift:8-73]
4. Actions dispatched to `DecoderAdapter.forcePreference()` (HW↔SW decoder switch) and `RenderAdapter.apply()` (set `ResolutionCap` on MetalRenderer) | [Core/Performance/SubsystemAdapters.swift:16, 40-60]
5. `PerformanceOptimizer` records a `PlaybackSample` into `PlaybackHistory` for future prediction | [PerformanceOptimizer.swift:70-81]

## 10. Conventions & Patterns
- Naming conventions:
  - Protocols use `-ing` or `-able` suffix: `MediaDecoding`, `MediaDemuxing`, `FrameRendering`, `DisplayProviding`, `HLSPlayerProtocol`, `StreamingCacheProtocol`
  - Protocol typealiases: `typealias VideoRenderer = FrameRendering` [Core/Renderers/FrameRendering.swift:4]
  - State enums use adjective forms: `idle`, `loading`, `ready`, `playing`, `paused`, `ended`, `seeking`, `error(String)`
  - Test injection methods prefixed `_testInject` or `_test` — e.g., `_testInjectPerformance(cpu:memoryBytes:)`, `_testInject(_:)`
- Folder organization rule: `Core/` contains non-UI business logic subdivided by domain (Engine, Renderers, Decoders, Streaming, Performance, Analysis, Hardware); `UI/` contains SwiftUI views, view-models, controls, session, shortcuts, touchbar, utilities — mirrors Core structure where applicable
- Repeated code shapes / patterns:
  - `ObservableObject` classes with `@Published` properties for SwiftUI binding
  - Protocol-oriented design: core abstractions defined as protocols (`MediaDecoding`, `MediaDemuxing`, `VideoDecoding`, `FrameRendering`, etc.)
  - `@MainActor` on all UI-facing classes; `@unchecked Sendable` on thread-safe utilities
  - Factory/`makeDefault()` static methods on complex subsystem managers (e.g., `PerformanceOptimizer.makeDefault()`, `StreamingManager.makeDefault()`)
  - `SessionLocator.shared` singleton pattern for accessing `PlaybackSession` from non-view contexts (menu commands, window controllers)
- Testing approach (framework, location, what is tested):
  - Swift XCTest target `TitanPlayerTests` under `Tests/` directory
  - Test file naming: `<Component>Tests.swift` (e.g., `MetalRendererTests.swift`, `HDRTypesTests.swift`)
  - Tests exist for: AirPlay, HDR types, HDR parsers (Dolby Vision, HDR10+), HDRMetadataProcessor, HDR playback integration, Metal renderer, display capabilities/config/persistence, analysis types, video decoder, streaming, audio
  - Test helper directory `Helpers/`
  - Test fixtures include `Fixtures/test.mp4` [Package.swift:37]

## 11. Gotchas & Non-Obvious Behavior
- `TimeObserver` in `MediaPipeline` uses `Date().timeIntervalSince(startTime)` for current time (wall clock), NOT demuxer PTS — drifts if pipeline stalls | [Core/Engine/TimeObserver.swift:30-31]
- `FFmpegBridge` is a stub — all methods return zero/nil/default values. No actual FFmpeg C bindings are implemented; real FFmpeg integration relies on the `FFmpegBuild` package but the bridge acts as placeholder | [Core/Decoders/FFmpeg/FFmpegBridge.swift:7-37]
- `AudioTap` wiring uses reflection (`Mirror`) to find a `MediaDecoding` instance inside the engine — fragile if internal property names change | [UI/Session/PlaybackSession.swift:306-317]
- `MediaPipeline` creates two separate demuxer instances: one `FFmpegDemuxer` for probing, then a potentially different backend for actual playback — probe resources are thrown away | [Core/Engine/MediaPipeline.swift:35-37, 44-49]
- `HDRMetadataProcessor` expects HDR metadata in `CMSampleBuffer` attachments dictionary under keys `"HDR10PlusMetadata"`, `"DolbyVisionProfile"`, `"DolbyVisionMetadata"`, `"HDR10Metadata"` — these keys must match whatever the decoder/probe layer populates | [HDRMetadataProcessor.swift:152-192]
- `PlaybackEngine` manages an `AVPlayer` AND a separate `MediaPipeline` — both operate in parallel for the same file, but only `AVPlayer` drives audio; `MediaPipeline` drives video rendering | [PlaybackEngine.swift:7, 23, 88]
- `MetalShaders.loadLibrary()` falls back to runtime MSL compilation if the app bundle lacks a default.metallib segment (common with SwiftPM builds) — it concatenates all `.metal` files into one source, stripping duplicate headers | [Core/Renderers/MetalShaders.swift:12-53]
- `AdaptiveQualityController` has a hardcoded rule: if CPU > 70% AND thermal is non-nominal AND HW decoder is active, it forces software decoder — this can cause performance degradation if the software decoder is slower | [AdaptiveQualityController.swift:25-29]
- `AudioEngine.spatialAudioEnabled` can be toggled while playing, but `setSpatialAudioEnabled` calls `enableSpatialAudio()`/`disableSpatialAudio()` which may reconfigure the audio graph mid-playback | [PlaybackEngine.swift:164-172]
- The `FrameStore` wraps a `UInt64` frame counter that wraps around (uses `&+=`), potentially causing `MirrorViewDelegate` to skip textures briefly during overflow | [Core/Engine/FrameStore.swift:17]
- `CurrentlyAccessedURL` in PlaybackSession is tracked for security-scoped resource stop-access; if a user opens a file outside the sandbox, the bookmark may fail silently | [PlaybackSession.swift:86, 105-114]
- `PlayerView` uses a `DispatchWorkItem` with 3-second delay for auto-hiding controls — if the user pauses during the countdown, controls hide then immediately reappear | [UI/Views/PlayerView.swift:65-77]

## 12. Glossary
- **HDR10** — Static HDR format with per-content metadata (max/min luminance, CLL, FALL) | [Core/Renderers/HDRTypes.swift:10]
- **HDR10+** — Dynamic HDR format with per-frame metadata (Samsung), uses Bezier curve tone mapping | [HDRTypes.swift:60]
- **Dolby Vision** — Dynamic HDR format with dual-layer encoding and RPU (Reference Processing Unit) metadata | [HDRTypes.swift:79-195]
- **HLG** — Hybrid Log-Gamma, broadcast HDR standard (BBC/NHK) | [HDRTypes.swift:7]
- **EDR** — Extended Dynamic Range, Apple's display technology that extends SDR luminance for HDR content | [Core/Renderers/DisplayCapabilities.swift:8]
- **ACES** — Academy Color Encoding System, reference tone mapping curve used as fallback when no dynamic metadata | [Resources/Shaders/HDR.metal:28]
- **RPU** — Reference Processing Unit, Dolby Vision's per-frame metadata structure | [HDRTypes.swift:147]
- **HLS** — HTTP Live Streaming, Apple's adaptive streaming protocol (.m3u8) | [Core/Streaming/StreamingManager.swift:7-17]
- **HRTF** — Head-Related Transfer Function, spatial audio filter for 3D sound positioning | [Core/Engine/Audio/AudioEngine.swift:30]
- **BS.1770** — ITU standard for loudness metering (EBU R128), K-weighted pre-filter + true-peak | [Core/Analysis/LFSAudioMeter.swift:6]
- **ICtCp** — Color space used by Dolby Vision Profile 8 IPT-PQ | [HDRTypes.swift:101]
- **AV1** — Next-gen video codec, hardware decode supported on Apple M3+ | [Core/Hardware/HardwareDecoderCapabilities.swift:63]
- **SEI** — Supplemental Enhancement Information, H.264/HEVC message container for HDR10+ metadata | [HDR10PlusParser.swift:22]
- **TouchBar** — MacBook Pro Touch Bar integration (mini-player controls) | [UI/TouchBar/]

## 13. Open Questions
- UNCERTAIN: How `MediaDecoding.audioTap` is actually wired — the reflection-based `decoderFromEngine()` in PlaybackSession attempts to find one, but the `MediaPipeline`'s `decoder` property is private and may not be reachable via `Mirror` | [PlaybackSession.swift:306-317]
- UNCERTAIN: Whether `AVPlayer` and `MediaPipeline` both control audio output — `PlaybackEngine` starts `AVPlayer` for audio, while `MediaPipeline` also has an `audioRenderer` that could produce conflicting audio | [PlaybackEngine.swift:23, MediaPipeline.swift:15]
- UNCERTAIN: `FFmpegBridge` is a stub — the actual FFmpeg C bindings may be provided by the `FFmpegBuild` package at link time, but the Swift stub class has no `@_silgen_name` or actual C function imports | [FFmpegBridge.swift:7-37]
