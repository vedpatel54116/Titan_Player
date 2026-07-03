# Launch Safety Check — Design

## Problem

`PlaybackSession.init()` has a force-unwrap crash risk at line 142:

```swift
let device = MTLCreateSystemDefaultDevice()
    ?? MTLCreateSystemDefaultDevice()!
```

If Metal is unavailable, the app crashes with `EXC_BAD_ACCESS` / `SIGABRT`. There is no recovery path — the user sees a crash report instead of a helpful error.

Other subsystems (`VideoAnalysisManager`, `PerformanceOptimizer`) also depend on the Metal device but have no graceful fallback.

## Goal

Prevent initialization crashes from breaking the app. If any critical subsystem fails to initialize, show a blocking alert with a "Quit" button instead of crashing.

## Design

### 1. Fix the force-unwrap crash

**File:** `PlaybackSession.swift` (line 142)

Replace:
```swift
let device = MTLCreateSystemDefaultDevice()
    ?? MTLCreateSystemDefaultDevice()!
```

With a safe lookup that reuses the renderer's device when available:
```swift
let device: MTLDevice?
if let existing = resolvedVideoRenderer as? MetalRenderer {
    device = existing.device
} else {
    device = MTLCreateSystemDefaultDevice()
}
```

### 2. Failable subsystem creation

Make subsystem init within `PlaybackSession.init()` handle nil/throwing cases gracefully. When a subsystem cannot be created, store `nil` and record the failure.

- `VideoAnalysisManager` — if `device` is nil, create with nil or skip
- `PlaybackEngine`, `DisplayManager`, `AirPlayController`, `StreamingManager`, `PerformanceOptimizer` — wrap in `do/catch` (even though they currently don't throw, this future-proofs)

### 3. Add `initializationError` property

```swift
@Published var initializationError: PlayerInitializationError?

enum PlayerInitializationError: LocalizedError {
    case metalDeviceUnavailable
    case subsystemFailure(String)

    var errorDescription: String? {
        switch self {
        case .metalDeviceUnavailable:
            return "Metal is not available on this device."
        case .subsystemFailure(let name):
            return "Failed to initialize \(name)."
        }
    }
}
```

Set this property in `init()` when any subsystem fails. The session still completes initialization — it marks itself as degraded.

### 4. UI alert in TitanPlayerApp

**File:** `TitanPlayerApp.swift`

```swift
@State private var showError = false

// In body:
.onReceive(session.$initializationError) { error in
    showError = error != nil
}
.alert(
    "Player Engine Error",
    isPresented: $showError,
    actions: {
        Button("Quit") { NSApplication.shared.terminate(nil) }
    },
    message: {
        Text(session.initializationError?.localizedDescription
             ?? "Failed to initialize player engine. Please restart the app.")
    }
)
```

The alert blocks interaction with the window. The only action is "Quit".

## Files Changed

| File | Change |
|------|--------|
| `TitanPlayer/UI/Session/PlaybackSession.swift` | Fix force-unwrap, add `initializationError`, failable subsystem creation |
| `TitanPlayer/TitanPlayerApp.swift` | Observe error, present alert |

## Acceptance Criteria

- [ ] Failable initializers are used for risky subsystems (Metal device, VideoAnalysisManager)
- [ ] PlaybackSession handles nil subsystems without crashing
- [ ] UI displays a blocking alert with "Quit" button if initialization fails
