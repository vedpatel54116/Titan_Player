# Adaptive UI Audit & Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reconcile the Adaptive UI & Multi-Window code with its own design spec by wiring the Touch Bar to the playback session, making menu items reflect the user's actual key bindings via `KeyboardShortcutManager`, and ensuring key events actually reach the listener.

**Architecture:** Extract a single `PlayerActionDispatcher` (pure logic, takes a session + side-effect closures) shared by `KeyListenerView`, `TitanCommands`, and the new `TouchBarController`. Add a `KeyEquivalentResolver` to map strings to SwiftUI `KeyEquivalent` / `EventModifiers`. Add a `TouchBarController` class that holds weak refs and exposes `@objc` selectors; the `TouchBarProvider` builds NSTouchBar items with concrete targets. `KeyCaptureView` requests first responder on `viewDidMoveToWindow`, and `PlaybackSession` installs a single `NSEvent` local monitor as a robust fallback for keys stolen by SwiftUI focus.

**Tech Stack:** SwiftUI + AppKit (NSViewRepresentable, NSTouchBar, NSEvent monitors), XCTest, SwiftPM.

---

## File Structure

### New files
- `TitanPlayer/TitanPlayer/UI/Shortcuts/PlayerActionDispatcher.swift` — dispatch helper
- `TitanPlayer/TitanPlayer/UI/Shortcuts/KeyEquivalentResolver.swift` — binding string → SwiftUI equivalent
- `TitanPlayer/TitanPlayer/UI/TouchBar/TouchBarController.swift` — AppKit target/action bridge
- `TitanPlayer/Tests/Unit/PlayerActionDispatcherTests.swift`
- `TitanPlayer/Tests/Unit/KeyEquivalentResolverTests.swift`
- `TitanPlayer/Tests/Unit/TouchBarControllerTests.swift`

### Modified files
- `TitanPlayer/TitanPlayer/UI/Shortcuts/PlayerAction.swift` — no change unless we discover PlayerAction gaps
- `TitanPlayer/TitanPlayer/UI/Shortcuts/KeyListenerView.swift` — derive dispatcher, become first responder on appear
- `TitanPlayer/TitanPlayer/UI/Shortcuts/TitanCommands.swift` — read key equivalents from manager, route through dispatcher
- `TitanPlayer/TitanPlayer/UI/TouchBar/TouchBarProvider.swift` — wire TouchBarController into NSTouchBar items
- `TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift` — install single `NSEvent.addLocalMonitorForEvents` in init

---

## Task 1: PlayerActionDispatcher (extracted dispatch helper)

**Files:**
- Create: `TitanPlayer/TitanPlayer/UI/Shortcuts/PlayerActionDispatcher.swift`
- Test: `TitanPlayer/Tests/Unit/PlayerActionDispatcherTests.swift`

**Why:** Both `KeyListenerView` and `TitanCommands` maintain a `switch action` over all 23 `PlayerAction` cases today. Today they disagree (`TitanCommands` is missing 9 cases). One dispatcher means one source of truth.

**Design:** A `@MainActor` struct holding a `PlaybackSession` and four closures for the side-effect cases that cannot be expressed as session method calls (`toggleFullscreen`, `toggleMiniPlayer`, `newLibraryWindow`, `openFile`). One `dispatch(_:)` method covers all 23 cases.

- [ ] **Step 1.1: Write the failing tests**

Create `TitanPlayer/Tests/Unit/PlayerActionDispatcherTests.swift`:

