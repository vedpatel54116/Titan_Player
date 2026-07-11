# Hardware Scan Code Keyboard Input — Design Spec

**Date:** 2026-07-07  
**Status:** Approved  
**Scope:** Replace the string-based keyboard input system with hardware-scan-code-based detection for full international keyboard layout support.

---

## Problem

The current keyboard input system stores key bindings as strings (e.g. `"space"`, `"m"`, `"leftarrow"`) resolved via `PhysicalKeyResolver` → `UCKeyTranslate`. While `PhysicalKeyResolver` already uses `event.keyCode` internally, the binding storage and matching layer uses string comparison, which introduces layout-dependent fragility. Menu items use `.keyboardShortcut()` modifiers that create a parallel dispatch path conflicting with the local event monitor. External gaming keyboards and non-QWERTY layouts (ISO, JIS) need true hardware-scan-code independence.

## Goals

1. Store bindings as `(keyCode: UInt16, modifiers: UInt16)` — hardware scan codes, not characters.
2. Match key events by comparing `event.keyCode` directly against stored scan codes.
3. Remove all `.keyboardShortcut()` modifiers from `TitanCommands` to eliminate dual-dispatch conflicts.
4. Add keyboard layout change detection and telemetry.
5. Handle key repeat via `NSEvent.isARepeat` for continuous seeking.
6. Support numeric keypad (keyCode 65-92) with NumLock awareness via `.numericPad` flag.
7. Auto-migrate existing string-based bindings to scan-code format on first launch.

---

## Architecture

### Approach: Pure Scan-Code

All key bindings are stored and matched as raw hardware scan codes. No string-based resolution in the hot path. Menu items have no `.keyboardShortcut()` modifiers — all keyboard input flows through a single pipeline:

```
NSEvent → KeyEventRouter (scan-code match) → PlayerActionDispatcher
```

### Data Model

**`KeyBinding` struct** (in `PlayerAction.swift`):

```swift
struct KeyBinding: Equatable, Codable {
    let action: PlayerAction
    let keyCode: UInt16
    let modifiers: UInt16  // NSEvent.ModifierFlags rawValue

    init(action: PlayerAction, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        self.action = action
        self.keyCode = keyCode
        self.modifiers = modifiers.rawValue
    }
}
```

Codable encoding uses `UInt16` for both fields. Old string-based format is detected by checking for `key: String` during decode and migrated automatically.

### Scan-Code Key Mapping

**`ScanCodeKeyMapper`** (new file, replaces `KeyEquivalentResolver`):

Static lookup table mapping scan codes to human-readable key names for UI display and `ShortcutDisplayFormatter`:

| Range | Keys |
|-------|------|
| 0-29 | Letters (A-Z) and digits (1-0) |
| 30-43 | Symbols: `]`, `O`, `U`, `[`, `I`, `P`, `L`, `J`, `'`, `K`, `;`, `\`, `,`, `/` |
| 44-50 | `M`, `.`, Tab, Space, `` ` ``, Delete |
| 51-63 | Escape, Command, Shift, Option, Control, RightShift, RightOption, RightControl, Fn |
| 64-84 | Numeric keypad: `.`, `*`, `+`, `-`, `/`, `=`, digits 0-9 |
| 85-126 | Function keys F1-F19, arrows, Home, End, PageUp, PageDown, Help, ForwardDelete |

Provides `keyName(for: UInt16) -> String?` for display formatting.

### Key Resolution

**`KeyEventRouter`** — simplified:

```swift
func action(for event: NSEvent) -> PlayerAction? {
    guard !isFirstResponderTextEditing(event: event) else { return nil }
    let code = event.keyCode
    let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
    for action in PlayerAction.allCases {
        guard let binding = shortcutManager.binding(for: action) else { continue }
        if binding.keyCode == code && binding.modifiers == mods {
            return action
        }
    }
    return nil
}
```

`.deviceIndependentFlagsMask` strips caps lock, num lock, and other device-dependent flags.

### Event Monitor

**`PlaybackSession` local monitor** — unchanged except removing the old string comparison:

```swift
keyMonitorToken = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
    // ... existing window identifier check ...
    if !KeyboardShortcutManager.isRecordingShortcut,
       let action = router.action(for: event) {
        dispatcher.dispatch(action)
        return nil
    }
    return event
}
```

