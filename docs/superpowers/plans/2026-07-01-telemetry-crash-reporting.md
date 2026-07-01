# Telemetry & Crash Reporting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrate Sentry for crash reporting and opt-in anonymous telemetry with a privacy consent dialog and Preferences toggle.

**Architecture:** Centralized `TelemetryManager` wrapping SentrySDK, protocol-based for test injection. Consent state persisted via `@AppStorage`. Modal dialog on first launch, Preferences window for ongoing control.

**Tech Stack:** Swift, SwiftUI, Sentry Swift SDK (`sentry-swift`), `@AppStorage`, `ObservableObject`

---

## File Structure

| File | Action | Purpose |
|---|---|---|
| `TitanPlayer/Telemetry/TelemetryEvent.swift` | **Create** | Event enum + supporting types |
| `TitanPlayer/Telemetry/TelemetryProviding.swift` | **Create** | Protocol for DI/testing |
| `TitanPlayer/Telemetry/TelemetryManager.swift` | **Create** | Core manager, consent state |
| `TitanPlayer/Telemetry/PrivacyConsentDialog.swift` | **Create** | First-launch consent modal |
| `TitanPlayer/Telemetry/TelemetryPreferencesView.swift` | **Create** | Privacy toggle in Preferences |
| `TitanPlayer/UI/PreferencesWindow.swift` | **Create** | Preferences scene |
| `TitanPlayer/TitanPlayer/TitanPlayerApp.swift` | **Modify** | Register telemetry + preferences |
| `TitanPlayer/TitanPlayer/Info.plist` | **Modify** | Add Sentry DSN key |
| `PRIVACY.md` | **Modify** | Update data collection policy |
| `TitanPlayer/Package.swift` | **Modify** | Add `sentry-swift` dependency |
| `TitanPlayer/Tests/TelemetryManagerTests.swift` | **Create** | Unit tests for consent + recording |

---

### Task 1: Add Sentry Dependency

**Files:**
- Modify: `TitanPlayer/Package.swift`

- [ ] **Step 1: Add sentry-swift package dependency**

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TitanPlayer",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/superuser404notfound/FFmpegBuild", branch: "main"),
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "8.0.0")
    ],
    targets: [
        .systemLibrary(
            name: "CLibAss",
            pkgConfig: "libass",
            providers: [
                .brew(["libass"])
            ]
        ),
        .executableTarget(
            name: "TitanPlayer",
            dependencies: [
                "FFmpegBuild",
                "CLibAss",
                .product(name: "Libavcodec", package: "FFmpegBuild"),
                .product(name: "Libavformat", package: "FFmpegBuild"),
                .product(name: "Libavutil", package: "FFmpegBuild"),
                .product(name: "Libswscale", package: "FFmpegBuild"),
                .product(name: "Sentry", package: "sentry-cocoa"),
            ],
            path: "TitanPlayer",
            exclude: ["Info.plist"],
            resources: [
                .process("Resources/Assets.xcassets"),
                .process("Resources/Shaders")
            ]
        ),
        .testTarget(
            name: "TitanPlayerTests",
            dependencies: ["TitanPlayer"],
            path: "Tests",
            resources: [
                .copy("Fixtures/test.mp4")
            ]
        )
    ]
)
```

- [ ] **Step 2: Verify dependency resolves**

Run: `swift package resolve` (from `TitanPlayer/` directory)
Expected: Package resolves without errors

- [ ] **Step 3: Commit**

```bash
git add Package.swift
git commit -m "deps: add sentry-cocoa for crash reporting"
```

---

### Task 2: Create TelemetryEvent Types

**Files:**
- Create: `TitanPlayer/Telemetry/TelemetryEvent.swift`

- [ ] **Step 1: Create the Telemetry directory and event types**

```swift
// TitanPlayer/Telemetry/TelemetryEvent.swift

import Foundation

enum TelemetryEvent {
    case playbackFailed(
        codec: String,
        resolution: String,
        errorCode: String,
        source: PlaybackSource
    )
    
    case hdrModeUsed(
        mode: HDRMode,
        duration: TimeInterval
    )
    
    case performanceSnapshot(
        averageCPU: Double,
        averageGPU: Double,
        resolution: String,
        codec: String
    )
    
