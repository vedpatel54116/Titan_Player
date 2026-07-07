# Shortcuts Preferences Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Shortcuts" tab to the Preferences window that lists all `PlayerAction`s grouped by category, shows current bindings as human-readable strings, allows recording new bindings with conflict detection, and provides a "Reset to Defaults" button.

**Architecture:** Standalone `ShortcutsPreferencesView` creates its own `KeyboardShortcutManager` instance (same `UserDefaults.standard` as `PlaybackSession`). A static `isRecordingShortcut` flag coordinates with the session's key monitor. Key display uses a new `ShortcutDisplayFormatter` utility. Recording captures via `NSEvent.addLocalMonitorForEvents` + `PhysicalKeyResolver`.

**Tech Stack:** SwiftUI, AppKit (`NSEvent` local monitors), `PhysicalKeyResolver`, `KeyEquivalentResolver`, existing `KeyboardShortcutManager` persistence layer.

---

## File Structure

| File | Action | Purpose |
|------|--------|---------|
| `UI/Shortcuts/KeyboardShortcutManager.swift` | Modify | Add `static var isRecordingShortcut`, `resetToDefaults()` |
| `UI/Shortcuts/ShortcutDisplayFormatter.swift` | Create | Converts `(key, modifiers)` → display string ("⌘F") |
| `UI/Session/PlaybackSession.swift` | Modify | Guard monitor dispatch on `isRecordingShortcut` |
| `UI/Shortcuts/ShortcutsPreferencesView.swift` | Create | Full shortcuts preferences tab UI |
| `UI/PreferencesWindow.swift` | Modify | Add "Shortcuts" tab to `TabView` |
| `Tests/Unit/KeyboardShortcutManagerTests.swift` | Modify | Add rebind-persist, conflict, reset tests |

---

### Task 1: Add `resetToDefaults()` and `isRecordingShortcut` to `KeyboardShortcutManager`

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Shortcuts/KeyboardShortcutManager.swift`

- [ ] **Step 1: Add static recording flag**

After the `defaultsKey` static let (line 6), add:

```swift
static var isRecordingShortcut = false
```

- [ ] **Step 2: Add `resetToDefaults()` method**

After the `persist()` method (around line 55), add:

```swift
func resetToDefaults() {
    bindings = Self.defaultBindings
    persist()
}
```

- [ ] **Step 3: Verify build**

Run: `swift build` from `TitanPlayer/` directory.
Expected: Build succeeds with no errors.

- [ ] **Step 4: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Shortcuts/KeyboardShortcutManager.swift
git commit -m "Add isRecordingShortcut flag and resetToDefaults() to KeyboardShortcutManager"
```

---

### Task 2: Create `ShortcutDisplayFormatter`

**Files:**
- Create: `TitanPlayer/TitanPlayer/UI/Shortcuts/ShortcutDisplayFormatter.swift`

- [ ] **Step 1: Create the formatter**

Create `TitanPlayer/TitanPlayer/UI/Shortcuts/ShortcutDisplayFormatter.swift` with:

```swift
import AppKit

enum ShortcutDisplayFormatter {
    static func displayString(key: String, modifiers: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []

        if modifiers.contains(.control) { parts.append("\u{2303}") }
        if modifiers.contains(.option)  { parts.append("\u{2325}") }
        if modifiers.contains(.shift)   { parts.append("\u{21E7}") }
        if modifiers.contains(.command) { parts.append("\u{2318}") }

        parts.append(displayKey(key))

        return parts.joined()
    }

    private static func displayKey(_ key: String) -> String {
        switch key {
        case "space":     return "Space"
        case "return", "enter": return "\u{21A9}"
        case "tab":       return "\u{21E5}"
        case "escape", "esc": return "\u{238B}"
        case "delete", "del": return "\u{232B}"
        case "uparrow":   return "\u{2191}"
        case "downarrow": return "\u{2193}"
        case "leftarrow": return "\u{2190}"
        case "rightarrow": return "\u{2192}"
        case "home":      return "\u{2196}"
        case "end":       return "\u{2198}"
        case "pageup":    return "\u{21DE}"
        case "pagedown":  return "\u{21DF}"
        case "clear":     return "\u{2327}"
        default:
            if key.count == 1 { return key.uppercased() }
            return key
        }
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build` from `TitanPlayer/` directory.
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Shortcuts/ShortcutDisplayFormatter.swift
git commit -m "Add ShortcutDisplayFormatter for human-readable key binding display"
```

---

### Task 3: Add recording guard to `PlaybackSession` monitor

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift:446`

