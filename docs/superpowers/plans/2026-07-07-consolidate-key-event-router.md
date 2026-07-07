# Consolidate Key Event Matching into KeyEventRouter

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the duplicate NSEvent→PlayerAction matching logic that exists in `KeyCaptureView.keyDown` and `PlaybackSession.installKeyMonitor()` by extracting it into a single shared `KeyEventRouter` type.

**Architecture:** A new `KeyEventRouter` struct owns the key-string resolution + modifier masking + binding iteration. Both `KeyCaptureView` and `PlaybackSession` become thin call-sites that obtain an action from the router and dispatch it. The `PlaybackSession` local monitor remains authoritative (intercepts before first-responder chain); `KeyCaptureView.keyDown` becomes a fallback for responder-chain-only scenarios.

**Tech Stack:** Swift, AppKit (NSEvent), Swift Testing / XCTest

---

## File Map

| File | Action | Purpose |
|------|--------|---------|
| `TitanPlayer/UI/Shortcuts/KeyEventRouter.swift` | **Create** | Single source of truth for NSEvent→PlayerAction matching |
| `TitanPlayer/UI/Shortcuts/KeyListenerView.swift` | **Modify** | Replace inline matching with `KeyEventRouter` call |
| `TitanPlayer/UI/Session/PlaybackSession.swift` | **Modify** | Replace inline matching with `KeyEventRouter` call |
| `TitanPlayer/Tests/Unit/KeyEventRouterTests.swift` | **Create** | Tests for exact match, modifier mismatch, no binding, arrow keys |
| `TitanPlayer/Tests/Unit/PlayerActionDispatcherTests.swift` | **Modify** | Add a regression test ensuring router+dispatcher integration |

---

### Task 1: Create `KeyEventRouter` struct

**Files:**
- Create: `TitanPlayer/TitanPlayer/UI/Shortcuts/KeyEventRouter.swift`

- [ ] **Step 1: Write the `KeyEventRouter` implementation**

```swift
import AppKit

/// Single source of truth for resolving an `NSEvent` to a `PlayerAction`.
///
/// **Capture mechanism note:** The `PlaybackSession` local monitor
/// (`NSEvent.addLocalMonitorForEvents`) is authoritative — it intercepts
/// key-down events *before* the first-responder chain.  `KeyCaptureView`
/// keeps a thin `action(for:)` call as a fallback for the rare case where
/// the local monitor is not attached (e.g. during teardown) or the event
/// arrives via the responder chain only.
struct KeyEventRouter {
    let shortcutManager: KeyboardShortcutManager

    /// Resolve `event` to the matching `PlayerAction`, or `nil` if no
    /// binding matches.
    func action(for event: NSEvent) -> PlayerAction? {
        let keyName = PhysicalKeyResolver.keyString(for: event)
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        for action in PlayerAction.allCases {
            guard let binding = shortcutManager.binding(for: action) else { continue }
            if binding.key == keyName && binding.modifiers == mods {
                return action
            }
        }
        return nil
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build` from `TitanPlayer/`
Expected: Builds cleanly (new file is picked up by SwiftPM automatically since it lives under the target source tree).

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Shortcuts/KeyEventRouter.swift
git commit -m "feat(shortcuts): add KeyEventRouter — single NSEvent→PlayerAction resolver"
```

---

### Task 2: Simplify `KeyCaptureView` to use `KeyEventRouter`

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Shortcuts/KeyListenerView.swift`

- [ ] **Step 1: Replace inline matching in `KeyCaptureView.keyDown`**

Replace the current file contents with:

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
        let router = KeyEventRouter(shortcutManager: session.shortcutManager)
        let view = KeyCaptureView()
        view.dispatcher = dispatcher
        view.router = router
        return view
    }

    func updateNSView(_ nsView: KeyCaptureView, context: Context) {
        nsView.router = KeyEventRouter(shortcutManager: session.shortcutManager)
    }
}