**Key repeat**: The OS generates repeated `keyDown` events when a key is held. Each repeat dispatches the action (e.g. holding left arrow dispatches `seekBackward10` repeatedly at the system key-repeat rate). No special `isARepeat` handling needed — the existing `keyDown(with:)` and local monitor both fire on repeats.

**Numeric keypad**: Numpad keys have `.numericPad` in modifier flags. `.deviceIndependentFlagsMask` strips this, so numpad keys match their main keyboard equivalents. For future dedicated numpad actions, check `.contains(.numericPad)`.

### Menu Items

**`TitanCommands`** — remove all `.keyboardShortcut()` modifiers:

```swift
@ViewBuilder
private func menuButton(_ title: String, action: PlayerAction) -> some View {
    Button(title) { dispatcher.dispatch(action) }
}
```

Trade-off: Menu items no longer show keyboard shortcut indicators. The shortcuts still work via the local event monitor. The ShortcutsPreferencesView displays all bindings.

### Migration

**On first launch after update:**

1. Read old bindings from `titanplayer.keybindings` in UserDefaults.
2. Attempt to decode as old format (`[KeyBinding]` with `key: String`).
3. If old format detected: map each string key to its QWERTY scan code via a one-time lookup table.
4. Persist in new format (`keyCode: UInt16, modifiers: UInt16`).
5. Log migration completion.

**Old string → QWERTY scan code mapping:**

| String | QWERTY Scan Code |
|--------|-----------------|
| `"space"` | 49 |
| `"leftarrow"` | 123 |
| `"rightarrow"` | 124 |
| `"uparrow"` | 126 |
| `"downarrow"` | 125 |
| `"m"` | 46 |
| `"f"` | 3 |
| `"."` | 47 |
| `","` | 43 |
| `"["` | 33 |
| `"]"` | 30 |
| `"\\"` | 42 |
| `"1"` | 18 |
| `"2"` | 19 |
| `"3"` | 20 |
| `"0"` | 29 |
| Letters a-z | 0-12, 13-17, 31-32, 34-35, 37-38, 40, 45-46 |

### Layout Detection & Telemetry

**`KeyboardLayoutMonitor`** (new utility):

```swift
enum KeyboardLayoutMonitor {
    static var currentLayoutID: String = ""

    static func detectLayout() {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let id = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return }
        let layoutID = Unmanaged<CFString>.fromOpaque(id).takeUnretainedValue() as String
        if !currentLayoutID.isEmpty && layoutID != currentLayoutID {
            Logger.keyboard.info("Layout changed: \(self.currentLayoutID) → \(layoutID)")
        }
        currentLayoutID = layoutID
    }
}
```

**When to check:**
- On app launch (in `PlaybackSession` init, after key monitor setup)
- Optional: On `NSWorkspace.activeKeyboardApplicationDidChangeNotification` for runtime layout switches

**Logging:** Uses `Logger.keyboard.info` (one-time event convention per AGENTS.md).

### "Press Key to Bind" UI

**`ShortcutsPreferencesView`** — capture `keyCode` directly:

```swift
eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
    if event.keyCode == 53 {  // Escape
        stopRecording()
        return event
    }
    let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let candidate = KeyBinding(action: action, keyCode: event.keyCode, modifiers: mods)
    do {
        try resolvedManager.setBinding(candidate, for: action)
        stopRecording()
    } catch {
        conflictError = error.localizedDescription
    }
    return event
}
```

No character resolution needed — the raw scan code is stored directly.

### Display Formatting

**`ShortcutDisplayFormatter`** — updated to use scan codes:

```swift
static func displayString(keyCode: UInt16, modifiers: UInt16) -> String {
    var parts: [String] = []
    let flags = NSEvent.ModifierFlags(rawValue: modifiers)
    if flags.contains(.control) { parts.append("\u{2303}") }
    if flags.contains(.option)  { parts.append("\u{2325}") }
    if flags.contains(.shift)   { parts.append("\u{21E7}") }
    if flags.contains(.command) { parts.append("\u{2318}") }
    parts.append(ScanCodeKeyMapper.keyName(for: keyCode) ?? "?")
    return parts.joined()
}
```

---

## Files to Modify

