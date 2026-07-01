# App Store Preparation & Dual Distribution Design

**Date:** 2026-06-30
**Status:** Approved
**Branch:** `feat/app-store-prep`
**Target:** macOS 14+
**Depends on:** existing `TitanPlayer` executable target, `TitanPlayer.xcodeproj/` scaffold (`PROJECT_PENDING.md`, `project.yml.suggested`), Homebrew, Apple Developer Program account.

## Overview

Ship TitanPlayer through **two** mutually-exclusive macOS distribution channels from the same source tree:

- **Mac App Store (MAS)** — sandboxed build, App Store Connect submission.
- **Developer ID** — notarized direct distribution (`.pkg` / `.dmg`) outside the MAS.

Both channels use the same product name (`TitanPlayer`), bundle identifier (`com.titanplayer.app`), and SwiftPM-compiled executable. Divergence is confined to **build configuration**, **entitlements file**, **signing identity**, **distribution mechanism**, and **app-store metadata**. License is MIT (open source).

A `.xcodeproj` is genuinely produced for the first time, replacing the scaffold documented in `TitanPlayer.xcodeproj/PROJECT_PENDING.md`. The project is regenerated from `project.yml` via `xcodegen` and `project.pbxproj` is gitignored, just as the scaffold doc already proposes.

## Goals & Non-Goals

**Goals**

- Real, reproducible build of a `.app` bundle from the existing SwiftPM sources via `xcodegen` + Xcode.
- Two configurations (`AppStore`, `Direct`) producing two `.app` variants from one source tree.
- One entitlements file per configuration matching Apple review guidelines.
- Full App Store Connect metadata (en-US): name, subtitle, description, keywords, release notes, privacy URL, support URL, marketing URL, copyright.
- A complete asset catalog (`Assets.xcassets`) with `AppIcon.appiconset` covering all macOS-required sizes (16, 32, 64, 128, 256, 512, 1024) plus App Store marketing 1280×800.
- MIT LICENSE file at the repo root.
- `PRIVACY.md` document describing data practices, suitable as `privacy_url` target.
- `fastlane/` metadata + `Fastfile` with two lanes (`mas`, `direct`).
- `.gitignore` updated to exclude generated Xcode artifacts.
- Honest verification: textual/structural lint (xmllint, plutil -lint, json validation); environment limit on actual `xcodebuild`/`notarytool` documented in the plan.

**Non-Goals (YAGNI)**

- Generating the marketing 1280×800 screenshot — text-only placeholder README; user-supplies capture.
- Producing a real pixel-perfect branded icon — procedurally-generated placeholder, swappable pre-ship.
- ASan / hardened-runtime ASan fork — out of scope for this prompt; covered by testing-strategy spec.
- App Store Connect API key provisioning — `Fastfile` references placeholder; user-supplies via `~/.fastlane/.env`.
- Auto-uploading to App Store Connect in CI — submission is intentionally manual due to Apple ToS; CI only builds + notarizes.
- Localization beyond `en-US` — single-locale metadata; structure supports adding locales later.
- Replacing the parallel-SwiftPM/Xcode strategy — both stay.

## Decisions Log

| Decision | Rationale |
|---|---|
| `com.titanplayer.app` as bundle identifier | Matches `bundleIdPrefix: com.titanplayer` already declared in `project.yml.suggested`; avoids future renames when `Mac App Store` rejects other namespaces not on a Developer account's organization list. |
| Dual-target (App Store + Developer ID) | User-confirmed; reaches both NA/EU MAS customers and direct-distribution-friendly enterprise/security-conscious users. |
| `xcodegen` produces `project.pbxproj`, which is gitignored | Manual authoring is brittle (per existing `PROJECT_PENDING.md`); regeneration is the source of truth. |
| `project.yml` is committed at repo root (replaces `project.yml.suggested`) | Single source of truth for the Xcode build; matches the suggested file's content. |
| Sandbox ON for App Store, OFF for Direct | Apple MAS **requires** sandbox. Direct distribution does not benefit from sandbox; Hardened Runtime gives equivalent security with more capability flexibility. |
| Hardened Runtime ON for both | `xcrun notarytool` requires it (direct). MAS requires it indirectly via sandbox. Single code path. |
| Two entitlements files, both committed | Cleanly diff-able; reviewers can audit MAS capability vs. Direct. |
| Info.plist gains `NSAppleEventsUsageDescription`, `NSMicrophoneUsageDescription`, `NSAppTransportSecurity` keys | Required for App Review when sandboxing interaction with mic + AirPlay + ATS-by-default behavior. |
| `Assets.xcassets` lives under `TitanPlayer/TitanPlayer/Resources/` | Already referenced by `Package.swift` line 23 (`resources: [.process("Resources/Assets.xcassets")]`); Xcode build will pick it up via the same `path:` declaration in `project.yml`. |
| App icon is a procedurally-generated 1024² PNG + complete `Contents.json` slot manifest | Avoids fabricating shipped-icon identity; clear swap-in path before MAS submit. |
| `fastlane deliver` for metadata upload only, not auto-submit | Apple guidelines forbid unattended submit; metadata pre-fill is the realistic automation win. |
| `xcrun notarytool` invoked manually documented, not as a CI hook here | Mirrors MAS submission policy: signing+notarization stay under human control. CI builds only. |