final class KeyCaptureView: NSView {
    var dispatcher: PlayerActionDispatcher?
    var router: KeyEventRouter?

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
        guard let router, let dispatcher else {
            super.keyDown(with: event)
            return
        }
        if let action = router.action(for: event) {
            dispatcher.dispatch(action)
            return
        }
        super.keyDown(with: event)
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build` from `TitanPlayer/`
Expected: Builds cleanly.

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Shortcuts/KeyListenerView.swift
git commit -m "refactor(shortcuts): KeyCaptureView uses KeyEventRouter instead of inline matching"
```

---

### Task 3: Simplify `PlaybackSession.installKeyMonitor()` to use `KeyEventRouter`

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift`

- [ ] **Step 1: Replace inline matching in `installKeyMonitor()`**

Replace lines 417–456 of `PlaybackSession.swift` with:

```swift
    private func installKeyMonitor() {
        let side = DispatcherSideEffects(
            toggleFullscreen: { NSApp.keyWindow?.toggleFullScreen(nil) },
            toggleMiniPlayer: { [weak self] in
                guard let self else { return }
                SessionLocator.MiniWindowController.shared.toggle(
                    using: { _ in MiniPlayerView() },
                    session: self
                )
            },
            newLibraryWindow: { TitanCommands.openLibraryPanel() },
            openFile:         { TitanCommands.openFileUsingPanel(session: self) }
        )
        let dispatcher = PlayerActionDispatcher(session: self, sideEffects: side)
        let router = KeyEventRouter(shortcutManager: shortcutManager)

        keyMonitorToken = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard let window = event.window else { return event }
            let identifier = window.identifier?.rawValue ?? window.title
            let belongsToScene =
                identifier.contains("main")   ||
                identifier.contains("mini")   ||
                identifier.contains("Mini")   ||
                identifier.contains("Library") ||
                identifier.contains("library") ||
                identifier.contains("TitanPlayer")
            guard belongsToScene else { return event }

            if let action = router.action(for: event) {
                dispatcher.dispatch(action)
                return nil   // consumed
            }
            return event   // not consumed
        }
    }
```

- [ ] **Step 2: Verify build**

Run: `swift build` from `TitanPlayer/`
Expected: Builds cleanly.

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift
git commit -m "refactor(shortcuts): installKeyMonitor uses KeyEventRouter instead of inline matching"
```

---

### Task 4: Add `KeyEventRouterTests`

**Files:**
- Create: `TitanPlayer/TitanPlayer/Tests/Unit/KeyEventRouterTests.swift`

- [ ] **Step 1: Write the test file**

