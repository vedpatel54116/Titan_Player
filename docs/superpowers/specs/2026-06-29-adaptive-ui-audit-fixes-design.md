# Adaptive UI — Audit & Fix Design

## Goal

Resolve three spec-vs-code gaps in the Adaptive UI & Multi-Window feature
([spec](2026-06-27-adaptive-ui-multiwindow-design.md)),
so the implementation matches its own design and the Phase 4 / Prompt 7
validation criteria pass:

1. **Touch Bar wiring** — buttons and scrubber fire actions; reflect session state.
2. **Menu key equivalent visibility** — `TitanCommands` reads the current
   `KeyBinding` from `KeyboardShortcutManager`.
3. **Keyboard listener first-responder** — `KeyCaptureView` becomes the first
   responder so keys actually reach `keyDown(with:)`.

This is a focused reconciliation, not a redesign. The existing spec already
documents the intended behavior; we are bringing code into conformance.

---

## Change 1 — Touch Bar wiring

### Current state

`TitanPlayer/TitanPlayer/UI/TouchBar/TouchBarProvider.swift` builds the Touch
Bar items but constructs `NSButton(title: ..., target: nil, action: nil)` and
an `NSSlider` with `target: nil, action: nil`. Tapping them does nothing. The
`NSScrubber` has no data source.

That violates:

> Touch Bar: on supported hardware, controls appear **and reflect playback
> state** — Touch Bar is a nice-to-have; we do not over-invest.

and the validation criterion:

> Touch Bar controls work on supported hardware; inert elsewhere

### Fix

Replace `target: nil, action: nil` with concrete `Selector`-based targets
that route to a shared `TouchBarController` instance held by
`TouchBarHostView`. The controller owns a weak reference to the `PlaybackSession`
and exposes `@objc` methods:

```swift
@MainActor
final class TouchBarController: NSObject {
    weak var session: PlaybackSession?
    weak var hostView: NSView?

    @objc func togglePlayPause()    { session?.togglePlayPause() }
    @objc func skipBackward()       { Task { await session?.seekBackward() } }
    @objc func skipForward()        { Task { await session?.seekForward() } }
    @objc func openMini()           { /* openWindow(id: "mini") */ }
    @objc func volumeChanged(_ sender: NSSlider) { session?.setVolume(sender.floatValue) }
}
```

The `TouchBarDelegate.makeItemForIdentifier` builds each control with
`target: controller, action: #selector(...)`. The time label and play/pause
button are updated on each `draw(in:)` or, simpler, on each
`TouchBarProvider.updateNSView` (the representable already re-runs when
`@EnvironmentObject` values change).

The scrubber (`NSScrubber`) gets a simple `NSScrubberDataSource` whose number
of items equals `Int(session.duration)` and whose `viewForItem(at:)` produces
a tick label. Selection drives `session.seek(to:)` via the scrubber delegate.
Tick density is low enough (1 tick per second ≈ small) to keep it cheap; if
durations get huge, switch to minute-ticks. The scrubber is continuous
(`isContinuous = true`) for live drag seeking, throttled to ≤ 10Hz to avoid
swamping `seek()`.

The mini-mode Touch Bar (transport + time only) keeps the same controller
instance but the `openMini` button is omitted.

### Tests

`TouchBarControllerTests` (or `TouchBarProviderTests`) — exercise the
controller's selectors: mock `PlaybackSession` (a `MockSession: PlaybackSession`
or a smaller protocol), call each `@objc` method, assert forwarded calls.
Integration tests would need a live Touch Bar simulator (Xcode UI tests) and
are **not** in scope; covered manually per the spec's "manual verification"
section.

---

## Change 2 — Menu key equivalents

### Current state

`TitanCommands.swift` declares a few menu items like:

```swift
Button("Mini Player") { toggleMini() }
    .keyboardShortcut("m", modifiers: [.command])
```

and the rest have no visible shortcut at all. Per the spec:

> Each menu item shows its current key equivalent read from `shortcutManager`,
> so the displayed equivalent matches any `UserDefaults` override.

Today, if a user runs:
`defaults write com.titanplayer.TitanPlayer titanplayer.keybindings -data ...`
to remap, the menu still shows `⌘M` instead of the new binding.

### Fix