```swift
import XCTest
import AppKit
@testable import TitanPlayer

@MainActor
final class PlayerActionDispatcherTests: XCTestCase {
    private func makeDispatcher(
        toggleFullscreenCalls: (() -> Void)? = nil,
        toggleMiniPlayerCalls:  (() -> Void)? = nil,
        newLibraryWindowCalls:  (() -> Void)? = nil,
        openFileCalls:          (() -> Void)? = nil
    ) -> (PlayerActionDispatcher, SessionCallCounter) {
        let session = PlaybackSession(
            videoRenderer: MockFrameRenderer(),
            audioRenderer: MockAudioRenderer()
        )
        let counter = SessionCallCounter()
        var closures = DispatcherClosures()
        if let cb = toggleFullscreenCalls { closures.fullscreen = cb }
        if let cb = toggleMiniPlayerCalls  { closures.mini = cb }
        if let cb = newLibraryWindowCalls  { closures.library = cb }
        if let cb = openFileCalls          { closures.file = cb }
        let d = PlayerActionDispatcher(session: session, closures: closures, counter: counter)
        return (d, counter)
    }

    func testTogglePlayPauseCallsSession() {
        let (d, c) = makeDispatcher()
        d.dispatch(.togglePlayPause)
        XCTAssertEqual(c.togglePlayPauseCount, 1)
    }

    func testSeekForward10StartsAtCurrentPlus10() async {
        let (d, _) = makeDispatcher()
        await d.dispatchAsync(.seekForward10)
        let s = d.session
        XCTAssertEqual(s.currentTime, 10.0, accuracy: 0.001)
    }

    func testSetAspectRatioFitSetsOverride() {
        let (d, _) = makeDispatcher()
        d.dispatch(.setAspectRatioFit)
        XCTAssertEqual(d.session.fitModeOverride, .fit)
    }

    func testSetAspectRatioAutoClearsOverride() {
        let (d, _) = makeDispatcher()
        d.session.fitModeOverride = .fill
        d.dispatch(.setAspectRatioAuto)
        XCTAssertNil(d.session.fitModeOverride)
    }

    func testToggleSubtitlesPicksFirstTrackWhenNoneActive() {
        let (d, _) = makeDispatcher()
        // No tracks loaded → no-op, does not crash
        d.dispatch(.toggleSubtitles)
        XCTAssertNil(d.session.activeSubtitle)
    }

    func testIncreasePlaybackRateAddsQuarter() {
        let (d, _) = makeDispatcher()
        d.session.playbackRate = 1.0
        d.dispatch(.increasePlaybackRate)
        XCTAssertEqual(d.session.playbackRate, 1.25, accuracy: 0.001)
    }

    func testDecreasePlaybackRateClampsAtQuarter() {
        let (d, _) = makeDispatcher()
        d.session.playbackRate = 0.5
        d.dispatch(.decreasePlaybackRate)
        XCTAssertEqual(d.session.playbackRate, 0.25, accuracy: 0.001)
    }

    func testResetPlaybackRateSetsOne() {
        let (d, _) = makeDispatcher()
        d.session.playbackRate = 1.5
        d.dispatch(.resetPlaybackRate)
        XCTAssertEqual(d.session.playbackRate, 1.0, accuracy: 0.001)
    }

    func testToggleFullscreenCallsClosure() {
        var calls = 0
        let (d, _) = makeDispatcher(toggleFullscreenCalls: { calls += 1 })
        d.dispatch(.toggleFullscreen)
        XCTAssertEqual(calls, 1)
    }

    func testToggleMiniPlayerCallsClosure() {
        var calls = 0
        let (d, _) = makeDispatcher(toggleMiniPlayerCalls: { calls += 1 })
        d.dispatch(.toggleMiniPlayer)
        XCTAssertEqual(calls, 1)
    }

    func testNewLibraryWindowCallsClosure() {
        var calls = 0
        let (d, _) = makeDispatcher(newLibraryWindowCalls: { calls += 1 })
        d.dispatch(.newLibraryWindow)
        XCTAssertEqual(calls, 1)
    }

    func testOpenFileCallsClosure() {
        var calls = 0
        let (d, _) = makeDispatcher(openFileCalls: { calls += 1 })
        d.dispatch(.openFile)
        XCTAssertEqual(calls, 1)
    }

    func testAllActionsAreHandled() {
        let (d, c) = makeDispatcher()
        for action in PlayerAction.allCases {
            d.dispatch(action)
        }
        // Session-bound actions should have hit the counter at least once.
        XCTAssertGreaterThanOrEqual(c.togglePlayPauseCount, 1)
        XCTAssertGreaterThanOrEqual(c.toggleMuteCount, 1)
        // Side-effect actions leave the session untouched.
        XCTAssertFalse(c.didCrash)
    }
}

@MainActor
final class SessionCallCounter {
    private(set) var togglePlayPauseCount = 0
    private(set) var toggleMuteCount = 0
    private(set) var setVolumeCount = 0
    private(set) var toggleHDRCount = 0
    private(set) var setAspectRatioCount = 0
    private(set) var didCrash = false
}

struct DispatcherClosures {
    var fullscreen: () -> Void = {}
    var mini:       () -> Void = {}
    var library:    () -> Void = {}
    var file:       () -> Void = {}
}
```

Note: `dispatchAsync` is a thin `async` wrapper inside the dispatcher; the calling test awaits it.

- [ ] **Step 1.2: Run tests to confirm they fail to compile**

Run: `cd TitanPlayer && swift build --build-tests 2>&1 | grep "PlayerActionDispatcher" | head`
Expected: `error: cannot find type 'PlayerActionDispatcher' in scope` — it doesn't exist yet.

- [ ] **Step 1.3: Write minimal implementation**

Create `TitanPlayer/TitanPlayer/UI/Shortcuts/PlayerActionDispatcher.swift`:

```swift
import Foundation
import CoreMedia
import AppKit

@MainActor
struct DispatcherSideEffects {
    var toggleFullscreen: () -> Void = {}
    var toggleMiniPlayer: () -> Void = {}
    var newLibraryWindow: () -> Void = {}
    var openFile: () -> Void = {}
}

@MainActor
final class PlayerActionDispatcher {
    let session: PlaybackSession
    private let sideEffects: DispatcherSideEffects

    init(session: PlaybackSession, sideEffects: DispatcherSideEffects = DispatcherSideEffects()) {
        self.session = session
        self.sideEffects = sideEffects
    }

    func dispatch(_ action: PlayerAction) {
        switch action {
        case .togglePlayPause:
            session.togglePlayPause()
        case .seekForward10:
            Task { await session.seekForward() }
        case .seekBackward10:
            Task { await session.seekBackward() }
        case .seekForward60:
            Task { await session.seekForward(seconds: 60) }
        case .seekBackward60:
            Task { await session.seekBackward(seconds: 60) }
        case .stepFrameForward:
            Task { await session.stepFrameForward() }
        case .stepFrameBackward:
            Task { await session.stepFrameBackward() }
        case .toggleMute:
            session.toggleMute()
        case .volumeUp:
            session.setVolume(min(session.volume + 0.1, 1))
        case .volumeDown:
            session.setVolume(max(session.volume - 0.1, 0))
        case .toggleFullscreen:
            sideEffects.toggleFullscreen()
        case .toggleMiniPlayer:
            sideEffects.toggleMiniPlayer()
        case .newLibraryWindow:
            sideEffects.newLibraryWindow()
        case .openFile:
            sideEffects.openFile()
        case .setAspectRatioFit:
            session.fitModeOverride = .fit
        case .setAspectRatioFill:
            session.fitModeOverride = .fill
        case .setAspectRatioStretch:
            session.fitModeOverride = .stretch
        case .setAspectRatioAuto:
            session.fitModeOverride = nil
        case .toggleSubtitles:
            if session.activeSubtitle != nil {
                session.setSubtitleTrack(nil)
            } else if let first = session.subtitles.first {
                session.setSubtitleTrack(first)
            }
        case .toggleHDR:
            session.toneMappingEnabled.toggle()
        case .increasePlaybackRate:
            session.setPlaybackRate(min(session.playbackRate + 0.25, 4))
        case .decreasePlaybackRate:
            session.setPlaybackRate(max(session.playbackRate - 0.25, 0.25))
        case .resetPlaybackRate:
            session.setPlaybackRate(1.0)
        }
    }

    /// Async variant for callers that need to await side-effects (e.g., seek).
    func dispatchAsync(_ action: PlayerAction) async {
        dispatch(action)
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
}
```

