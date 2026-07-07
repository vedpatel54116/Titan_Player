# Shortcuts Preferences Tab — Design Spec

**Date:** 2026-07-07  
**Status:** Approved  
**Scope:** Add a "Shortcuts" tab to the Preferences window for viewing and rebinding keyboard shortcuts.

---

## Problem

The README advertises "customizable keyboard shortcuts (30+)" and `KeyboardShortcutManager` fully supports rebinding with conflict detection, but `PreferencesWindow` only renders a single "Privacy" tab. There is no UI to view or change shortcuts.

## Goals

1. List every `PlayerAction` grouped by category (Playback / Window / Aspect / Analysis) with its current binding displayed as a human-readable string (e.g. "⌘F", "Space", "⌥1").
2. Each row has a "Record" button that captures the next keyDown as the candidate new binding.
3. On capture, call `shortcutManager.setBinding(candidate, for: action)`. If it throws (conflict), show an inline error naming the conflicting action; do NOT apply the change.
4. "Reset to Defaults" button restores `KeyboardShortcutManager.defaultBindings` for all actions and persists.
5. Recording monitor is disabled during recording so it doesn't intercept itself or dispatch a `PlayerAction`.

## Architecture

### Dependency Injection

`KeyboardShortcutManager` is a plain `@MainActor final class` (not `ObservableObject`). The `ShortcutsPreferencesView` creates its own instance using `UserDefaults.standard`. Both this instance and `PlaybackSession`'s instance read/write the same `defaultsKey` (`titanplayer.keybindings`) on `UserDefaults.standard`, so persisted bindings are shared.

### Recording Coordination

`PlaybackSession` has a local `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` monitor that dispatches `PlayerAction`s. While recording a shortcut in the preferences view, this monitor must not dispatch.

**Mechanism:** Add a `static var isRecordingShortcut = false` flag on `KeyboardShortcutManager`. The `PlaybackSession` monitor checks this flag before dispatching — if true, it returns the event unhandled. The `ShortcutsPreferencesView` sets this flag to `true` before starting recording and `false` when done.

### Key Display Formatting

A `ShortcutDisplayFormatter` utility converts `(key: String, modifiers: NSEvent.ModifierFlags)` into a human-readable string. It uses standard macOS symbols:

| Modifier | Symbol |
|----------|--------|
| `.command` | ⌘ |
| `.option` | ⌥ |
| `.shift` | ⇧ |
| `.control` | ⌃ |

Key names are formatted as: `"space"` → `"Space"`, `"leftarrow"` → `"←"`, `"rightarrow"` → `"→"`, `"uparrow"` → `"↑"`, `"downarrow"` → `"↓"`, single characters uppercased (e.g. `"f"` → `"F"`).

The formatting logic reuses the same key-name mapping as `KeyEquivalentResolver` but produces display strings instead of SwiftUI `KeyEquivalent` values.

## UI Layout