- [ ] **Step 1: Add guard in the key monitor**

In `PlaybackSession.swift`, find the line inside the `addLocalMonitorForEvents` closure that calls `router.action(for: event)` (around line 446). Wrap the action dispatch with a recording guard:

**Before:**
```swift
if let action = router.action(for: event) {
    dispatcher.dispatch(action)
    return nil   // consumed
}
```

**After:**
```swift
if !KeyboardShortcutManager.isRecordingShortcut,
   let action = router.action(for: event) {
    dispatcher.dispatch(action)
    return nil   // consumed
}
```

- [ ] **Step 2: Verify build**

Run: `swift build` from `TitanPlayer/` directory.
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift
git commit -m "Guard PlaybackSession key monitor dispatch during shortcut recording"
```

---

### Task 4: Create `ShortcutsPreferencesView`

**Files:**
- Create: `TitanPlayer/TitanPlayer/UI/Shortcuts/ShortcutsPreferencesView.swift`

- [ ] **Step 1: Create the view**

Create `TitanPlayer/TitanPlayer/UI/Shortcuts/ShortcutsPreferencesView.swift` with:

```swift
import SwiftUI
import AppKit

struct ShortcutsPreferencesView: View {
    @State private var manager = KeyboardShortcutManager()
    @State private var recordingAction: PlayerAction? = nil
    @State private var conflictError: String? = nil
    @State private var eventMonitor: Any? = nil

    private let groups: [(String, [PlayerAction])] = [
        ("Playback", [
            .togglePlayPause, .seekBackward10, .seekForward10,
            .seekBackward60, .seekForward60,
            .stepFrameForward, .stepFrameBackward,
            .volumeUp, .volumeDown, .toggleMute,
            .toggleSubtitles, .toggleHDR,
            .increasePlaybackRate, .decreasePlaybackRate, .resetPlaybackRate
        ]),
        ("Window", [
            .openFile, .toggleFullscreen, .toggleMiniPlayer, .newLibraryWindow
        ]),
        ("Aspect", [
            .setAspectRatioFit, .setAspectRatioFill,
            .setAspectRatioStretch, .setAspectRatioAuto
        ]),
        ("Analysis", [
            .toggleWaveform, .toggleVectorscope,
            .toggleHistogram, .toggleAudioMeters
        ])
    ]

    var body: some View {
        Form {
            ForEach(groups, id: \.0) { group in
                Section(group.0) {
                    ForEach(group.1, id: \.self) { action in
                        shortcutRow(for: action)
                    }
                }
            }

            Section {
                Button("Reset to Defaults") {
                    manager.resetToDefaults()
                }
            }
        }
        .padding()
        .frame(width: 480, height: 520)
    }

    @ViewBuilder
    private func shortcutRow(for action: PlayerAction) -> some View {
        let binding = manager.binding(for: action)
        let display = binding.map {
            ShortcutDisplayFormatter.displayString(key: $0.key, modifiers: $0.modifiers)
        } ?? "None"
        let isRecording = recordingAction == action

        HStack {
            Text(action.displayName)
                .frame(width: 180, alignment: .leading)

            if isRecording {
                Text("Press a key...")
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .leading)
            } else {
                Text(display)
                    .monospaced()
                    .frame(width: 80, alignment: .leading)
            }

            if let error = conflictError, isRecording {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()

            if isRecording {
                Button("Cancel") { stopRecording() }
            } else {
                Button("Record") { startRecording(for: action) }
            }
        }
        .padding(.vertical, 2)
    }