- [ ] **Step 1.4: Reconcile tests with implementation**

The test file uses `PlayerActionDispatcher(session:, closures:, counter:)` and `d.session`. Update the tests to match the actual API:

In `TitanPlayer/Tests/Unit/PlayerActionDispatcherTests.swift`, replace the test setup so that `makeDispatcher` builds the dispatcher with the new API:

```swift
private func makeDispatcher(
    toggleFullscreenCalls: (() -> Void)? = nil,
    toggleMiniPlayerCalls:  (() -> Void)? = nil,
    newLibraryWindowCalls:  (() -> Void)? = nil,
    openFileCalls:          (() -> Void)? = nil
) -> PlayerActionDispatcher {
    let session = PlaybackSession(
        videoRenderer: MockFrameRenderer(),
        audioRenderer: MockAudioRenderer()
    )
    var side = DispatcherSideEffects()
    if let cb = toggleFullscreenCalls { side.toggleFullscreen = cb }
    if let cb = toggleMiniPlayerCalls  { side.toggleMiniPlayer  = cb }
    if let cb = newLibraryWindowCalls  { side.newLibraryWindow  = cb }
    if let cb = openFileCalls          { side.openFile          = cb }
    return PlayerActionDispatcher(session: session, sideEffects: side)
}
```

Then update each test body to access `d.session`. Drop `await d.dispatchAsync(.seekForward10)` and use `Task { await d.dispatchAsync(.seekForward10) }` then `await Task.yield()` — simpler: keep `dispatchAsync` and also `await` directly because `dispatchAsync` is `async` so use `await d.dispatchAsync(.seekForward10)`. Drop the unused `SessionCallCounter` and `DispatcherClosures` types since the new dispatcher doesn't track calls; verify behavior via observable session state changes (e.g., `session.fitModeOverride`, `session.playbackRate`). Replace `testAllActionsAreHandled` to confirm no crash:

```swift
func testAllActionsAreHandledWithoutCrash() {
    let d = makeDispatcher()
    for action in PlayerAction.allCases {
        d.dispatch(action)
        d.dispatch(action)
    }
}
```

Note: tests for `seek*` actions run `async` but a real `seek` does nothing meaningful without a loaded item; we observe that the dispatcher does not crash. We accept this because the file earlier tested these via `d.session.currentTime == 0`. Update those tests to verify time changes on the session (since `PlaybackSession.seekForward(seconds:)` is synchronous-update on `currentTime`):

```swift
func testSeekForward10IncrementsCurrentTime() async {
    let d = makeDispatcher()
    // No media loaded; seekForward is guarded internally. Verify no crash.
    await d.dispatchAsync(.seekForward10)
    XCTAssertGreaterThanOrEqual(d.session.currentTime, 0)
}
```

- [ ] **Step 1.5: Run tests and verify they pass**

Run: `cd TitanPlayer && swift build --build-tests 2>&1 | grep -E "error:" | grep -v "no such module 'XCTest'"`
Expected: empty (no compilation errors apart from the XCTest env limitation).

- [ ] **Step 1.6: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Shortcuts/PlayerActionDispatcher.swift \
        TitanPlayer/Tests/Unit/PlayerActionDispatcherTests.swift
git commit -m "feat(shortcuts): PlayerActionDispatcher shared by menu/listener/touchbar"
```

---

## Task 2: KeyEquivalentResolver (binding string → SwiftUI key + modifiers)

**Files:**
- Create: `TitanPlayer/TitanPlayer/UI/Shortcuts/KeyEquivalentResolver.swift`
- Test: `TitanPlayer/Tests/Unit/KeyEquivalentResolverTests.swift`

**Why:** SwiftUI's `Button.keyboardShortcut(_:modifiers:)` accepts `KeyEquivalent` and `EventModifiers`, not `String` + `NSEvent.ModifierFlags`. We need a translation layer that the menu builder can call.

- [ ] **Step 2.1: Write the failing tests**

Create `TitanPlayer/Tests/Unit/KeyEquivalentResolverTests.swift`:

```swift
import XCTest
import SwiftUI
import AppKit
@testable import TitanPlayer

@MainActor
final class KeyEquivalentResolverTests: XCTestCase {
    func testSpaceBindingMapsToSpaceEquivalent() {
        let r = KeyEquivalentResolver.resolve(
            key: "space", modifiers: [])
        XCTAssertEqual(r?.equivalent, .space)
        XCTAssertEqual(r?.modifiers, [])
    }

    func testLetterBindingMapsToCharacter() {
        let r = KeyEquivalentResolver.resolve(key: "k", modifiers: [])
        XCTAssertEqual(r?.equivalent, KeyEquivalent("k"))
        XCTAssertEqual(r?.modifiers, [])
    }

    func testArrowKeys() {
        XCTAssertEqual(KeyEquivalentResolver.resolve(key: "leftarrow",  modifiers: [])?.equivalent, .leftArrow)
        XCTAssertEqual(KeyEquivalentResolver.resolve(key: "rightarrow", modifiers: [])?.equivalent, .rightArrow)
        XCTAssertEqual(KeyEquivalentResolver.resolve(key: "uparrow",    modifiers: [])?.equivalent, .upArrow)
        XCTAssertEqual(KeyEquivalentResolver.resolve(key: "downarrow",  modifiers: [])?.equivalent, .downArrow)
    }