| File | Change |
|------|--------|
| `UI/Shortcuts/PlayerAction.swift` | Replace `KeyBinding.key: String` with `keyCode: UInt16, modifiers: UInt16`. Update Codable. |
| `UI/Shortcuts/KeyboardShortcutManager.swift` | Update `defaultBindings` to use scan codes. Add migration logic. Update `setBinding` conflict detection. |
| `UI/Shortcuts/KeyEventRouter.swift` | Compare `event.keyCode` directly instead of string comparison. Remove `PhysicalKeyResolver` dependency. |
| `UI/Shortcuts/TitanCommands.swift` | Remove all `.keyboardShortcut()` modifiers. Remove `KeyEquivalentResolver` usage. |
| `UI/Shortcuts/ShortcutsPreferencesView.swift` | Capture `event.keyCode` directly in recording monitor. Update display formatting. |
| `UI/Shortcuts/ShortcutDisplayFormatter.swift` | Update to accept `(keyCode: UInt16, modifiers: UInt16)` instead of `(key: String, modifiers)`. |
| `UI/Session/PlaybackSession.swift` | Add `KeyboardLayoutMonitor.detectLayout()` call on init. |

**Note:** `PhysicalKeyResolver` is no longer called in the hot path (KeyEventRouter uses `event.keyCode` directly). It remains available for `UCKeyTranslate`-based character resolution if needed for future features, and its existing tests continue to validate correctness.

## Files to Create

| File | Purpose |
|------|---------|
| `UI/Shortcuts/ScanCodeKeyMapper.swift` | Static scan-code-to-key-name mapping + keyEquivalent conversion |
| `Core/Utilities/Keyboard/KeyboardLayoutMonitor.swift` | Layout change detection and telemetry |

## Files to Delete

| File | Reason |
|------|--------|
| `UI/Shortcuts/KeyEquivalentResolver.swift` | Replaced by `ScanCodeKeyMapper` |

## Files to Update (Tests)

| File | Change |
|------|--------|
| `Tests/Unit/KeyEquivalentResolverTests.swift` | Replace with `ScanCodeKeyMapperTests.swift` |
| `Tests/Unit/KeyboardShortcutManagerTests.swift` | Update to use scan-code-based `KeyBinding` |
| `Tests/Unit/KeyEventRouterTests.swift` | Update to match on `event.keyCode` directly |
| `Tests/Unit/PhysicalKeyResolverTests.swift` | Keep as-is (still validates `UCKeyTranslate` works) |

---

## Detailed Behavior

### Default Bindings (scan codes)

| Action | Scan Code | Key |
|--------|-----------|-----|
| togglePlayPause | 49 | Space |
| seekBackward10 | 123 | ← |
| seekForward10 | 124 | → |
| seekBackward60 | 123 | ← (with Cmd) |
| seekForward60 | 124 | → (with Cmd) |
| stepFrameForward | 47 | . |
| stepFrameBackward | 43 | , |
| volumeUp | 126 | ↑ |
| volumeDown | 125 | ↓ |
| toggleMute | 46 | M |
| toggleFullscreen | 3 | F (with Cmd) |
| toggleMiniPlayer | 46 | M (with Cmd) |
| newLibraryWindow | 38 | L (with Cmd) |
| openFile | 31 | O (with Cmd) |
| setAspectRatioFit | 18 | 1 (with Option) |
| setAspectRatioFill | 19 | 2 (with Option) |
| setAspectRatioStretch | 20 | 3 (with Option) |
| setAspectRatioAuto | 29 | 0 (with Option) |
| toggleSubtitles | 9 | V |
| toggleHDR | 4 | H |
| increasePlaybackRate | 30 | ] |
| decreasePlaybackRate | 33 | [ |
| resetPlaybackRate | 42 | \ |
| toggleWaveform | 18 | 1 |
| toggleVectorscope | 19 | 2 |
| toggleHistogram | 20 | 3 |
| toggleAudioMeters | 21 | 4 |

### Conflict Detection

Same as current: `setBinding` iterates all existing bindings and throws if `keyCode + modifiers` matches an existing binding for a different action.

### Reset to Defaults

`resetToDefaults()` replaces all in-memory bindings with `Self.defaultBindings` (scan-code format) and persists.

---

## Out of Scope

- "Swap" convenience (rebinding conflicting action automatically)
- Drag-and-drop reordering of shortcuts
- Import/export of shortcut profiles
- Numpad-specific dedicated bindings (future enhancement)
- Per-layout default bindings (current design uses QWERTY scan codes as defaults)
