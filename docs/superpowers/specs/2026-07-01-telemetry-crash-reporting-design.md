# Telemetry & Crash Reporting — Design Spec

**Date:** 2026-07-01
**Status:** Approved
**Author:** opencode

## Overview

Integrate Sentry for crash reporting and opt-in anonymous telemetry in TitanPlayer. Users are prompted once on first launch with a clear consent dialog. Telemetry can be toggled at any time via a new Preferences window.

## Goals

1. **Crash reporting** — Capture and report crashes with full stack traces to a Sentry dashboard.
2. **Opt-in telemetry** — Collect anonymous usage data (playback failures, HDR mode, performance, audio formats) only with explicit user consent.
3. **Privacy-first** — No PII collected. Clear consent flow. Opt-out takes effect immediately.
4. **Preferences UI** — New Preferences window with a Privacy tab for ongoing control.

## Architecture

### Approach: Centralized TelemetryManager

Single `TelemetryManager` class wrapping SentrySDK, following existing project patterns (ObservableObject, protocol injection, `@AppStorage` persistence).

### Data Flow

```
PlaybackEngine ──┐
MetalRenderer  ──┤──→ TelemetryManager.record(.event) ──→ SentrySDK
PerfOptimizer  ──┤         ↑ consented?
AudioEngine    ──┘         │ no → no-op (discard)
```

### Consent State

- `@AppStorage("titanplayer.telemetry.consented")` — boolean, user's choice
- `@AppStorage("titanplayer.telemetry.hasPrompted")` — boolean, prevents re-prompting
- On first launch, `needsConsentPrompt` returns `true`, presenting the modal dialog
- `setConsent(false)` calls `SentrySDK.close()` for immediate effect

## Components

### TelemetryManager

**File:** `Telemetry/TelemetryManager.swift`

```swift
@MainActor
final class TelemetryManager: ObservableObject, TelemetryProviding {
    static let shared = TelemetryManager()
    
    @AppStorage("titanplayer.telemetry.consented") private var consented = false
    @AppStorage("titanplayer.telemetry.hasPrompted") private var hasPrompted = false
    
    private let dsn: String
    
    var isOptedIn: Bool { consented }
    var needsConsentPrompt: Bool { !hasPrompted }
    
    func initialize() {
        guard consented else { return }
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
        // Convert TelemetryEvent → Sentry event with fingerprint
    }
    
    func setConsent(_ granted: Bool) {
        consented = granted
        hasPrompted = true
        if granted { initialize() }
        else { SentrySDK.close() }
    }
}
```

### TelemetryEvent

**File:** `Telemetry/TelemetryEvent.swift`

```swift
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

enum PlaybackSource: String { case local, hls, dash }
enum HDRMode: String { case hdr10, dolbyVision, hlghdr }
enum AudioFormat: String { case atmos, stereo, spatial, surround5_1 }
```

### TelemetryProviding Protocol

**File:** `Telemetry/TelemetryProviding.swift`

```swift
protocol TelemetryProviding: AnyObject {
    var isOptedIn: Bool { get }
    var needsConsentPrompt: Bool { get }
    func initialize()
    func record(_ event: TelemetryEvent)
    func setConsent(_ granted: Bool)
}
```

Enables test injection via `_testInject` pattern.

### PrivacyConsentDialog

**File:** `Telemetry/PrivacyConsentDialog.swift`

Modal dialog shown once on first launch:
- Title: "Help Improve TitanPlayer"
- Body: Explains anonymous crash reports and usage statistics
- Lists what is collected (crash reports, playback errors, HDR/audio usage, performance)
- Two buttons: "Don't Send" / "Allow"
- No "Remind me later" — forces explicit choice
- Displayed as `.sheet` from `ContentView`

### TelemetryPreferencesView

**File:** `Telemetry/TelemetryPreferencesView.swift`

- Single toggle: "Send anonymous crash reports"
- Caption explaining no personal data is collected
- Toggle calls `telemetry.setConsent()` — takes effect immediately

### PreferencesWindow

**File:** `UI/PreferencesWindow.swift`

- New `Scene` registered in `TitanPlayerApp`
- `TabView` with "Privacy" tab (future tabs: General, Playback, Shortcuts)
- Accessible via `Cmd+,` keyboard shortcut

## Integration Points

| Event | Source File | Trigger |
|---|---|---|
| `playbackFailed` | `PlaybackEngine.swift` | Catch block in `openFile()` / `play()` |
| `hdrModeUsed` | `MetalRenderer.swift` | One aggregate event per playback session (total HDR duration by mode) |
| `performanceSnapshot` | `PerformanceOptimizer.swift` | Periodic timer (every 60s during playback) |
| `audioFormatUsed` | `AudioEngine.swift` | On format detection during `configureOutput()` |

## App Entry Point Changes

**File:** `TitanPlayerApp.swift`

```swift
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
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
        // ... Mini Player, Library windows
    }
}
```

## File Changes

| File | Action | Purpose |
|---|---|---|
| `Telemetry/TelemetryManager.swift` | **Create** | Core manager, consent state |
| `Telemetry/TelemetryEvent.swift` | **Create** | Event enum + supporting types |
| `Telemetry/TelemetryProviding.swift` | **Create** | Protocol for DI/testing |
| `Telemetry/PrivacyConsentDialog.swift` | **Create** | First-launch consent modal |
| `Telemetry/TelemetryPreferencesView.swift` | **Create** | Privacy toggle in Preferences |
| `UI/PreferencesWindow.swift` | **Create** | Preferences scene |
| `TitanPlayerApp.swift` | **Modify** | Register telemetry + preferences |
| `Info.plist` | **Modify** | Add Sentry DSN key (`SentryDSN`) |
| `PRIVACY.md` | **Modify** | Update data collection policy |
| `Package.swift` | **Modify** | Add `sentry-swift` dependency |

## Privacy

- **No PII** — `sendDefaultPii = false`, no user identifiers sent
- **Anonymous** — Events contain only technical data (codec, resolution, error codes)
- **Opt-in only** — Telemetry is OFF until user explicitly consents
- **Immediate opt-out** — `SentrySDK.close()` called on decline/toggle-off
- **PRIVACY.md updated** — Discloses anonymous crash reporting and usage statistics

## Acceptance Criteria

1. Crashes are reported to Sentry dashboard with full stack traces and device info.
2. Telemetry events (playback failures, HDR usage, performance, audio formats) are sent securely and anonymously.
3. Users are prompted once on first launch with a clear consent dialog.
4. Users can opt-out at any time from Preferences > Privacy.
5. Opt-out takes effect immediately (no data sent after toggle).
6. No PII is collected or transmitted.
7. All telemetry calls are no-op when consent is not granted.
8. Unit tests verify consent state management and event recording logic.

## Testing

- `TelemetryManagerTests.swift` — Consent state, initialize/close lifecycle, event recording
- `PrivacyConsentDialogTests.swift` — UI state transitions
- `TelemetryEventTests.swift` — Event serialization to Sentry format
- Use `_testInject` pattern for mock `TelemetryProviding` in integration tests