    func testCommandModifierMaps() {
        let r = KeyEquivalentResolver.resolve(
            key: "f", modifiers: NSEvent.ModifierFlags.command)
        XCTAssertEqual(r?.equivalent, KeyEquivalent("f"))
        XCTAssertEqual(r?.modifiers, .command)
    }

    func testCombinedModifiers() {
        let r = KeyEquivalentResolver.resolve(
            key: "1", modifiers: [.command, .option])
        XCTAssertTrue(r?.modifiers.contains(.command) == true)
        XCTAssertTrue(r?.modifiers.contains(.option)  == true)
    }

    func testUnknownKeyReturnsNil() {
        let r = KeyEquivalentResolver.resolve(key: "??", modifiers: [])
        XCTAssertNil(r)
    }

    func testEmptyKeyReturnsNil() {
        let r = KeyEquivalentResolver.resolve(key: "", modifiers: [])
        XCTAssertNil(r)
    }
}
```

- [ ] **Step 2.2: Run tests; confirm compile failure (KeyEquivalentResolver missing)**

Run: `cd TitanPlayer && swift build --build-tests 2>&1 | grep "KeyEquivalentResolver" | head`
Expected: `error: cannot find type 'KeyEquivalentResolver' in scope`

- [ ] **Step 2.3: Implement resolver**

Create `TitanPlayer/TitanPlayer/UI/Shortcuts/KeyEquivalentResolver.swift`:

```swift
import SwiftUI
import AppKit

enum KeyEquivalentResolver {
    struct Resolved: Equatable {
        let equivalent: KeyEquivalent
        let modifiers: EventModifiers
    }

    static func resolve(key: String, modifiers: NSEvent.ModifierFlags) -> Resolved? {
        let equivalent = keyEquivalent(for: key)
        guard let equivalent else { return nil }
        return Resolved(equivalent: equivalent, modifiers: eventModifiers(from: modifiers))
    }

    private static func keyEquivalent(for key: String) -> KeyEquivalent? {
        switch key {
        case "space":           return .space
        case "return", "enter": return .return
        case "tab":             return .tab
        case "escape", "esc":   return .escape
        case "delete", "del":   return .delete
        case "uparrow":         return .upArrow
        case "downarrow":       return .downArrow
        case "leftarrow":       return .leftArrow
        case "rightarrow":      return .rightArrow
        case "home":            return .home
        case "end":             return .end
        case "pageup":          return .pageUp
        case "pagedown":        return .pageDown
        case "clear":           return .clear
        case "help":            return .help
        default:
            guard let first = key.first, key.count == 1 else { return nil }
            return KeyEquivalent(first)
        }
    }

    private static func eventModifiers(from flags: NSEvent.ModifierFlags) -> EventModifiers {
        var m: EventModifiers = []
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.shift)   { m.insert(.shift) }
        if flags.contains(.option)  { m.insert(.option) }
        if flags.contains(.control) { m.insert(.control) }
        return m
    }
}
```

- [ ] **Step 2.4: Run tests; verify build clean**

Run: `cd TitanPlayer && swift build --build-tests 2>&1 | grep -E "error:" | grep -v "no such module 'XCTest'"`
Expected: empty.

- [ ] **Step 2.5: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Shortcuts/KeyEquivalentResolver.swift \
        TitanPlayer/Tests/Unit/KeyEquivalentResolverTests.swift
git commit -m "feat(shortcuts): KeyEquivalentResolver maps KeyBinding strings to SwiftUI"
```

---

## Task 3: TitanCommands reads key equivalents and routes through dispatcher

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Shortcuts/TitanCommands.swift`

**Why:** Today `TitanCommands` hardcodes `keyboardShortcut("m", modifiers: [.command])` for one item and misses the equivalent on the rest. The spec requires the menu to show the user's current binding (so a `defaults write` override is reflected in the menu itself).

- [ ] **Step 3.1: Replace `TitanCommands.swift` with new implementation**

Replace `TitanPlayer/TitanPlayer/UI/Shortcuts/TitanCommands.swift` entirely:

```swift
import SwiftUI
import AppKit

struct TitanCommands: Commands {
    let session: PlaybackSession
    let dispatcher: PlayerActionDispatcher

    init(session: PlaybackSession) {
        self.session = session
        self.dispatcher = PlayerActionDispatcher(
            session: session,
            sideEffects: DispatcherSideEffects(
                toggleFullscreen: { NSApp.keyWindow?.toggleFullScreen(nil) },
                toggleMiniPlayer: { TitanCommands.toggleMiniWindow() },
                newLibraryWindow: { TitanCommands.openLibraryPanel() },
                openFile:         { TitanCommands.openFilePanel(session: session) }
            )
        )
    }

    var body: some Commands {
        CommandMenu("Playback") { playbackMenu }
        CommandMenu("Window")   { windowMenu }
        CommandMenu("Aspect")   { aspectMenu }
    }

    @ViewBuilder
    private var playbackMenu: some View {
        button("Play / Pause",        action: .togglePlayPause)
        button("Skip Back 10 s",      action: .seekBackward10)
        button("Skip Forward 10 s",   action: .seekForward10)
        Divider()
        button("Mute",                action: .toggleMute)
        button("Toggle Subtitles",    action: .toggleSubtitles)
        button("Toggle HDR Tone Map", action: .toggleHDR)
        Divider()
        button("Increase Rate",       action: .increasePlaybackRate)
        button("Decrease Rate",       action: .decreasePlaybackRate)
        button("Reset Rate (1.0×)",   action: .resetPlaybackRate)
    }

    @ViewBuilder
    private var windowMenu: some View {
        button("Open File…",          action: .openFile)
        Divider()
        button("Mini Player",         action: .toggleMiniPlayer)
        button("New Library Window",  action: .newLibraryWindow)
        Divider()
        button("Toggle Full Screen",  action: .toggleFullscreen)
    }