```swift
import XCTest
import AppKit
@testable import TitanPlayer

private struct FakeKeyResolver {
    /// Maps raw keyCode → resolved key string.  Used to inject values
    /// via `PhysicalKeyResolver.layoutProvider` without touching the
    /// real keyboard layout.
    let mapping: [UInt16: String]
}

@MainActor
final class KeyEventRouterTests: XCTestCase {

    // MARK: - Helpers

    private static let qwertyKeyCodes: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z",
        7: "x", 8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e",
        15: "r", 16: "y", 17: "t", 31: "o", 32: "u", 34: "i", 35: "p",
        37: "l", 38: "j", 40: "k", 45: "n", 46: "m"
    ]

    private func makeManager(
        bindings: [PlayerAction: KeyBinding] = KeyboardShortcutManager.defaultBindings
    ) -> KeyboardShortcutManager {
        let defaults = UserDefaults(suiteName: "router-test-\(UUID())")!
        let mgr = KeyboardShortcutManager(defaults: defaults)
        // Overwrite with the provided bindings
        for (_, b) in bindings {
            try? mgr.setBinding(b, for: b.action)
        }
        return mgr
    }

    private func makeEvent(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        characters: String = "x",
        charactersIgnoringModifiers: String = "x"
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    /// Run with `PhysicalKeyResolver.layoutProvider` overridden for the
    /// duration of `body`, then restore the original.
    private func withLayout<T>(_ provider: KeyboardLayoutProviding,
                               _ body: () throws -> T) rethrows -> T {
        let saved = PhysicalKeyResolver.layoutProvider
        PhysicalKeyResolver.layoutProvider = provider
        defer { PhysicalKeyResolver.layoutProvider = saved }
        return try body()
    }

    private func qwertyProvider() -> FakeKeyboardLayoutProvider {
        FakeKeyboardLayoutProvider(mapping: Self.qwertyKeyCodes)
    }

    // MARK: - Exact match

    func testSpaceBarMatchesTogglePlayPause() {
        let mgr = makeManager()
        let router = KeyEventRouter(shortcutManager: mgr)
        // keyCode 49 = space
        let event = makeEvent(keyCode: 49, characters: " ", charactersIgnoringModifiers: " ")

        let result = withLayout(qwertyProvider()) {
            router.action(for: event)
        }
        XCTAssertEqual(result, .togglePlayPause)
    }

    func testLetterMMatchesToggleMute() {
        let mgr = makeManager()
        let router = KeyEventRouter(shortcutManager: mgr)
        // keyCode 46 = m
        let event = makeEvent(keyCode: 46)

        let result = withLayout(qwertyProvider()) {
            router.action(for: event)
        }
        XCTAssertEqual(result, .toggleMute)
    }

    func testCommandFMatchesToggleFullscreen() {
        let mgr = makeManager()
        let router = KeyEventRouter(shortcutManager: mgr)
        // keyCode 3 = f, modifiers = .command
        let event = makeEvent(keyCode: 3, modifiers: .command)

        let result = withLayout(qwertyProvider()) {
            router.action(for: event)
        }
        XCTAssertEqual(result, .toggleFullscreen)
    }

    // MARK: - Modifier mismatch

    func testSpaceBarWithCommandDoesNotMatchTogglePlayPause() {
        let mgr = makeManager()
        let router = KeyEventRouter(shortcutManager: mgr)
        // space + command should NOT match togglePlayPause (which has no modifiers)
        let event = makeEvent(keyCode: 49, modifiers: .command,
                              characters: " ", charactersIgnoringModifiers: " ")

        let result = withLayout(qwertyProvider()) {
            router.action(for: event)
        }
        XCTAssertNil(result)
    }

    func testLetterFWithoutCommandDoesNotMatchToggleFullscreen() {
        let mgr = makeManager()
        let router = KeyEventRouter(shortcutManager: mgr)
        // f without command should NOT match toggleFullscreen
        let event = makeEvent(keyCode: 3)

        let result = withLayout(qwertyProvider()) {
            router.action(for: event)
        }
        XCTAssertNil(result)
    }

    // MARK: - No binding for an action

    func testUnboundKeyReturnsNil() {
        // Remove the default bindings so nothing matches
        let defaults = UserDefaults(suiteName: "router-empty-\(UUID())")!
        let mgr = KeyboardShortcutManager(defaults: defaults)
        let router = KeyEventRouter(shortcutManager: mgr)

        let event = makeEvent(keyCode: 49, characters: " ", charactersIgnoringModifiers: " ")

        let result = withLayout(qwertyProvider()) {
            router.action(for: event)
        }
        XCTAssertNil(result)
    }

    // MARK: - Arrow-key special-casing

    func testLeftArrowMatchesSeekBackward10() {
        let mgr = makeManager()
        let router = KeyEventRouter(shortcutManager: mgr)
        // keyCode 123 = left arrow
        let event = makeEvent(keyCode: 123, modifiers: [],
                              characters: "\u{F702}", charactersIgnoringModifiers: "\u{F702}")

        let result = withLayout(qwertyProvider()) {
            router.action(for: event)
        }
        XCTAssertEqual(result, .seekBackward10)
    }

    func testRightArrowMatchesSeekForward10() {
        let mgr = makeManager()
        let router = KeyEventRouter(shortcutManager: mgr)
        // keyCode 124 = right arrow
        let event = makeEvent(keyCode: 124, modifiers: [],
                              characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}")

        let result = withLayout(qwertyProvider()) {
            router.action(for: event)
        }
        XCTAssertEqual(result, .seekForward10)
    }

    func testCommandLeftArrowMatchesSeekBackward60() {
        let mgr = makeManager()
        let router = KeyEventRouter(shortcutManager: mgr)
        let event = makeEvent(keyCode: 123, modifiers: .command,
                              characters: "\u{F702}", charactersIgnoringModifiers: "\u{F702}")

        let result = withLayout(qwertyProvider()) {
            router.action(for: event)
        }
        XCTAssertEqual(result, .seekBackward60)
    }

    func testUpArrowMatchesVolumeUp() {
        let mgr = makeManager()
        let router = KeyEventRouter(shortcutManager: mgr)
        // keyCode 126 = up arrow
        let event = makeEvent(keyCode: 126, modifiers: [],
                              characters: "\u{F700}", charactersIgnoringModifiers: "\u{F700}")

        let result = withLayout(qwertyProvider()) {
            router.action(for: event)
        }
        XCTAssertEqual(result, .volumeUp)
    }

    func testDownArrowMatchesVolumeDown() {
        let mgr = makeManager()
        let router = KeyEventRouter(shortcutManager: mgr)
        // keyCode 125 = down arrow
        let event = makeEvent(keyCode: 125, modifiers: [],
                              characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}")

        let result = withLayout(qwertyProvider()) {
            router.action(for: event)
        }
        XCTAssertEqual(result, .volumeDown)
    }

    // MARK: - Modifier stripping edge case

    func testExtraModifiersBeyondBindingAreRejected() {
        let mgr = makeManager()
        let router = KeyEventRouter(shortcutManager: mgr)
        // 'f' is bound to toggleFullscreen with .command only.
        // Passing .command + .shift should NOT match.
        let event = makeEvent(keyCode: 3, modifiers: [.command, .shift])

        let result = withLayout(qwertyProvider()) {
            router.action(for: event)
        }
        XCTAssertNil(result)
    }

    // MARK: - Custom bindings

    func testCustomBindingRespected() {
        let defaults = UserDefaults(suiteName: "router-custom-\(UUID())")!
        let mgr = KeyboardShortcutManager(defaults: defaults)
        // Remap togglePlayPause from space to "p" (keyCode 35)
        try? mgr.setBinding(
            KeyBinding(action: .togglePlayPause, key: "p", modifiers: []),
            for: .togglePlayPause
        )
        let router = KeyEventRouter(shortcutManager: mgr)

        let spaceEvent = makeEvent(keyCode: 49, characters: " ", charactersIgnoringModifiers: " ")
        let pEvent = makeEvent(keyCode: 35)

        let resultSpace = withLayout(qwertyProvider()) {
            router.action(for: spaceEvent)
        }
        let resultP = withLayout(qwertyProvider()) {
            router.action(for: pEvent)
        }
        XCTAssertNil(resultSpace, "Old binding should no longer match")
        XCTAssertEqual(resultP, .togglePlayPause)
    }
}

// MARK: - Fake layout provider (same as PhysicalKeyResolverTests)

private struct FakeKeyboardLayoutProvider: KeyboardLayoutProviding {
    let mapping: [UInt16: String]

    func character(for keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String? {
        mapping[keyCode]
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: Empty output (no errors besides the known XCTest module issue).

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/Tests/Unit/KeyEventRouterTests.swift
git commit -m "test(shortcuts): add KeyEventRouterTests covering match, mismatch, arrows, custom bindings"
```

