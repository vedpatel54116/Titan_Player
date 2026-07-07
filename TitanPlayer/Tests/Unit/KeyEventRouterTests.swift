import XCTest
import AppKit
@testable import TitanPlayer

@MainActor
final class KeyEventRouterTests: XCTestCase {

    // MARK: - Helpers

    private static let qwertyKeyCodes: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z",
        7: "x", 8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e",
        15: "r", 16: "y", 17: "t", 31: "o", 32: "u", 34: "i", 35: "p",
        37: "l", 38: "j", 40: "k", 45: "n", 46: "m"
    ]

    private func makeManager() -> KeyboardShortcutManager {
        let defaults = UserDefaults(suiteName: "router-test-\(UUID())")!
        return KeyboardShortcutManager(defaults: defaults)
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
        let event = makeEvent(keyCode: 49, characters: " ", charactersIgnoringModifiers: " ")

        let result = withLayout(qwertyProvider()) {
            router.action(for: event)
        }
        XCTAssertEqual(result, .togglePlayPause)
    }

    func testLetterMMatchesToggleMute() {
        let mgr = makeManager()
        let router = KeyEventRouter(shortcutManager: mgr)
        let event = makeEvent(keyCode: 46)

        let result = withLayout(qwertyProvider()) {
            router.action(for: event)
        }
        XCTAssertEqual(result, .toggleMute)
    }

    func testCommandFMatchesToggleFullscreen() {
        let mgr = makeManager()
        let router = KeyEventRouter(shortcutManager: mgr)
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
        let event = makeEvent(keyCode: 3)

        let result = withLayout(qwertyProvider()) {
            router.action(for: event)
        }
        XCTAssertNil(result)
    }

    // MARK: - No binding for an action

    func testUnboundKeyReturnsNil() {
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
        let event = makeEvent(keyCode: 3, modifiers: [.command, .shift])

        let result = withLayout(qwertyProvider()) {
            router.action(for: event)
        }
        XCTAssertNil(result)
    }

    // MARK: - Text-field focus passthrough

    /// When an NSTextView is first responder (e.g. user is typing in a
    /// search box or rename field), the router must return nil so the key
    /// event passes through to the text system.
    func testLetterMWithTextViewFirstResponderReturnsNil() {
        let mgr = makeManager()
        let router = KeyEventRouter(shortcutManager: mgr)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        window.contentView?.addSubview(textView)
        window.makeFirstResponder(textView)

        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "m", charactersIgnoringModifiers: "m",
            isARepeat: false, keyCode: 46
        )!

        let result = withLayout(qwertyProvider()) {
            router.action(for: event)
        }
        XCTAssertNil(result, "Should not dispatch when NSTextView is first responder")
    }

    /// When an NSTextField is being edited (its field editor is an
    /// NSTextView), the router must return nil.
    func testLetterMWithTextFieldEditingReturnsNil() {
        let mgr = makeManager()
        let router = KeyEventRouter(shortcutManager: mgr)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        window.contentView?.addSubview(textField)
        window.makeFirstResponder(textField)

        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "m", charactersIgnoringModifiers: "m",
            isARepeat: false, keyCode: 46
        )!

        let result = withLayout(qwertyProvider()) {
            router.action(for: event)
        }
        XCTAssertNil(result, "Should not dispatch when NSTextField field editor is active")
    }

    // MARK: - Custom bindings

    func testCustomBindingRespected() {
        let defaults = UserDefaults(suiteName: "router-custom-\(UUID())")!
        let mgr = KeyboardShortcutManager(defaults: defaults)
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

// MARK: - Fake layout provider

private struct FakeKeyboardLayoutProvider: KeyboardLayoutProviding {
    let mapping: [UInt16: String]

    func character(for keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String? {
        mapping[keyCode]
    }
}

// MARK: - Manual QA (if automated tests cannot fully verify)

/// The automated tests above exercise the first-responder guard with real
/// NSWindow/NSTextView/NSTextField instances.  For a full regression check,
/// perform the following manual steps:
///
/// 1. Open the Library window (Cmd+L) and click into the search field.
/// 2. Type "vlm" into the search field.  Expected: the literal text "vlm"
///    appears and NO subtitle toggle, mute toggle, or library-window
///    shortcut fires.
/// 3. Click outside the text field (e.g. on the player view) so the text
///    field loses first responder.
/// 4. Press "m" — expected: mute toggles.
/// 5. Press "v" — expected: subtitles toggle.
/// 6. Press Cmd+L — expected: a new Library window opens.
/// 7. Repeat in the main window's rename/relabel fields (if any).