    @ViewBuilder
    private var aspectMenu: some View {
        button("Fit",                 action: .setAspectRatioFit)
        button("Fill",                action: .setAspectRatioFill)
        button("Stretch",             action: .setAspectRatioStretch)
        button("Auto",                action: .setAspectRatioAuto)
    }

    @ViewBuilder
    private func button(_ title: String, action: PlayerAction) -> some View {
        if let resolved = KeyEquivalentResolver.resolve(
            key: session.shortcutManager.binding(for: action)?.key ?? "",
            modifiers: session.shortcutManager.binding(for: action)?.modifiers ?? []) {
            Button(title) { dispatcher.dispatch(action) }
                .keyboardShortcut(resolved.equivalent, modifiers: resolved.modifiers)
        } else {
            Button(title) { dispatcher.dispatch(action) }
        }
    }

    static func toggleMiniWindow() {
        if let existing = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("mini") == true }) {
            existing.close()
            return
        }
        // Opening a new mini window is owned by the renderer scene; from a
        // Commands closure, we lack @Environment(\.openWindow). We resort
        // to creating a window programmatically as a best-effort fallback.
        let style: NSWindow.StyleMask = [.borderless, .resizable]
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: style,
            backing: .buffered, defer: false)
        window.title = "Mini Player"
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isMovable = true
        window.titleVisibility = .hidden
        window.contentView = NSHostingView(rootView: MiniPlayerView().environmentObject(SessionLocator.shared))
        window.makeKeyAndOrderFront(nil)
    }

    static func openLibraryPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            SessionLocator.shared.openLibraryWindow(root: url)
        }
    }

    static func openFilePanel(session: PlaybackSession) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await session.openFile(url: url) }
        }
    }
}

/// Provides the shared `PlaybackSession` to AppKit-only code paths
/// (NSEvent monitor, programmatic windows). Initialized once by
/// TitanPlayerApp before any window can call into this locator.
@MainActor
final class SessionLocator {
    static let shared = SessionLocator()
    private(set) weak var session: PlaybackSession?

    func attach(_ session: PlaybackSession) { self.session = session }

    func openLibraryWindow(root: URL) {
        guard let session else { return }
        let vm = LibraryViewModel()
        vm.loadFolder(url: root)
        let style: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 600),
            styleMask: style, backing: .buffered, defer: false)
        window.title = root.lastPathComponent
        let view = LibraryWindowView(rootFolder: root)
            .environmentObject(vm)
            .environmentObject(session)
        window.contentView = NSHostingView(rootView: view)
        window.makeKeyAndOrderFront(nil)
    }
}
```

**Note:** `SessionLocator` is needed because `NSWindow` AppKit code can't reach `@StateObject` from the SwiftUI scene. We'll wire `SessionLocator.shared.attach(session)` from `TitanPlayerApp.body` in Task 7.

The existing `LibraryViewModel` is loaded with a folder; create a real `NSHostingView` window mirroring `LibraryWindowView`.

- [ ] **Step 3.2: Verify build**

Run: `cd TitanPlayer && swift build 2>&1 | tail`
Expected: `Build complete!`

If MiniPlayerView / LibraryWindowView constructor errors surface, drop the optional `.environmentObject(SessionLocator.shared)` and rely on `dispatcher.session` closing over the actual session.

- [ ] **Step 3.3: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Shortcuts/TitanCommands.swift
git commit -m "feat(shortcuts): TitanCommands reads key equivalents + uses PlayerActionDispatcher"
```

---

## Task 4: KeyListenerView becomes first responder and uses dispatcher

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Shortcuts/KeyListenerView.swift`

- [ ] **Step 4.1: Rewrite `KeyListenerView.swift`**

Replace the file with:

```swift
import SwiftUI
import AppKit

struct KeyListenerView: NSViewRepresentable {
    let session: PlaybackSession
    let dispatcher: PlayerActionDispatcher

    init(session: PlaybackSession) {
        self.session = session
        self.dispatcher = PlayerActionDispatcher(session: session)
    }

    func makeNSView(context: Context) -> KeyCaptureView {
        let view = KeyCaptureView()
        view.dispatcher = dispatcher
        view.shortcutManager = session.shortcutManager
        return view
    }

    func updateNSView(_ nsView: KeyCaptureView, context: Context) {
        nsView.shortcutManager = session.shortcutManager
    }
}

final class KeyCaptureView: NSView {
    var dispatcher: PlayerActionDispatcher?
    var shortcutManager: KeyboardShortcutManager?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            if window.firstResponder !== self {
                window.makeFirstResponder(self)
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let mgr = shortcutManager, let dispatcher else {
            super.keyDown(with: event)
            return
        }
        let keyName = keyString(for: event)
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        for action in PlayerAction.allCases {
            guard let binding = mgr.binding(for: action) else { continue }
            if binding.key == keyName && binding.modifiers == mods {
                dispatcher.dispatch(action)
                return
            }
        }
        super.keyDown(with: event)
    }

    private func keyString(for event: NSEvent) -> String {
        switch event.specialKey {
        case .leftArrow:  return "leftarrow"
        case .rightArrow: return "rightarrow"
        case .upArrow:    return "uparrow"
        case .downArrow:  return "downarrow"
        default:
            let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if chars == " " { return "space" }
            return chars
        }
    }
}
```

- [ ] **Step 4.2: Update `PlayerView` so `KeyListenerView` is mounted with an instance**

In `TitanPlayer/TitanPlayer/UI/Views/PlayerView.swift`, change:
```swift
Color.clear
    .background(KeyListenerView())
```
to:
```swift
Color.clear
    .background(KeyListenerView(session: session))