`TitanCommands` already holds `session: PlaybackSession`. Read bindings via
`session.shortcutManager.binding(for: action)`. Expose a helper that returns
a `(KeyEquivalent, modifiers)` tuple for any `PlayerAction`. SwiftUI's
`Button` accepts `.keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers)`,
so we construct equivalents from the `KeyBinding.key` string.

`KeyEquivalent` accepts `Character` and `KeyEquivalent.return / .escape / .space /
.upArrow / .downArrow / .leftArrow / .rightArrow` (etc.). `NSEvent.ModifierFlags`
maps to `EventModifiers` via `SwiftUI`'s `.option / .command / .control / .shift`
set.

```swift
private func shortcut(for action: PlayerAction) -> (key: KeyEquivalent, mods: EventModifiers)? {
    guard let b = session.shortcutManager.binding(for: action) else { return nil }
    guard let ke = keyEquivalent(for: b.key) else { return nil }
    return (ke, eventModifiers(from: b.modifiers))
}
```

The `dispatch` switch statement in `TitanCommands` currently only handles ~14
of the 23 cases; the rest silently no-op when hit. Fix by routing the menu
through the same `KeyListenerView.handle(_:)` logic (extract that switch into
a static function `PlayerActionDispatcher.dispatch(_ action:, session:)`
shared by both `KeyListenerView` and `TitanCommands`). `toggleMiniPlayer`,
`newLibraryWindow`, `openFile`, `seekForward60`, `seekBackward60`,
`stepFrameForward`, `stepFrameBackward`, `volumeUp`, `volumeDown`, and the
remaining cases all get wired consistently.

For menu items the spec lists (Fit/Fill/Stretch/Auto, Volume Up/Down, etc.),
the displayed keyboard shortcut is the equivalent from the manager; if no
binding exists, the menu simply omits `.keyboardShortcut(...)`.

### Tests

`TitanCommandsKeyEquivalentsTests` — verify:
- Given a manager with custom binding `togglePlayPause → "k"`, the `playbackMenu`
  returns a `KeyEquivalent("k")` for that action.
- A no-op action renders a `Button` with no `.keyboardShortcut`.
- Round-trip: a binding loaded from `UserDefaults` is reflected by the menu.

---

## Change 3 — Keyboard listener first-responder

### Current state

`PlayerView` adds the listener via:

```swift
Color.clear
    .background(KeyListenerView())
```

SwiftUI's `.background(_:)` places the NSView behind the SwiftUI hierarchy.
On its own it does **not** ask the system to make it first responder — the
window's normal first responder (usually the text field for the focused
SwiftUI control) wins. For many keys (arrows, letters, space) the system
sends them to the key window's first responder, which is rarely
`KeyCaptureView`. So a user pressing `space` while focused on a SwiftUI
`Slider` may never reach `keyDown`.

### Fix

Two complementary changes:

1. **Make `KeyCaptureView` actually request first responder.** On `viewDidMoveToWindow`
   (i.e., once it's in a window) schedule a `DispatchQueue.main.async` call to
   `window.makeFirstResponder(self)`. Idempotent — if a control legitimately
   needs focus later, it can re-take first responder; `keyDown` will then fire
   on the focused control, and our keys would still miss it. To handle the
   "I clicked into a Slider, then want space to play" case, also accept
   keyDown via a global NSEvent monitor installed in `PlaybackSession`
   (`NSEvent.addLocalMonitorForEvents`) so the player windows receive key
   events **regardless** of which subview is first responder.

2. **Fallback NSEvent monitor** — we already noted in the spec that
   "SwiftUI's onKeyPress covers most cases, but NSEvent monitoring is the
   reliable fallback for keys like space and arrows that SwiftUI sometimes
   swallows." Today we attempted only the SwiftUI/KeyView path and it is
   unreliable. Add `NSEvent.addLocalMonitorForEvents(matching: [.keyDown])`
   in `PlaybackSession.init`. The handler:

   - Reads `event.window`; if non-nil and the window belongs to a TitanPlayer
     scene (we identify via `window.identifier` matching the main/mini
     scenes), proceed.
   - Resolves the event to a `PlayerAction` via `shortcutManager`.
   - If matched, calls `PlayerActionDispatcher.dispatch(action, session:)`
     and returns `nil` from the monitor (consumes the event).
   - If unmatched, returns the event unchanged (lets the focused control
     handle it).

   Remove on `deinit` via `NSEvent.removeMonitor(_:)`.

This is two independent code paths for the same job — both correct — and
together they cover all common cases: `KeyCaptureView` covers arrow/letter
keys when nothing else is focused, the monitor covers space/enter/arrows
when a SwiftUI control has focus. Either path alone has known failure modes;
both together are robust.

### Tests

Unit-level: `NSEventMonitorTests` / `PlayerActionDispatcherTests`
- `PlayerActionDispatcher.dispatch(.togglePlayPause, session:)` calls
  `session.togglePlayPause()`.
- Dispatch tests for every `PlayerAction` case (table-driven).
- Build safety: confirm the monitor is created/removed in pairs (no leak) by
  checking `PlaySession.deinit` calls `removeMonitor`.

Manual verification per existing plan: launch the app, focus a slider,
press space → playback toggles. Without monitor: doesn't work.
With monitor: works. Press `→` while slider is focused → seek forward.

---

## Architecture impact

- **New file**: `TitanPlayer/UI/Shortcuts/PlayerActionDispatcher.swift`
  (extracted helper for both `KeyListenerView` and `TitanCommands`).
- **New file**: `TitanPlayer/Tests/Unit/PlayerActionDispatcherTests.swift`
  (table-driven per-action tests).
- **Modified**: `TitanPlayer/UI/TouchBar/TouchBarProvider.swift`
  (real targets/actions, basic scrubber, time/play button updates).
- **Modified**: `TitanPlayer/UI/Shortcuts/KeyListenerView.swift`
  (uses `PlayerActionDispatcher`).
- **Modified**: `TitanPlayer/UI/Shortcuts/TitanCommands.swift`
  (reads key equivalents from manager, fully routes through dispatcher).
- **Modified**: `TitanPlayer/UI/Session/PlaybackSession.swift`
  (adds local NSEvent monitor in init, removes in deinit).
- **Modified**: `TitanPlayer/UI/Views/PlayerView.swift` — keep `.background(KeyListenerView())`
  but the new first-responder logic and the global monitor make it robust.

No public API changes; no file moves; no new dependencies.

---

## Error handling & edge cases

- **Touch Bar unavailable**: `makeTouchBar()` is gated by AppKit — not
  called on hardware without a Touch Bar. Zero overhead elsewhere. **No
  new fallback path needed**.
- **User changes theme / remap during runtime**: the existing `TitanCommands`
  reads `session.shortcutManager` per render. SwiftUI re-evaluates
  `body` when `@EnvironmentObject` values change; we'll add an
  `@Published` count on the manager so `TitanCommands` re-reads the menu
  on remap. Touch Bar equivalent: `TouchBarProvider.updateNSView` is
  already called on every `@Published` change in the session; we trigger
  a `touchBar = makeTouchBar()` rebuild when the bindings list changes.
- **NSEvent monitor + already-handled event**: monitor returns `nil`
  only when the action is matched. Unmatched events are passed through
  so text inputs, table views, etc., continue to work.
- **Monitor + SwiftUI `onKeyPress`**: we are not adding `onKeyPress`
  here; we have one path (monitor) and a SwiftUI view-level fallback
  (`KeyCaptureView`). `onKeyPress` would be a third path — out of scope.
- **Window leak from NSEvent monitor**: hold the returned `Any?` token
  on the session, call `NSEvent.removeMonitor(_:)` in `deinit`.

---

## Validation after this change

Re-running the prompt's validation criteria:

- [ ] Controls auto-hide during playback — **already passing**
- [ ] Touch Bar controls work correctly — **passes after Change 1**
- [ ] Keyboard shortcuts function as expected — **passes after Change 3**
- [ ] Multi-window playback synchronization — **already passing**
- [ ] UI adapts to different screen sizes — **already passing**

Plus spec items:
- [ ] Menu items show key equivalents from `shortcutManager` — **passes after Change 2**
- [ ] UserDefaults overrides persist and reflect in menus — **passes after Change 2**

---

## Out of scope

- A SwiftUI `InspectorView` for HDR tone-map / brightness controls
  (already exists; not changing).
- Per-file `UserDefaults` persistence of `fitModeOverride` (mentioned in
  spec under "user override persists in UserDefaults keyed by the file
  URL"; current code does not do this. Leave for separate Phase 5 prompt
  — would grow scope.)
- `AppDelegate`-based `application(_:openURLs:)` for `openFile` from
  Finder double-click.
- NSWindowDelegate adjustments for window-restoration.