```
┌─ Preferences ──────────────────────────────────────┐
│ [Privacy] [Shortcuts]                               │
├─────────────────────────────────────────────────────┤
│                                                     │
│  Playback                                           │
│  ┌─────────────────────┬──────────┬────────┐       │
│  │ Play / Pause        │ Space    │ Record │       │
│  │ Skip Back 10s       │ ←        │ Record │       │
│  │ Skip Forward 10s    │ →        │ Record │       │
│  │ Skip Back 60s       │ ⌘←       │ Record │       │
│  │ Skip Forward 60s    │ ⌘→       │ Record │       │
│  │ Step Frame Forward  │ .        │ Record │       │
│  │ Step Frame Backward │ ,        │ Record │       │
│  │ Volume Up           │ ↑        │ Record │       │
│  │ Volume Down         │ ↓        │ Record │       │
│  │ Mute                │ M        │ Record │       │
│  │ Toggle Subtitles    │ V        │ Record │       │
│  │ Toggle HDR          │ H        │ Record │       │
│  │ Increase Rate       │ ]        │ Record │       │
│  │ Decrease Rate       │ [        │ Record │       │
│  │ Reset Rate          │ \        │ Record │       │
│  └─────────────────────┴──────────┴────────┘       │
│                                                     │
│  Window                                             │
│  ┌─────────────────────┬──────────┬────────┐       │
│  │ Open File           │ ⌘O       │ Record │       │
│  │ Toggle Full Screen  │ ⌘F       │ Record │       │
│  │ Mini Player         │ ⌘M       │ Record │       │
│  │ New Library Window  │ ⌘L       │ Record │       │
│  └─────────────────────┴──────────┴────────┘       │
│                                                     │
│  Aspect                                             │
│  ┌─────────────────────┬──────────┬────────┐       │
│  │ Fit                 │ ⌥1       │ Record │       │
│  │ Fill                │ ⌥2       │ Record │       │
│  │ Stretch             │ ⌥3       │ Record │       │
│  │ Auto                │ ⌥0       │ Record │       │
│  └─────────────────────┴──────────┴────────┘       │
│                                                     │
│  Analysis                                           │
│  ┌─────────────────────┬──────────┬────────┐       │
│  │ Waveform            │ 1        │ Record │       │
│  │ Vectorscope         │ 2        │ Record │       │
│  │ Histogram           │ 3        │ Record │       │
│  │ Audio Meters        │ 4        │ Record │       │
│  └─────────────────────┴──────────┴────────┘       │
│                                                     │
│                              [Reset to Defaults]    │
└─────────────────────────────────────────────────────┘
```

When a row is in recording state, the binding column shows "Press a key..." and the Record button becomes "Cancel".

## Files to Create / Modify

### New Files

| File | Purpose |
|------|---------|
| `UI/Shortcuts/ShortcutsPreferencesView.swift` | The full shortcuts preferences tab |
| `Tests/Unit/ShortcutsPreferencesViewTests.swift` | Tests for rebind, conflict, reset |

### Modified Files

| File | Change |
|------|--------|
| `UI/Shortcuts/KeyboardShortcutManager.swift` | Add `static var isRecordingShortcut = false` and `resetToDefaults()` method |
| `UI/Session/PlaybackSession.swift` | Check `KeyboardShortcutManager.isRecordingShortcut` in the monitor before dispatching (line ~446) |
| `UI/PreferencesWindow.swift` | Add "Shortcuts" tab to the `TabView` |

## Detailed Behavior

### Recording Flow

1. User clicks "Record" on a row → `recordingAction` state is set to that `PlayerAction`.
2. `isRecordingShortcut = true` is set globally.
3. A local `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` is created.
4. On keyDown:
   - If Escape: cancel recording (clear state, remove monitor, set `isRecordingShortcut = false`).
   - If modifier-only key (no base key): ignore, stay in recording state.
   - Otherwise: resolve via `PhysicalKeyResolver.keyString(for: event)`, attempt `setBinding`.
5. On conflict: store the error message (includes conflicting action name), stay in recording state so user can try another key. Do NOT apply the change.
6. On success: clear recording state, remove monitor, set `isRecordingShortcut = false`.
7. Monitor is removed in all cases (success, conflict, cancel) via a `defer` or explicit cleanup.

### Reset to Defaults

1. User clicks "Reset to Defaults".
2. Call `shortcutManager.resetToDefaults()` which resets in-memory bindings to `Self.defaultBindings` and persists to `UserDefaults.standard`.
3. The view re-reads bindings from the manager (triggers SwiftUI update via `@State`).

### Conflict Error Format

```
"⌘F is already assigned to Toggle Full Screen"
```

The error is shown inline below the row in red text while the row remains in recording state.

## Tests

Extend `KeyboardShortcutManagerTests.swift` with:

1. **`testRebindPersistsAcrossInstances`** — rebind an action, create a new manager instance, verify the new binding is loaded.
2. **`testConflictRejection`** — attempt to bind two actions to the same key+modifiers, verify the second throws and the first is unchanged.
3. **`testResetToDefaults`** — rebind some actions, call `resetToDefaults()`, verify all actions return to `defaultBindings`.

## Out of Scope

- "Swap" convenience (rebinding the conflicting action automatically) — nice-to-have, not required.
- Drag-and-drop reordering of shortcuts.
- Import/export of shortcut profiles.
