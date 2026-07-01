# TitanPlayer.xcodeproj

This directory holds the parallel Xcode project that hosts the
`TitanPlayerUITests` XCUITest target.

## Status: scaffold

The committed `.xcodeproj/` skeleton currently ships:

- `TitanPlayer.xcodeproj/PROJECT_PENDING.md` — notes on regeneration
- Directory structure and scheme placeholders

The canonical pbxproj is intentionally absent because hand-authoring a
fully-equivalent Xcode project is brittle. Generate it via one of:

```bash
# Option 1: xcodegen project.yml
brew install xcodegen
xcodegen generate        # produces TitanPlayer.xcodeproj/project.pbxproj

# Option 2: Xcode UI
open TitanPlayer.xcodeproj   # Xcode prompts to create a project from
                             # scratch, then point sources at
                             # TitanPlayer/TitanPlayer/ and add a UI test
                             # target referencing TitanPlayerUITests/.
```

The project must:

1. Reference the existing SwiftPM sources at
   `TitanPlayer/TitanPlayer/TitanPlayer/**` (no copies, no moves).
2. Run a `Run Script` build phase on the app target:
   ```
   cd "${SRCROOT}/TitanPlayer" && swift build -c debug
   ```
3. Provide a UI test target `TitanPlayerUITests` whose sources live in
   `TitanPlayerUITests/`.
4. Define a Run Script phase before the test phase that re-runs
   `swift build -c debug` so the XCUITest bundle has a fresh executable.

## Test scheduling

Run the UI tests nightly from `.github/workflows/tests.yml`:
```bash
xcodebuild -project TitanPlayer.xcodeproj \
           -scheme TitanPlayerUITests \
           -destination 'platform=macOS' \
           test
```

Locally: `make ui-tests`.

## Parity with SwiftPM tests

`scripts/check-test-parity.sh` ensures every Swift test file under
`TitanPlayer/Tests/` is reachable from SwiftPM (it always is, via the
existing `Package.swift`). The `.xcodeproj` reference parity will be
maintained by `xcodegen project.yml` once that manifest is committed.
