# TelemetryManager Testability & PRIVACY.md Sync

**Date:** 2026-07-03
**Status:** Approved

## Problem

`TelemetryManager` is tightly coupled to `SentrySDK` static calls. Existing tests only verify consent state transitions, not Sentry interactions (start, capture, close). The PRIVACY.md document needs updating to reflect the actual collected event types and DSN configuration.

## Goal

1. Make TelemetryManager testable via a protocol seam for SentrySDK
2. Add comprehensive unit tests covering the consent state machine and all TelemetryEvent paths
3. Update PRIVACY.md to document collected events, PII policy, DSN source, and opt-out instructions

## Design

### 1. SentrySDKProtocol Seam

**New file:** `TitanPlayer/TitanPlayer/Telemetry/TelemetrySentry.swift`

```swift
import Sentry

protocol SentrySDKProtocol: Sendable {
    func start(dsn: String, tracesSampleRate: Double)
    func capture(event: Event)
    func close()
}

struct LiveSentrySDK: SentrySDKProtocol {
    func start(dsn: String, tracesSampleRate: Double) {
        SentrySDK.start { options in
            options.dsn = dsn
            options.tracesSampleRate = tracesSampleRate
            options.enableAutoSessionTracking = true
            options.attachStacktrace = true
            options.sendDefaultPii = false
        }
    }

    func capture(event: Event) {
        SentrySDK.capture(event: event)
    }

    func close() {
        SentrySDK.close()
    }
}
```

### 2. TelemetryManager Refactor

**File:** `TitanPlayer/TitanPlayer/Telemetry/TelemetryManager.swift`

Changes:
- Add `private let sentry: SentrySDKProtocol` property
- Change `private init()` to `init(dsn: String = Bundle.main..., sentry: SentrySDKProtocol = LiveSentrySDK())`
- `static let shared` uses default params: `TelemetryManager()`
- `initialize()` calls `sentry.start(dsn: dsn, tracesSampleRate: 0.2)` instead of `SentrySDK.start { ... }`
- `record(_:)` calls `sentry.capture(event: sentryEvent)` instead of `SentrySDK.capture(event:)`
- `setConsent(false)` calls `sentry.close()` instead of `SentrySDK.close()`
- `setConsent(true)` calls `initialize()` (unchanged)

**Public API remains identical.** `TelemetryProviding` protocol unchanged.

### 3. Unit Tests

**File:** `TitanPlayer/Tests/Unit/TelemetryManagerTests.swift` (replace existing)

**Mock:**

```swift
final class MockSentrySDK: SentrySDKProtocol, @unchecked Sendable {
    var startCallCount = 0
    var lastStartDSN: String?
    var captureCallCount = 0
    var lastCapturedEvent: Event?
    var closeCallCount = 0

    func start(dsn: String, tracesSampleRate: Double) {
        startCallCount += 1
        lastStartDSN = dsn
    }
    func capture(event: Event) {
        captureCallCount += 1
        lastCapturedEvent = event
    }
    func close() {
        closeCallCount += 1
    }
}
```

**Test cases:**

| Test | Setup | Assertion |
|------|-------|-----------|
| `test_initialize_noOpWithoutConsent` | `consented=false`, `initialize()` | `mock.startCallCount == 0` |
| `test_initialize_noOpWithoutDSN` | `consented=true`, `dsn=""` | `mock.startCallCount == 0` |
| `test_initialize_startsSentry` | `consented=true`, valid DSN | `mock.startCallCount == 1`, `mock.lastStartDSN == dsn` |
| `test_record_ignoredWithoutConsent` | `consented=false`, `record(...)` | `mock.captureCallCount == 0` |
| `test_record_capturesEvent` | `consented=true`, `record(.hdrModeUsed(...))` | `mock.captureCallCount == 1` |
| `test_setConsent_true_initializesSentry` | `setConsent(true)` | `mock.startCallCount == 1` |
| `test_setConsent_false_closesSentry` | `setConsent(true)` then `setConsent(false)` | `mock.closeCallCount == 1` |
| `test_telemetryOffPath_doesNotCrash` | `consented=false`, all 5 event cases | No crash, `mock.captureCallCount == 0` |

### 4. PRIVACY.md Updates

**File:** `PRIVACY.md`

Add under "Opt-In Telemetry" > "What is collected":

| Event Type | Data Sent | Level |
|------------|-----------|-------|
| `playbackFailed` | codec, resolution, error_code, source (local/hls) | error |
| `hdrModeUsed` | hdr_mode (hdr10/dolbyVision/hlg), duration_seconds | info |
| `performanceSnapshot` | resolution, codec, cpu_percent, gpu_percent | info |
| `audioFormatUsed` | audio_format (atmos/stereo/spatial/surround5_1), sample_rate, bit_depth | info |
| `compatibilityModeActivated` | reason, source (local/hls) | warning |

Add notes:
- `sendDefaultPii=false` — no personal identifiers sent
- DSN configured via `Info.plist` key `SentryDSN`
- Sentry (getsentry.com) is the data processor
- Opt-out: Preferences > Privacy toggle, or `defaults write titanplayer.telemetry.consented -bool false`

## Constraints

- Do not change consent key names (`titanplayer.telemetry.consented`, `titanplayer.telemetry.hasPrompted`)
- Do not enable telemetry by default (`consented` defaults to `false`)
- Public API (`TelemetryProviding`) unchanged

## Files Changed

| File | Change |
|------|--------|
| `TitanPlayer/TitanPlayer/Telemetry/TelemetrySentry.swift` | New — protocol + live impl |
| `TitanPlayer/TitanPlayer/Telemetry/TelemetryManager.swift` | Refactor — inject protocol + DSN |
| `TitanPlayer/Tests/Unit/TelemetryManagerTests.swift` | Rewrite — full coverage |
| `PRIVACY.md` | Update — event reference + opt-out docs |