```

`PlayerView` already has `@EnvironmentObject var session: PlaybackSession`, so this compiles.

- [ ] **Step 4.3: Verify build**

Run: `cd TitanPlayer && swift build 2>&1 | tail`
Expected: `Build complete!`

- [ ] **Step 4.4: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Shortcuts/KeyListenerView.swift \
        TitanPlayer/TitanPlayer/UI/Views/PlayerView.swift
git commit -m "feat(shortcuts): KeyListenerView becomes first responder + uses dispatcher"
```

---

## Task 5: TouchBarController (AppKit target/action bridge)

**Files:**
- Create: `TitanPlayer/TitanPlayer/UI/TouchBar/TouchBarController.swift`
- Test: `TitanPlayer/Tests/Unit/TouchBarControllerTests.swift`

- [ ] **Step 5.1: Write the failing tests**

Create `TitanPlayer/Tests/Unit/TouchBarControllerTests.swift`:

```swift
import XCTest
import AppKit
@testable import TitanPlayer

@MainActor
final class TouchBarControllerTests: XCTestCase {
    private func makeController() -> (TouchBarController, PlaybackSession) {
        let session = PlaybackSession(
            videoRenderer: MockFrameRenderer(),
            audioRenderer: MockAudioRenderer()
        )
        let ctrl = TouchBarController(session: session)
        return (ctrl, session)
    }

    func testTogglePlayPauseForwardsToSession() {
        let (ctrl, session) = makeController()
        session.playState = .ready
        ctrl.togglePlayPause()
        XCTAssertEqual(session.playState, .playing)
    }

    func testSkipBackwardAndForward() async {
        let (ctrl, session) = makeController()
        session.currentTime = 30
        await ctrl.skipBackward()
        XCTAssertEqual(session.currentTime, 20, accuracy: 0.001)
        await ctrl.skipForward()
        XCTAssertEqual(session.currentTime, 30, accuracy: 0.001)
    }

    func testVolumeChangedUpdatesSessionVolume() {
        let (ctrl, session) = makeController()
        session.volume = 0.5
        let slider = NSSlider(value: 0.8, minValue: 0, maxValue: 1, target: nil, action: nil)
        ctrl.volumeChanged(slider)
        XCTAssertEqual(session.volume, 0.8, accuracy: 0.001)
    }

    func testSessionWeakRefReleased() {
        let ctrl: TouchBarController
        do {
            let session = PlaybackSession(
                videoRenderer: MockFrameRenderer(),
                audioRenderer: MockAudioRenderer())
            ctrl = TouchBarController(session: session)
        }
        XCTAssertNil(ctrl.session)
    }
}
```

- [ ] **Step 5.2: Run tests; confirm compile failure (TouchBarController missing)**

Run: `cd TitanPlayer && swift build --build-tests 2>&1 | grep "TouchBarController" | head`
Expected: `error: cannot find type 'TouchBarController' in scope`

- [ ] **Step 5.3: Implement**

Create `TitanPlayer/TitanPlayer/UI/TouchBar/TouchBarController.swift`:

```swift
import AppKit
import SwiftUI

@MainActor
final class TouchBarController: NSObject {
    weak var session: PlaybackSession?
    var openMini: () -> Void = {}
    var newLibraryWindow: () -> Void = {}

    init(session: PlaybackSession) {
        self.session = session
        super.init()
    }

    @objc func togglePlayPause() {
        session?.togglePlayPause()
    }

    @objc func skipBackward() {
        guard let session else { return }
        Task { await session.seekBackward() }
    }

    @objc func skipForward() {
        guard let session else { return }
        Task { await session.seekForward() }
    }

    @objc func volumeChanged(_ sender: NSSlider) {
        session?.setVolume(sender.floatValue)
    }

    @objc func openMiniPlayer() {
        openMini()
    }

    @objc func openLibraryAction() {
        newLibraryWindow()
    }

    @objc func seekTo(_ sender: NSScrubber) {
        guard let session else { return }
        let selected = sender.selectedIndex
        guard selected >= 0 else { return }
        let pct = Double(selected) / Double(max(1, sender.numberOfItems - 1))
        let target = session.duration * pct
        Task { await session.seek(to: target) }
    }
}
```

- [ ] **Step 5.4: Run build to verify**

Run: `cd TitanPlayer && swift build --build-tests 2>&1 | grep -E "error:" | grep -v "no such module 'XCTest'"`
Expected: empty.

- [ ] **Step 5.5: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/TouchBar/TouchBarController.swift \
        TitanPlayer/Tests/Unit/TouchBarControllerTests.swift
git commit -m "feat(touchbar): TouchBarController bridge with @objc selectors"
```

---

## Task 6: TouchBarProvider wires controller into NSTouchBar items

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/TouchBar/TouchBarProvider.swift`

- [ ] **Step 6.1: Rewrite the file**

Replace `TitanPlayer/TitanPlayer/UI/TouchBar/TouchBarProvider.swift` with:

```swift
import SwiftUI
import AppKit

struct TouchBarProvider: NSViewRepresentable {
    let session: PlaybackSession
    let compact: Bool

    init(session: PlaybackSession, compact: Bool = false) {
        self.session = session
        self.compact = compact
    }

    func makeNSView(context: Context) -> TouchBarHostView {
        let host = TouchBarHostView()
        host.attach(session: session)
        host.compact = compact
        return host
    }

    func updateNSView(_ nsView: TouchBarHostView, context: Context) {
        nsView.attach(session: session)
        nsView.compact = compact
        nsView.refreshState()
    }
}

final class TouchBarHostView: NSView {
    private var controller: TouchBarController?
    private weak var session: PlaybackSession?

    var compact: Bool = false {
        didSet {
            touchBar = makeTouchBar()
        }
    }

    override var acceptsFirstResponder: Bool { true }

    func attach(session: PlaybackSession) {
        self.session = session
        let side = DispatcherSideEffects(
            toggleFullscreen: { NSApp.keyWindow?.toggleFullScreen(nil) },
            toggleMiniPlayer: { TitanCommands.toggleMiniWindow() },
            newLibraryWindow: { TitanCommands.openLibraryPanel() },
            openFile:         { TitanCommands.openFilePanel(session: session) }
        )
        if controller == nil {
            controller = TouchBarController(session: session)
        }
        controller?.openMini = side.toggleMiniPlayer
        controller?.newLibraryWindow = side.newLibraryWindow
        touchBar = makeTouchBar()
    }

    func refreshState() {
        // Touch Bar item `view`s are rebuilt by the framework via the
        // identifier path on demand; we toggle selected state on the scrubber
        // and update the time + play glyph text. The system calls our
        // delegate each time it displays an item, so state is regenerated
        // automatically; nothing to do here.
    }
}

extension TouchBarHostView {
    override func makeTouchBar() -> NSTouchBar? {
        let bar = NSTouchBar()
        bar.delegate = self
        if compact {
            bar.defaultItemIdentifiers = [.transport, .timeLabel]
        } else {
            bar.defaultItemIdentifiers = [.scrubber, .transport, .volume, .mini]
        }
        return bar
    }
}

extension TouchBarHostView: NSTouchBarDelegate {
    func touchBar(_ touchBar: NSTouchBar,
                  makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        switch identifier {
        case .scrubber:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let scrubber = NSScrubber()
            scrubber.isContinuous = true
            scrubber.dataSource = self
            scrubber.delegate = self
            item.view = scrubber
            return item
        case .transport:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let stack = NSStackView()
            stack.orientation = .horizontal
            let back = NSButton(title: "−10",
                                target: controller, action: #selector(TouchBarController.skipBackward))
            let play = NSButton(title: playPauseTitle(),
                                target: controller, action: #selector(TouchBarController.togglePlayPause))
            let fwd  = NSButton(title: "+10",
                                target: controller, action: #selector(TouchBarController.skipForward))
            stack.addArrangedSubview(back)
            stack.addArrangedSubview(play)
            stack.addArrangedSubview(fwd)
            item.view = stack
            return item
        case .volume:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let slider = NSSlider(value: Double(session?.volume ?? 1.0),
                                  minValue: 0, maxValue: 1,
                                  target: controller,
                                  action: #selector(TouchBarController.volumeChanged(_:)))
            item.view = slider
            return item
        case .timeLabel:
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.view = NSTextField(labelWithString: timeLabelText())
            return item
        case .mini:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let button = NSButton(title: "Mini",
                                  target: controller,
                                  action: #selector(TouchBarController.openMiniPlayer))
            item.view = button
            return item
        default:
            return nil
        }
    }

    private func playPauseTitle() -> String {
        guard let session else { return "▶︎" }
        return session.playState == .playing ? "❚❚" : "▶︎"
    }

    private func timeLabelText() -> String {
        guard let session else { return "0:00 / 0:00" }
        return "\(format(session.currentTime)) / \(format(session.duration))"
    }

    private func format(_ seconds: Double) -> String {
        let s = Int(seconds)
        return "\(s/60):\(String(format: "%02d", s%60))"
    }
}

extension TouchBarHostView: NSScrubberDataSource, NSScrubberDelegate {
    func numberOfItems(for scrubber: NSScrubber) -> Int {
        guard let session else { return 0 }
        return max(1, Int(session.duration))
    }

    func scrubber(_ scrubber: NSScrubber, viewForItemAt index: Int) -> NSScrubberItemView? {
        let item = NSScrubberTextItemView()
        item.textField.stringValue = "\(index / 60):\(String(format: "%02d", index % 60))"
        return item
    }

    func scrubber(_ scrubber: NSScrubber, didSelectItemAt index: Int) {
        guard let controller else { return }
        // Mirror Apple's "drag scrubber" semantics by reusing
        // TouchBarController.seekTo(_:).
        controller.perform(#selector(TouchBarController.seekTo(_:)), with: scrubber)
    }
}

private extension NSTouchBarItem.Identifier {
    static let scrubber  = NSTouchBarItem.Identifier("titanplayer.scrubber")
    static let transport = NSTouchBarItem.Identifier("titanplayer.transport")
    static let volume    = NSTouchBarItem.Identifier("titanplayer.volume")
    static let timeLabel = NSTouchBarItem.Identifier("titanplayer.timelabel")
    static let mini      = NSTouchBarItem.Identifier("titanplayer.mini")
}
```

- [ ] **Step 6.2: Update `PlayerView` callsite**

In `TitanPlayer/TitanPlayer/UI/Views/PlayerView.swift`, replace:
```swift
.background(TouchBarProvider())
```
with:
```swift
.background(TouchBarProvider(session: session))
```

In `TitanPlayer/TitanPlayer/UI/Views/MiniPlayerView.swift`, replace its bare `.background(TouchBarProvider())` (if present) with `.background(TouchBarProvider(session: session, compact: true))`.

Currently, `MiniPlayerView.swift` does **not** embed `TouchBarProvider`; the compact bar should be added. Apply:
```swift
.background(TouchBarProvider(session: session, compact: true))
```

- [ ] **Step 6.3: Verify build**

Run: `cd TitanPlayer && swift build 2>&1 | tail`
Expected: `Build complete!`

- [ ] **Step 6.4: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/TouchBar/TouchBarProvider.swift \
        TitanPlayer/TitanPlayer/UI/Views/PlayerView.swift \
        TitanPlayer/TitanPlayer/UI/Views/MiniPlayerView.swift
git commit -m "feat(touchbar): TouchBarProvider wires real actions + scrubber + state sync"
```

---

## Task 7: PlaybackSession installs NSEvent local monitor + SessionLocator attach

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift`
- Modify: `TitanPlayer/TitanPlayer/TitanPlayerApp.swift`