    private func startRecording(for action: PlayerAction) {
        conflictError = nil
        recordingAction = action
        KeyboardShortcutManager.isRecordingShortcut = true

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape
                stopRecording()
                return event
            }

            let keyName = PhysicalKeyResolver.keyString(for: event)
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // Ignore modifier-only presses
            let baseKeys: Set<String> = [
                "space", "return", "enter", "tab", "escape", "esc",
                "delete", "del", "uparrow", "downarrow", "leftarrow", "rightarrow",
                "home", "end", "pageup", "pagedown", "clear"
            ]
            let isSingleChar = keyName.count == 1
            guard isSingleChar || baseKeys.contains(keyName) else {
                return event
            }

            let candidate = KeyBinding(action: action, key: keyName, modifiers: mods)
            do {
                try manager.setBinding(candidate, for: action)
                stopRecording()
            } catch {
                conflictError = error.localizedDescription
                // Stay in recording state so user can try another key
            }

            return event
        }
    }

    private func stopRecording() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        recordingAction = nil
        KeyboardShortcutManager.isRecordingShortcut = false
        conflictError = nil
    }
}

private extension PlayerAction {
    var displayName: String {
        switch self {
        case .togglePlayPause:        return "Play / Pause"
        case .seekBackward10:         return "Skip Back 10s"
        case .seekForward10:          return "Skip Forward 10s"
        case .seekBackward60:         return "Skip Back 60s"
        case .seekForward60:          return "Skip Forward 60s"
        case .stepFrameForward:       return "Step Frame Forward"
        case .stepFrameBackward:      return "Step Frame Backward"
        case .volumeUp:               return "Volume Up"
        case .volumeDown:             return "Volume Down"
        case .toggleMute:             return "Mute"
        case .toggleFullscreen:       return "Toggle Full Screen"
        case .toggleMiniPlayer:       return "Mini Player"
        case .newLibraryWindow:       return "New Library Window"
        case .openFile:               return "Open File"
        case .setAspectRatioFit:      return "Aspect: Fit"
        case .setAspectRatioFill:     return "Aspect: Fill"
        case .setAspectRatioStretch:  return "Aspect: Stretch"
        case .setAspectRatioAuto:     return "Aspect: Auto"
        case .toggleSubtitles:        return "Toggle Subtitles"
        case .toggleHDR:              return "Toggle HDR"
        case .increasePlaybackRate:   return "Increase Rate"
        case .decreasePlaybackRate:   return "Decrease Rate"
        case .resetPlaybackRate:      return "Reset Rate"
        case .toggleWaveform:         return "Waveform"
        case .toggleVectorscope:      return "Vectorscope"
        case .toggleHistogram:        return "Histogram"
        case .toggleAudioMeters:      return "Audio Meters"
        }
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build` from `TitanPlayer/` directory.
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Shortcuts/ShortcutsPreferencesView.swift
git commit -m "Create ShortcutsPreferencesView with grouped action list and recording"
```

---

### Task 5: Add "Shortcuts" tab to `PreferencesWindow`

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/PreferencesWindow.swift`

- [ ] **Step 1: Add the Shortcuts tab**

In `PreferencesWindow.swift`, add the new tab inside the `TabView`:

**Before:**
```swift
var body: some Scene {
    Window("Preferences", id: "preferences") {
        TabView {
            TelemetryPreferencesView()
                .tabItem { Label("Privacy", systemImage: "lock") }
        }
    }
}
```

**After:**
```swift
var body: some Scene {
    Window("Preferences", id: "preferences") {
        TabView {
            TelemetryPreferencesView()
                .tabItem { Label("Privacy", systemImage: "lock") }
            ShortcutsPreferencesView()
                .tabItem { Label("Shortcuts", systemImage: "command") }
        }
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build` from `TitanPlayer/` directory.
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/PreferencesWindow.swift
git commit -m "Add Shortcuts tab to PreferencesWindow"
```

---

### Task 6: Write tests

**Files:**
- Modify: `TitanPlayer/Tests/Unit/KeyboardShortcutManagerTests.swift`

- [ ] **Step 1: Add test for rebind persists across instances**

Append to `KeyboardShortcutManagerTests.swift`:

```swift
func testRebindPersistsAcrossInstances() {
    let defaults = UserDefaults(suiteName: "test-rebind-persist-\(UUID())")!
    let mgr = KeyboardShortcutManager(defaults: defaults)
    try? mgr.setBinding(.init(action: .togglePlayPause, key: "x"), for: .togglePlayPause)
    let mgr2 = KeyboardShortcutManager(defaults: defaults)
    XCTAssertEqual(mgr2.binding(for: .togglePlayPause)?.key, "x")
}
```

- [ ] **Step 2: Add test for conflict rejection preserves original**

Append:

```swift
func testConflictRejectionPreservesOriginal() {
    let defaults = UserDefaults(suiteName: "test-conflict-preserve-\(UUID())")!
    let mgr = KeyboardShortcutManager(defaults: defaults)
    let originalKey = mgr.binding(for: .togglePlayPause)?.key
    XCTAssertThrowsError(try mgr.setBinding(
        .init(action: .togglePlayPause, key: "m"), for: .togglePlayPause)) { error in
        XCTAssertTrue((error as NSError).domain == "KeyboardShortcutManager")
    }
    XCTAssertEqual(mgr.binding(for: .togglePlayPause)?.key, originalKey)
    XCTAssertEqual(mgr.binding(for: .toggleMute)?.key, "m")
}
```

- [ ] **Step 3: Add test for reset to defaults**

Append:

```swift
func testResetToDefaults() {
    let defaults = UserDefaults(suiteName: "test-reset-\(UUID())")!
    let mgr = KeyboardShortcutManager(defaults: defaults)
    try? mgr.setBinding(.init(action: .togglePlayPause, key: "x"), for: .togglePlayPause)
    try? mgr.setBinding(.init(action: .toggleMute, key: "z"), for: .toggleMute)
    XCTAssertEqual(mgr.binding(for: .togglePlayPause)?.key, "x")
    XCTAssertEqual(mgr.binding(for: .toggleMute)?.key, "z")

    mgr.resetToDefaults()

    XCTAssertEqual(mgr.binding(for: .togglePlayPause)?.key, "space")
    XCTAssertEqual(mgr.binding(for: .toggleMute)?.key, "m")

    // Verify persistence
    let mgr2 = KeyboardShortcutManager(defaults: defaults)
    XCTAssertEqual(mgr2.binding(for: .togglePlayPause)?.key, "space")
    XCTAssertEqual(mgr2.binding(for: .toggleMute)?.key, "m")
}
```

- [ ] **Step 4: Verify build with tests**

Run: `swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: Empty output (no errors other than the environmental XCTest one).

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/Tests/Unit/KeyboardShortcutManagerTests.swift
git commit -m "Add tests for rebind persistence, conflict rejection, and reset-to-defaults"
```

---

### Task 7: Final build verification

- [ ] **Step 1: Full build**

Run: `swift build` from `TitanPlayer/` directory.
Expected: Build succeeds.

- [ ] **Step 2: Run all tests (if Xcode available)**

Run: `swift test` from `TitanPlayer/` directory.
Expected: All tests pass. If XCTest is unavailable (Command Line Tools only), verify with:
```bash
swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"
```
Expected: Empty output.

- [ ] **Step 3: Final commit (if any remaining changes)**

Check `git status` and commit any remaining uncommitted changes.