---

### Task 5: Add dispatcher integration regression test to `PlayerActionDispatcherTests`

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Tests/Unit/PlayerActionDispatcherTests.swift`

- [ ] **Step 1: Append a test that wires router → dispatcher**

Add this test method at the end of `PlayerActionDispatcherTests`:

```swift
    // MARK: - KeyEventRouter + Dispatcher integration

    func testRouterAndDispatcherIntegration() {
        let defaults = UserDefaults(suiteName: "integration-test-\(UUID())")!
        let mgr = KeyboardShortcutManager(defaults: defaults)
        let router = KeyEventRouter(shortcutManager: mgr)

        let session = PlaybackSession(videoRenderer: MockFrameRenderer())
        session.volume = 0.5
        var dispatched = false
        var side = DispatcherSideEffects()
        side.togglePlayPause = { dispatched = true }
        let dispatcher = PlayerActionDispatcher(session: session, sideEffects: side)

        // Simulate: press space (keyCode 49) → router resolves → dispatcher dispatches
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: " ", charactersIgnoringModifiers: " ",
            isARepeat: false, keyCode: 49
        )!

        let saved = PhysicalKeyResolver.layoutProvider
        let provider = FakeKeyboardLayoutProviderForIntegration()
        PhysicalKeyResolver.layoutProvider = provider
        defer { PhysicalKeyResolver.layoutProvider = saved }

        if let action = router.action(for: event) {
            dispatcher.dispatch(action)
        }
        XCTAssertTrue(dispatched, "togglePlayPause side-effect should have been called")
    }
}

// Shared fake for the integration test (appended outside the class)
private struct FakeKeyboardLayoutProviderForIntegration: KeyboardLayoutProviding {
    func character(for keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String? {
        switch keyCode {
        case 49: return " "
        default: return nil
        }
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: Empty output.

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/Tests/Unit/PlayerActionDispatcherTests.swift
git commit -m "test(shortcuts): add router+dispatcher integration regression test"
```

---

### Task 6: Full build verification

- [ ] **Step 1: Clean build**

Run from `TitanPlayer/`:
```bash
swift build 2>&1
```
Expected: `Build complete!` with no warnings related to the changed files.

- [ ] **Step 2: Run existing tests (if Xcode available)**

Run: `swift test` (requires full Xcode install per AGENTS.md).
If unavailable, run the fallback check:
```bash
swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"
```
Expected: Empty output.

- [ ] **Step 3: Final commit if needed**

If any fixes were required in Steps 1-2, commit them:
```bash
git add -A
git commit -m "fix(shortcuts): address build issues in KeyEventRouter consolidation"
```