## Architecture

```
                              En-US metadata
                                  │
                                  ▼
                       ┌───────────────────────────┐
                       │       fastlane/           │
                       │ Appfile  Fastfile  metadata│
                       └──┬─────────────┬──────────┘
                          │             │
                  lane: mas             lane: direct
                          │             │
                          ▼             ▼
        ┌───────────────────────────┐  ┌──────────────────────────┐
        │  xcodebuild -config       │  │  xcodebuild -config       │
        │  AppStore                 │  │  Direct                   │
        │  PRODUCT_BUNDLE_IDENTIFIER│  │  PRODUCT_BUNDLE_IDENTIFIER│
        │  = com.titanplayer.app    │  │  = com.titanplayer.app   │
        │  CODE_SIGN_IDENTITY=      │  │  CODE_SIGN_IDENTITY=      │
        │   "Apple Distribution"    │  │   "Developer ID App"     │
        │  CODE_SIGN_ENTITLEMENTS=  │  │  CODE_SIGN_ENTITLEMENTS=  │
        │   TitanPlayer.entitlements│  │   TitanPlayer.Direct.…   │
        │  ENABLE_APP_SANDBOX=YES   │  │  ENABLE_APP_SANDBOX=NO    │
        │  ENABLE_HARDENED_RT=YES   │  │  ENABLE_HARDENED_RT=YES   │
        └──┬────────────────────────┘  └─┬────────────────────────┘
           │ xcrun altool/PKG                │ xcrun notarytool staple
           ▼                                ▼
       App Store Connect                  Developer-trusted host
       (TestFlight / review)              (download / curl install)

   Both configurations share:
   - TitanPlayer executable (SwiftPM `.build/release/TitanPlayer`)
   - Info.plist template (variable substitutions per CONFIG)
   - Assets.xcassets including AppIcon.appiconset
   - LICENSE (MIT), PRIVACY.md
   - Source: TitanPlayer/TitanPlayer/TitanPlayer/** (no copies)
```

### File-level plan

```
TitanPlayer/TitanPlayer/Resources/Assets.xcassets/
    Contents.json
    AppIcon.appiconset/
        Contents.json                          # all slots + idiom list
        icon_16x16.png
        icon_16x16@2x.png                      # 32
        icon_32x32.png
        icon_32x32@2x.png                      # 64
        icon_128x128.png
        icon_128x128@2x.png                    # 256
        icon_256x256.png
        icon_256x256@2x.png                    # 512
        icon_512x512.png
        icon_512x512@2x.png                    # 1024  ← marketing title icon
        # + icon_1280x800 (marketing)

TitanPlayer/TitanPlayer/
    Info.plist                                # extended (usage strings, ATS key)
    TitanPlayer.entitlements                  # MAS variant
    TitanPlayer.Direct.entitlements           # Developer ID variant
    Resources/Icon-Placeholder/
        master.svg                            # source vector for the procedural icon
        README.md                             # "replace this before MAS submit"

LICENSE                                       # MIT (full text)
PRIVACY.md                                   # plain markdown

fastlane/
    Appfile                                   # app_identifier, apple_id
    Fastfile                                  # lanes :mas, :direct, :metadata_only
    metadata/en-US/
        name.txt
        subtitle.txt
        description.txt
        keywords.txt
        release_notes.txt                     # first-ship "v1.0"
        privacy_url.txt                       # → https://<org>/titanplayer/PRIVACY
        support_url.txt                       # → https://github.com/<org>/titanplayer/issues
        marketing_url.txt                     # → https://<org>/titanplayer
        copyright.txt                         # → "© 2026 <owner>"
        screenshots/
            README.md                         # how to drop captures

TitanPlayer/
    project.yml                               # promoted from project.yml.suggested
                                             # + dual-config + entitlements

.gitignore                                    # added lines (xcuserstate, DerivedData, …)

TitanPlayer.xcodeproj/project.pbxproj        # gitignored; regenerated by xcodegen
```