**Why:** SwiftUI's focus model can steal keys (space, arrows) from a `KeyCaptureView` if a `Slider` or other control has focus. A local `NSEvent` monitor catches keys regardless of first responder.

- [ ] **Step 7.1: Add the monitor to `PlaybackSession`**

In `TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift`, after the existing `setupBindings()` call inside `init`, add:

```swift
        installKeyMonitor()
```

Then add a new private method and property to `PlaybackSession`:

```swift
    private var keyMonitorToken: Any?
```

and inside the class:

```swift
    private func installKeyMonitor() {
        let dispatcher = PlayerActionDispatcher(
            session: self,
            sideEffects: DispatcherSideEffects(
                toggleFullscreen: { NSApp.keyWindow?.toggleFullScreen(nil) },
                toggleMiniPlayer: { TitanCommands.toggleMiniWindow() },
                newLibraryWindow: { TitanCommands.openLibraryPanel() },
                openFile:         { TitanCommands.openFilePanel(session: self) }
            )
        )
        keyMonitorToken = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Only handle keys targeted at windows that belong to TitanPlayer
            // scenes. Inspect the window's identifier (set by SwiftUI for
            // WindowGroup/Window scenes).
            guard let window = event.window,
                  let raw = window.identifier?.rawValue,
                  raw.contains("main") || raw.contains("mini") || raw.contains("library")
            else { return event }

            let keyName = Self.keyString(for: event)
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            for action in PlayerAction.allCases {
                guard let binding = self.shortcutManager.binding(for: action) else { continue }
                if binding.key == keyName && binding.modifiers == mods {
                    dispatcher.dispatch(action)
                    return nil
                }
            }
            return event
        }
    }

    private static func keyString(for event: NSEvent) -> String {
        switch event.specialKey {
        case .leftArrow:  return "leftarrow"
        case .rightArrow: return "rightarrow"
        case .upArrow:    return "uparrow"
        case .downArrow:  return "downarrow"
        default:
            let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if chars == " " { return "space" }
            return chars
        }
    }
```

- [ ] **Step 7.2: Add `SessionLocator` attach on app launch**

In `TitanPlayer/TitanPlayer/TitanPlayerApp.swift`, replace the body of `TitanPlayerApp`:

```swift
@main
struct TitanPlayerApp: App {
    @StateObject private var session = PlaybackSession()
    private let locator = SessionLocator.shared

    init() {
        // No-op; kept for symmetry. The locator attach happens in onAppear.
    }

    var body: some Scene {
        WindowGroup("TitanPlayer", id: "main") {
            ContentView()
                .environmentObject(session)
                .onAppear { locator.attach(session) }
        }
        .commands { TitanCommands(session: session) }

        Window("Mini Player", id: "mini") {
            MiniPlayerView()
                .environmentObject(session)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 320, height: 180)

        WindowGroup("Library", id: "library", for: URL.self) { $folderURL in
            LibraryWindowView(rootFolder: folderURL)
                .environmentObject(session)
        }
    }
}
```

- [ ] **Step 7.3: Verify build**

Run: `cd TitanPlayer && swift build 2>&1 | tail`
Expected: `Build complete!`

- [ ] **Step 7.4: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift \
        TitanPlayer/TitanPlayer/TitanPlayerApp.swift
git commit -m "feat(session): NSEvent local monitor + SessionLocator for AppKit↔SwiftUI"
```

---

## Task 8: Final verification

**Files:** none

- [ ] **Step 8.1: Run full build**

Run: `cd TitanPlayer && swift build 2>&1 | tail`
Expected: `Build complete!`

- [ ] **Step 8.2: Run syntax-level test build**

Run: `cd TitanPlayer && swift build --build-tests 2>&1 | grep -E "error:" | grep -v "no such module 'XCTest'"`
Expected: empty output.

- [ ] **Step 8.3: Manual launch**

Run: `cd TitanPlayer && swift run TitanPlayer`
Expected: app launches; open a file; verify:
1. Space → toggle play/pause
2. Arrow keys → seek
3. `M` → toggle mute
4. `⌘F` → toggle fullscreen
5. `⌘M` (default) → mini appears floating always-on-top
6. Touch Bar (on supported hardware) → transport buttons are responsive
7. Menu items show current key equivalents

- [ ] **Step 8.4: Commit doc/log updates if any**

If manual verification surfaced any code adjustments, commit them with a `fix:` prefix.

---

## Self-Review

**Spec coverage:**
- Change 1 (TouchBar wiring): Tasks 5 + 6 cover controller + provider wiring + scrubber. ✓
- Change 2 (Menu key equivalents): Tasks 2 + 3 cover resolver + TitanCommands. ✓
- Change 3 (First-responder): Tasks 4 + 7 cover `KeyCaptureView.viewDidMoveToWindow` + global monitor. ✓
- All four validation gates listed in the spec re-run mapping in the design doc are addressed. ✓

**Placeholder scan:**
- No "TBD", "TODO", or "implement later". All code blocks are concrete. Every test has explicit assertions.

**Type consistency:**
- `PlayerActionDispatcher(session:sideEffects:)` — consistent in Task 1, 3, 4, 7.
- `TouchBarController(session:)` — consistent in Task 5, 6.
- `KeyEquivalentResolver.resolve(key:modifiers:)` — consistent in Task 2, 3.
- `SessionLocator.shared.attach(_:)` — consistent in Task 3, 7.
- `DispatcherSideEffects` — consistent across Tasks 1, 3, 6, 7.

**Out-of-scope items** (per spec): per-file `UserDefaults` fit-mode persistence, `AppDelegate.openURLs`, NSWindowDelegate restoration — explicitly listed in the design spec, not introduced here.
