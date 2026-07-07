# Titan Player — Agent Notes

## Build & Test

This is a SwiftPM project (`TitanPlayer/Package.swift`). Run commands from the
`TitanPlayer/` subdirectory.

- **Build (executable target):** `swift build`  ✅ works with Command Line Tools
- **Tests:** `swift test`  ⚠️ requires a full Xcode install

### Known environment limitation: `swift test` fails with `no such module 'XCTest'`

The machine currently has only **Command Line Tools** active
(`xcode-select -p` → `/Library/Developer/CommandLineTools`). Command Line Tools
does not ship the XCTest framework, so SwiftPM test targets cannot be built/run.

To run tests, install Xcode and switch the developer dir:
```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
swift test
```

When verifying test files on a CommandLineTools-only machine, use this to confirm
the test target has no errors *other than* the environmental XCTest one:
```bash
swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"
```
An empty result means the test sources are syntactically/type correct; the only
blocker is the missing XCTest module.

## Architecture pointer

Rendering / HDR pipeline design and plan live under `docs/superpowers/specs/`
and `docs/superpowers/plans/` (see `2026-06-25-metal-hdr-rendering-pipeline-*`).
Source: `TitanPlayer/TitanPlayer/Core/Renderers/`; Metal shaders:
`TitanPlayer/TitanPlayer/Resources/Shaders/`.

## Logging convention

Per-frame and per-packet `logger.info` calls are gated behind `#if DEBUG` to
keep release builds silent. The rule:

- **`logger.error` / `logger.warning`** — always on (debug + release).
- **`logger.debug`** — wrapped in `#if DEBUG … #endif`. Used for hot-path
  diagnostics (packet reading loop, decode cycle, file-open tracing).
- **`logger.info`** — reserved for one-time, non-repetitive events that should
  appear in release logs (if any remain).

Affected files: `MediaPipeline.swift`, `PlaybackEngine.swift`,
`PlaybackSession.swift`.

The `Package.swift` also defines `TITAN_VERBOSE_LOGGING` in debug builds for
custom conditional compilation needs.