### Entitlements (App Store variant)

Exactly the XML provided in the user prompt, filed at `TitanPlayer/TitanPlayer/TitanPlayer.entitlements`. `CODE_SIGN_ENTITLEMENTS` build setting keyed to this path when `CONFIGURATION = AppStore`.

### Entitlements (Developer ID variant)

`TitanPlayer/TitanPlayer/TitanPlayer.Direct.entitlements`:
- `com.apple.security.app-sandbox` = false
- (No `com.apple.security.assets.movies.read-write`, no `audio-input`, no `network.client/server` — none of Apple's push for sandboxing applies. Hardened Runtime covers the security surface.)
- Hardened Runtime flags injected via build settings (not in the file): `ENABLE_HARDENED_RUNTIME=YES`, `OTHER_CODE_SIGN_FLAGS=--options=runtime`.

### Info.plist extensions

Replaceable via Xcode build setting substitutions where GUI submission requires:

```xml
<key>NSAppleEventsUsageDescription</key>
<string>TitanPlayer uses Apple Events to command other media apps (e.g. hand off to QuickTime) and to receive Remote control commands.</string>
<key>NSMicrophoneUsageDescription</key>
<string>TitanPlayer uses the microphone only when you explicitly enable audio capture / voice-over features. Audio is processed locally and never leaves your Mac.</string>
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key>
    <false/>
    <key>NSAllowsLocalNetworking</key>
    <true/>
</dict>
<key>NSHumanReadableCopyright</key>
<string>$(NSHUMANREADABLECOPYRIGHT)</string>
<key>LSApplicationCategoryType</key>
<string>public.app-category.entertainment</string>
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
```

### `fastlane/Fastfile` shape (sketch only — full file in plan)

- `lane :metadata_only` — uploads `fastlane/metadata/en-US/*` to App Store Connect via `deliver` (no build, no submit).
- `lane :mas` — `match(app_identifier: "com.titanplayer.app", type: "appstore")`, `gym(configuration: "AppStore")`, prints manual-submit reminder.
- `lane :direct` — `match(app_identifier: "com.titanplayer.app", type: "developer_id")`, `gym(configuration: "Direct")`, `notarize(package: ..., bundle_id: "com.titanplayer.app", username: ENV["APPLE_ID"])` workflow.

### `project.yml` shape (sketch — full yaml in plan)

- `name: TitanPlayer`
- `options.bundleIdPrefix: com.titanplayer`
- `options.deploymentTarget.macOS: "14.0"`
- `configs: Debug, Release, AppStore, Direct` (AppStore & Direct map build settings; Debug + Release hold the dev variants)
- `settings.base.CODE_SIGN_STYLE: Automatic`, `DEVELOPMENT_TEAM: <placeholder>`
- Config-specific:
  - `AppStore`: `PRODUCT_BUNDLE_IDENTIFIER=com.titanplayer.app`, `CODE_SIGN_IDENTITY="Apple Distribution"`, `CODE_SIGN_ENTITLEMENTS=TitanPlayer/TitanPlayer/TitanPlayer.entitlements`, `ENABLE_APP_SANDBOX=YES`, `ENABLE_HARDENED_RUNTIME=YES`
  - `Direct`: same minus sandbox; `CODE_SIGN_IDENTITY="Developer ID Application"`, `CODE_SIGN_ENTITLEMENTS=TitanPlayer/TitanPlayer/TitanPlayer.Direct.entitlements`
- `targets.TitanPlayer`: `type: application`, `platform: macOS`, `sources: [path: TitanPlayer/TitanPlayer/TitanPlayer]`, `preBuildScripts: [swift build -c $(CONFIGURATION:lower)]` (Xcode substitutes `release` for `Release`/`AppStore`/`Direct`, `debug` for `Debug`). The produced executable is folded into the `.app`'s `MacOS/` payload by a second run script `cp .build/$(CONFIGURATION:lower)/TitanPlayer "$BUILT_PRODUCTS_DIR/$EXECUTABLE_FOLDER_PATH/TitanPlayer"`. The AppStore and Direct configurations build a `release` artifact and SHA-pin it before codesign so App Review cannot be tricked into shipping a Debug variant.

### Verification criteria (this prompt's bullets)

| User-stated criterion | Automated/captured gate in this work |
|---|---|
| App passes App Store Review guidelines | Upload `.pkg` to TestFlight lane using `xcrun altool --upload-package`; `fastlane deliver --submit_for_review false` (manual review). Cannot run in CommandLineTools-only environment; commands + sign-off checklist in the implementation plan. |
| Notarization succeeds without warnings | `xcrun notarytool submit ... --wait --output-format json` returns `Accepted` and staple via `xcrun stapler staple`. Same env limit; command fully specified in plan. |
| Sandboxing works correctly | Manual smoke + scripted launch test in plan; the existing `make compat-smoke` gate plus a target script `make sandbox-smoke` exercising file/mic/airplay. |
| All metadata complete and accurate | `fastlane deliver --check_metadata` (text-only lint, runs in CI) plus a `metadata-lint` Makefile target running a custom Ruby sanity check on `metadata/en-US/*.txt` (10k-char limits, 100-char subtitle, 30-char keywords, etc.). |
| App icon renders correctly in all contexts | `iconutil --convert icns ./Icon-Placeholder --output ./build/TitanPlayer.icns` plus `iconutil -h`; CI runs `iconutil --lint` on the resulting `.icns`. Visual review off-CI. |

### Honest scope limits

This work environment has only **Command Line Tools**, not Xcode. Concretely:

- ❌ Cannot run `xcodebuild`, `notarytool`, `altool`, or `iconutil` here.
- ❌ Cannot run `fastlane` without RubyGems workspace (works fine; just not exercised here).
- ✅ Can run `xmllint -noout`, `plutil -lint`, `swift package describe`, `jq`, `file`, basic stat.
- ✅ Can run `xcodegen install` via Homebrew (with `brew` on $PATH) — gates on a Mac GUI session.

The implementation plan will include a parallel `make dist-prep-check` script that performs every lint step that *can* run in this environment, leaving only the visible-Xcode steps to the user.

## Distribution runbook (user-side)

After the spec's commits land, the developer (you) completes App Store
submission on a machine with full Xcode + an Apple Developer account:

1. **One-time setup:**
   ```bash
   brew install xcodegen fastlane
   ```
2. **Generate the Xcode project from canonical yml:**
   ```bash
   cd TitanPlayer && xcodegen generate --spec project.yml --project ..
   open ../TitanPlayer.xcodeproj
   ```
3. **Mac App Store submission:**
   ```bash
   cd fastlane
   fastlane metadata_only   # pushes fastlane/metadata/* to App Store Connect
   fastlane mas             # build, sign with Apple Distribution, archive,
                            # upload to TestFlight. Then in App Store Connect
                            # UI: submit the build for review.
   ```
4. **Developer ID (notarized) submission:**
   ```bash
   cd fastlane
   fastlane direct          # build, sign, notarize via notarytool, staple;
                            # produces build/direct/TitanPlayer-Direct.pkg.
                            # Host the .pkg via your CDN / GitHub Releases.
   ```
5. **Required env vars in `~/.fastlane/.env`:**
   ```
   APPLE_ID=<your-developer-apple-id@example.com>
   TEAM_ID=<your Apple Developer Team ID>
   APP_STORE_TEAM_ID=<your App Store Connect team ID>
   MATCH_PASSWORD=<match keychain password>
   NOTARY_API_KEY_PATH=<absolute path to AuthKey_XXXX.json>
   ```

`make dist-prep-check` runs every textual lint this prompt produces,
including in CI (`.github/workflows/dist-prep.yml`). No Xcode required.

## What this prompt did NOT verify (env limit)

- Real `xcodebuild` success (requires full Xcode; this sandbox has Command Line Tools only).
- Real `xcrun notarytool --submit` success (notarizer unreachable without full Xcode + Apple Developer credentials).
- Real App Store Connect ingestion / TestFlight flight creation.
- Real `xcrun altool --upload-package` exit code.
- Actual macOS sandbox containment (requires manual sandbox smoke test).

These remain in the user-side runbook above.

## Validation criteria → automated tests mapping

| Validation bullet | Automated gate |
|---|---|
| App passes App Store Review | Human review + `xcrun altool --upload-package`; documented in plan as the submission step. |
| Notarization succeeds | `xcrun notarytool submit … --wait --output-format json` exit-code 0 + "Accepted". |
| Sandbox works | `make sandbox-smoke` (added in implementation plan). |
| Metadata complete | `fastlane/metadata-lint` (custom Ruby) + `fastlane deliver --check_metadata`. |
| Icon renders | `iconutil --convert icns` + `iconutil --lint`; visual sign-off in checklist. |
| Lint passes (this env) | `make dist-prep-check` script — text-only lint plist, entitlements, fastlane metadata, project.yml JSON→YAML parse, license presence, privacy presence. |