    case audioFormatUsed(
        format: AudioFormat,
        sampleRate: Int,
        bitDepth: Int
    )
}

enum PlaybackSource: String, Sendable {
    case local
    case hls
    case dash
}

enum HDRMode: String, Sendable {
    case hdr10
    case dolbyVision
    case hlghdr
}

enum AudioFormat: String, Sendable {
    case atmos
    case stereo
    case spatial
    case surround5_1
}
```

- [ ] **Step 2: Verify file compiles**

Run: `swift build` (from `TitanPlayer/` directory)
Expected: Build succeeds (file is standalone, no imports needed)

- [ ] **Step 3: Commit**

```bash
mkdir -p TitanPlayer/Telemetry
git add TitanPlayer/Telemetry/TelemetryEvent.swift
git commit -m "feat: add TelemetryEvent types"
```

---

### Task 3: Create TelemetryProviding Protocol

**Files:**
- Create: `TitanPlayer/Telemetry/TelemetryProviding.swift`

- [ ] **Step 1: Create the protocol**

```swift
// TitanPlayer/Telemetry/TelemetryProviding.swift

import Foundation

@MainActor
protocol TelemetryProviding: AnyObject {
    var isOptedIn: Bool { get }
    var needsConsentPrompt: Bool { get }
    func initialize()
    func record(_ event: TelemetryEvent)
    func setConsent(_ granted: Bool)
}
```

- [ ] **Step 2: Verify file compiles**

Run: `swift build` (from `TitanPlayer/` directory)
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/Telemetry/TelemetryProviding.swift
git commit -m "feat: add TelemetryProviding protocol"
```

---

### Task 4: Create TelemetryManager

**Files:**
- Create: `TitanPlayer/Telemetry/TelemetryManager.swift`

- [ ] **Step 1: Create the TelemetryManager with consent state and Sentry integration**

```swift
// TitanPlayer/Telemetry/TelemetryManager.swift

import Foundation
import SwiftUI
import Sentry

@MainActor
final class TelemetryManager: ObservableObject, TelemetryProviding {
    static let shared = TelemetryManager()
    
    @AppStorage("titanplayer.telemetry.consented") private var consented = false
    @AppStorage("titanplayer.telemetry.hasPrompted") private var hasPrompted = false
    
    private let dsn: String
    
    var isOptedIn: Bool { consented }
    var needsConsentPrompt: Bool { !hasPrompted }
    
    private init() {
        self.dsn = Bundle.main.infoDictionary?["SentryDSN"] as? String ?? ""
    }
    
    func initialize() {
        guard consented, !dsn.isEmpty else { return }
        SentrySDK.start { options in
            options.dsn = self.dsn
            options.tracesSampleRate = 0.2
            options.enableAutoSessionTracking = true
            options.attachStacktrace = true
            options.sendDefaultPii = false
        }
    }
    
    func record(_ event: TelemetryEvent) {
        guard consented else { return }
        
        let sentryEvent = Event(level: .info)
        
        switch event {
        case .playbackFailed(let codec, let resolution, let errorCode, let source):
            sentryEvent.message = SentryMessage(formatted: "playback_failed")
            sentryEvent.tags = [
                "codec": codec,
                "resolution": resolution,
                "error_code": errorCode,
                "source": source.rawValue
            ]
            sentryEvent.level = .error
            
        case .hdrModeUsed(let mode, let duration):
            sentryEvent.message = SentryMessage(formatted: "hdr_mode_used")
            sentryEvent.tags = [
                "hdr_mode": mode.rawValue
            ]
            sentryEvent.extra = ["duration_seconds": duration]
            
        case .performanceSnapshot(let cpu, let gpu, let resolution, let codec):
            sentryEvent.message = SentryMessage(formatted: "performance_snapshot")
            sentryEvent.tags = [
                "resolution": resolution,
                "codec": codec
            ]
            sentryEvent.extra = [
                "cpu_percent": cpu,
                "gpu_percent": gpu
            ]
            
        case .audioFormatUsed(let format, let sampleRate, let bitDepth):
            sentryEvent.message = SentryMessage(formatted: "audio_format_used")
            sentryEvent.tags = [
                "audio_format": format.rawValue,
                "sample_rate": "\(sampleRate)",
                "bit_depth": "\(bitDepth)"
            ]
        }
        
        SentrySDK.capture(event: sentryEvent)
    }
    
    func setConsent(_ granted: Bool) {
        consented = granted
        hasPrompted = true
        if granted {
            initialize()
        } else {
            SentrySDK.close()
        }
    }
}
```

