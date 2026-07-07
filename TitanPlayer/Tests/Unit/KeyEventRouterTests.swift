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