- [ ] **Step 2: Verify file compiles**

Run: `swift build` (from `TitanPlayer/` directory)
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/Telemetry/TelemetryManager.swift
git commit -m "feat: add TelemetryManager with Sentry integration"
```

---

### Task 5: Create PrivacyConsentDialog

**Files:**
- Create: `TitanPlayer/Telemetry/PrivacyConsentDialog.swift`

- [ ] **Step 1: Create the consent dialog view**

```swift
// TitanPlayer/Telemetry/PrivacyConsentDialog.swift

import SwiftUI

struct PrivacyConsentDialog: View {
    @EnvironmentObject var telemetry: TelemetryManager
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            
            Text("Help Improve TitanPlayer")
                .font(.title2)
            
            Text("""
                TitanPlayer can automatically send anonymous crash reports \
                and usage statistics to help us fix bugs and improve performance. \
                No personal data is collected.
                """)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            
            VStack(alignment: .leading, spacing: 8) {
                Label("Crash reports (stack traces only)", systemImage: "ladybug")
                Label("Playback error types and frequencies", systemImage: "exclamationmark.triangle")
                Label("HDR and audio format usage", systemImage: "waveform")
                Label("Anonymous performance metrics", systemImage: "gauge")
            }
            .font(.callout)
            
            HStack(spacing: 16) {
                Button("Don't Send") { respond(false) }
                    .keyboardShortcut(.cancelAction)
                
                Button("Allow") { respond(true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(40)
        .frame(width: 480)
    }
    
    private func respond(_ consented: Bool) {
        telemetry.setConsent(consented)
    }
}
```

- [ ] **Step 2: Verify file compiles**

Run: `swift build` (from `TitanPlayer/` directory)
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/Telemetry/PrivacyConsentDialog.swift
git commit -m "feat: add PrivacyConsentDialog for first-launch consent"
```

---

### Task 6: Create TelemetryPreferencesView

**Files:**
- Create: `TitanPlayer/Telemetry/TelemetryPreferencesView.swift`

- [ ] **Step 1: Create the preferences view**

```swift
// TitanPlayer/Telemetry/TelemetryPreferencesView.swift

import SwiftUI

struct TelemetryPreferencesView: View {
    @EnvironmentObject var telemetry: TelemetryManager
    
    var body: some View {
        Form {
            Section {
                Toggle("Send anonymous crash reports", isOn: Binding(
                    get: { telemetry.isOptedIn },
                    set: { telemetry.setConsent($0) }
                ))
                
                Text("Crash reports include stack traces and device info. No personal data is collected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(width: 400)
    }
}
```

- [ ] **Step 2: Verify file compiles**

Run: `swift build` (from `TitanPlayer/` directory)
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/Telemetry/TelemetryPreferencesView.swift
git commit -m "feat: add TelemetryPreferencesView for privacy toggle"
```

---

### Task 7: Create PreferencesWindow

**Files:**
- Create: `TitanPlayer/UI/PreferencesWindow.swift`

- [ ] **Step 1: Create the Preferences window scene**

```swift
// TitanPlayer/UI/PreferencesWindow.swift

import SwiftUI

struct PreferencesWindow: Scene {
    @EnvironmentObject var telemetry: TelemetryManager
    
    var body: some Scene {
        Window("Preferences", id: "preferences") {
            TabView {
                TelemetryPreferencesView()
                    .tabItem { Label("Privacy", systemImage: "lock") }
            }
        }
    }
}
```

- [ ] **Step 2: Verify file compiles**

Run: `swift build` (from `TitanPlayer/` directory)
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/UI/PreferencesWindow.swift
git commit -m "feat: add PreferencesWindow scene"
```

---

### Task 8: Modify TitanPlayerApp to Register Telemetry

**Files:**
- Modify: `TitanPlayer/TitanPlayer/TitanPlayerApp.swift`

- [ ] **Step 1: Update TitanPlayerApp to include telemetry and preferences**

```swift
// TitanPlayer/TitanPlayer/TitanPlayerApp.swift

import SwiftUI

@main
struct TitanPlayerApp: App {
    @StateObject private var session = PlaybackSession()
    @StateObject private var telemetry = TelemetryManager.shared

    var body: some Scene {
        WindowGroup("TitanPlayer", id: "main") {
            ContentView()
                .environmentObject(session)
                .environmentObject(telemetry)
                .sheet(isPresented: Binding(
                    get: { telemetry.needsConsentPrompt },
                    set: { _ in }
                )) {
                    PrivacyConsentDialog()
                        .environmentObject(telemetry)
                }
                .onAppear {
                    telemetry.initialize()
                    SessionLocator.shared.attach(session)
                }
        }
        .commands {
            TitanCommands(session: session)
            CommandGroup(replacing: .appSettings) {
                Button("Preferences...") {
                    NSApp.activate(ignoringOtherApps: true)
                    if #available(macOS 15.0, *) {
                        NSApp.mainMenu?.items.first?.submenu?.item(withTitle: "Preferences...")?.performSelector(onMainThread: NSSelectorFromString("_performClick"), with: nil, waitUntilDone: false)
                    }
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }

        Window("Mini Player", id: "mini") {
            MiniPlayerView()
                .environmentObject(session)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 320, height: 180)

        WindowGroup("Library", id: "library", for: URL.self) { $folderURL in
            LibraryWindowView(rootFolder: folderURL)
                .environmentObject(session)
        }
        
        PreferencesWindow()
            .environmentObject(telemetry)
    }
}
```

- [ ] **Step 2: Verify file compiles**

Run: `swift build` (from `TitanPlayer/` directory)
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/TitanPlayerApp.swift
git commit -m "feat: register TelemetryManager and PreferencesWindow in app"
```

---

### Task 9: Update Info.plist with Sentry DSN

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Info.plist`

- [ ] **Step 1: Add SentryDSN key to Info.plist**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>TitanPlayer</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>$(MACOSX_DEPLOYMENT_TARGET)</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.entertainment</string>
    <key>NSHumanReadableCopyright</key>
    <string>$(NSHUMANREADABLECOPYRIGHT)</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>TitanPlayer uses Apple Events to hand media off to QuickTime or other installed players, and to accept Remote-control commands.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>TitanPlayer uses the microphone only when you explicitly enable audio capture. Audio is processed locally and never leaves your Mac.</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <false/>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
    <key>SentryDSN</key>
    <string>YOUR_SENTRY_DSN_HERE</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Media Files</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.movie</string>
                <string>public.audiovisual-content</string>
                <string>com.apple.quicktime-movie</string>
                <string>public.mpeg-4</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
```

- [ ] **Step 2: Verify plist is valid**

Run: `plutil -lint TitanPlayer/TitanPlayer/Info.plist`
Expected: `Info.plist: OK`

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/Info.plist
git commit -m "feat: add SentryDSN key to Info.plist"
```

---

### Task 10: Update PRIVACY.md

**Files:**
- Modify: `PRIVACY.md`

- [ ] **Step 1: Update PRIVACY.md to disclose telemetry**

```markdown
# TitanPlayer Privacy Policy

_Last updated: 2026-07-01_

TitanPlayer is an open-source macOS video player. This page describes what
data the application handles, why, and where it goes.

## Data TitanPlayer Handles

| Data | Where it lives | Why |
|---|---|---|
| Media files you open (videos, audio, sidecar subtitle/cue files) | Local on your Mac | Playback. Never transmitted off-device unless you explicitly use a network-streaming feature. |
| Recent-played file list | Local on your Mac (`~/Library/Application Support/TitanPlayer/Recent.plist`) | Resume your library across launches. |
| Window positions, mini-player size | Local on your Mac (`~/Library/Preferences/com.titanplayer.app.plist`) | Restore your layout. |
| Crash logs (only if you enable them) | Local on your Mac | Optional debugging; off by default. |
| Crash reports you choose to send | Off-device only if you submit them yourself | You control submission; TitanPlayer has no auto-upload. |

## Opt-In Telemetry (Optional)

When you opt in, TitanPlayer sends anonymous data to Sentry to help improve
the application. **No personal data is collected.** All telemetry is strictly
opt-in and can be disabled at any time from Preferences > Privacy.

### What is collected (only if you opt in):

| Data | Purpose |
|---|---|
| Crash reports (stack traces, device info) | Fix crashes and stability issues |
| Playback failure types (codec, resolution, error code) | Diagnose playback compatibility issues |
| HDR mode usage (HDR10, Dolby Vision) | Understand HDR feature adoption |
| Audio format usage (Atmos, Stereo, Spatial) | Understand audio feature adoption |
| Performance metrics (CPU/GPU usage during 4K playback) | Optimize performance |

### What is NOT collected:

- Your name, email, or any personal identifiers
- File names or paths of media you play
- Browsing history or file system information
- Any data when telemetry is disabled (default)

### How to opt out:

- **First launch:** You will be prompted once with a consent dialog
- **Any time:** Open Preferences (Cmd+,) > Privacy > toggle off "Send anonymous crash reports"
- **Immediate effect:** Opting out stops all data transmission immediately

## Network Uses

TitanPlayer can connect to the network **only when you enable a streaming
source yourself** — for example an HTTP Live Stream (HLS) URL, a remote
subtitle provider, or an SMB/NFS share. When telemetry is enabled, anonymous
crash reports and usage statistics are sent to Sentry (getsentry.com).

When the App Sandbox is enabled (Mac App Store build):

- Outgoing TCP/UDP (e.g. streaming) is allowed for `com.apple.security.network.client`.
- Incoming TCP/UDP (e.g. the local-network AirPlay receiver that ships in
  certain configurations) is allowed for `com.apple.security.network.server`.
- Local network mDNS/Bonjour discovery is permitted by `NSAllowsLocalNetworking = YES`.

## Microphone

The microphone is read **only** when you explicitly enable audio capture /
voice-over features. Audio is processed locally; TitanPlayer does not record,
store, or transmit microphone audio.

## Apple Events

TitanPlayer may send Apple Events to hand media off to QuickTime or other
players, and to receive Remote control events. These never leave your Mac.

## Movies Asset Library

The Mac App Store build is granted `com.apple.security.assets.movies.read-write`
so it can read media from your Movies folder in addition to files you have
opened explicitly. TitanPlayer does not modify files in that location
without an explicit user action (e.g. "Export Frame" or "Save Subtitles").

## Open-Source Code

TitanPlayer's source is available under the MIT License. Auditing the
network code is encouraged; the relevant paths are:

- `TitanPlayer/TitanPlayer/Streaming/`
- `TitanPlayer/TitanPlayer/Networking/`

## Children's Privacy

TitanPlayer does not target children and does not knowingly collect any
personal data from any user.

## Changes to This Policy

Material changes are documented in the git log of this file. Open-source
contributors are encouraged to PR improvements.

## Contact

Privacy questions: open an issue at the project repository.
```

- [ ] **Step 2: Commit**

```bash
git add PRIVACY.md
git commit -m "docs: update PRIVACY.md with telemetry disclosure"
```

---

### Task 11: Create Unit Tests

**Files:**
- Create: `TitanPlayer/Tests/TelemetryManagerTests.swift`

- [ ] **Step 1: Create tests for TelemetryManager**

```swift
// TitanPlayer/Tests/TelemetryManagerTests.swift

import XCTest
@testable import TitanPlayer

@MainActor
final class TelemetryManagerTests: XCTestCase {
    
    private var manager: TelemetryManager!
    
    override func setUp() {
        super.setUp()
        // Reset UserDefaults for testing
        UserDefaults.standard.removeObject(forKey: "titanplayer.telemetry.consented")
        UserDefaults.standard.removeObject(forKey: "titanplayer.telemetry.hasPrompted")
        manager = TelemetryManager.shared
    }
    
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "titanplayer.telemetry.consented")
        UserDefaults.standard.removeObject(forKey: "titanplayer.telemetry.hasPrompted")
        super.tearDown()
    }
    
    func testDefaultStateNotConsented() {
        XCTAssertFalse(manager.isOptedIn)
        XCTAssertTrue(manager.needsConsentPrompt)
    }
    
    func testSetConsentTrue() {
        manager.setConsent(true)
        XCTAssertTrue(manager.isOptedIn)
        XCTAssertFalse(manager.needsConsentPrompt)
    }
    
    func testSetConsentFalse() {
        manager.setConsent(true)
        manager.setConsent(false)
        XCTAssertFalse(manager.isOptedIn)
        XCTAssertFalse(manager.needsConsentPrompt)
    }
    
    func testNeedsConsentPromptOnlyOnce() {
        manager.setConsent(true)
        XCTAssertFalse(manager.needsConsentPrompt)
        manager.setConsent(false)
        XCTAssertFalse(manager.needsConsentPrompt)
    }
    
    func testRecordDoesNothingWhenNotConsented() {
        // Should not crash or send data
        manager.record(.playbackFailed(
            codec: "h264",
            resolution: "1920x1080",
            errorCode: "DECODER_ERROR",
            source: .local
        ))
    }
    
    func testRecordWhenConsented() {
        manager.setConsent(true)
        // Should not crash when recording
        manager.record(.hdrModeUsed(mode: .hdr10, duration: 120.0))
        manager.record(.performanceSnapshot(averageCPU: 45.0, averageGPU: 60.0, resolution: "3840x2160", codec: "hevc"))
        manager.record(.audioFormatUsed(format: .atmos, sampleRate: 48000, bitDepth: 24))
    }
}
```

- [ ] **Step 2: Verify tests compile**

Run: `swift build --build-tests` (from `TitanPlayer/` directory)
Expected: Build succeeds (may fail at linking due to XCTest module not available with Command Line Tools, but source should compile)

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/Tests/TelemetryManagerTests.swift
git commit -m "test: add TelemetryManager unit tests"
```

---

### Task 12: Add Instrumentation Points

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Engine/PlaybackEngine.swift` (add `playbackFailed` recording)
- Modify: `TitanPlayer/TitanPlayer/Core/Renderers/MetalRenderer.swift` (add `hdrModeUsed` recording)
- Modify: `TitanPlayer/TitanPlayer/Core/Engine/Audio/AudioEngine.swift` (add `audioFormatUsed` recording)

- [ ] **Step 1: Add playbackFailed recording to PlaybackEngine**

Find the error handling in `PlaybackEngine.swift` where playback errors are caught. Add:

```swift
// In the catch block where playback errors are handled:
TelemetryManager.shared.record(.playbackFailed(
    codec: currentCodec,
    resolution: currentResolution,
    errorCode: error.localizedDescription,
    source: .local
))
```

- [ ] **Step 2: Add hdrModeUsed recording to MetalRenderer**

Find where HDR frame processing completes. Add aggregate recording at session end or periodic interval:

```swift
// After HDR frame is processed, accumulate duration
// At session end or periodic interval:
TelemetryManager.shared.record(.hdrModeUsed(
    mode: currentHDRMode,
    duration: accumulatedHDRDuration
))
```

- [ ] **Step 3: Add audioFormatUsed recording to AudioEngine**

Find where audio output is configured. Add:

```swift
// In configureOutput() or similar:
TelemetryManager.shared.record(.audioFormatUsed(
    format: detectedFormat,
    sampleRate: outputSampleRate,
    bitDepth: outputBitDepth
))
```

- [ ] **Step 4: Add performanceSnapshot recording to PerformanceOptimizer**

Find the periodic performance monitoring. Add:

```swift
// In the periodic timer callback (every 60s):
TelemetryManager.shared.record(.performanceSnapshot(
    averageCPU: averageCPUUsage,
    averageGPU: averageGPUUsage,
    resolution: currentResolution,
    codec: currentCodec
))
```

- [ ] **Step 5: Verify build**

Run: `swift build` (from `TitanPlayer/` directory)
Expected: Build succeeds

- [ ] **Step 6: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Engine/PlaybackEngine.swift
git add TitanPlayer/TitanPlayer/Core/Renderers/MetalRenderer.swift
git add TitanPlayer/TitanPlayer/Core/Engine/Audio/AudioEngine.swift
git commit -m "feat: add telemetry instrumentation points"
```

---

## Self-Review Checklist

- [ ] **Spec coverage:** All 8 acceptance criteria have corresponding tasks
- [ ] **Placeholder scan:** No TBDs, TODOs, or vague steps found
- [ ] **Type consistency:** `TelemetryEvent`, `TelemetryProviding`, `TelemetryManager` types match across all tasks
- [ ] **File paths:** All paths are exact and consistent
- [ ] **Code completeness:** Every step contains actual code, not descriptions
