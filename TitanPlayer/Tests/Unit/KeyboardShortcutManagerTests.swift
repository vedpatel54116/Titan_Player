import XCTest
import AppKit
@testable import TitanPlayer

@MainActor
final class KeyboardShortcutManagerTests: XCTestCase {
    func testDefaultBindingsLoadedWhenUserDefaultsEmpty() {
        let defaults = UserDefaults(suiteName: "test-empty-\(UUID())")!
        let mgr = KeyboardShortcutManager(defaults: defaults)
        XCTAssertNotNil(mgr.binding(for: .togglePlayPause))
        XCTAssertEqual(mgr.binding(for: .togglePlayPause)?.key, "space")
        XCTAssertEqual(mgr.binding(for: .toggleMute)?.key, "m")
        XCTAssertEqual(mgr.binding(for: .toggleFullscreen)?.modifiers, [.command])
    }

    func testCustomBindingsLoadedFromUserDefaults() throws {
        let defaults = UserDefaults(suiteName: "test-custom-\(UUID())")!
        let custom = [
            KeyBinding(action: .togglePlayPause, key: "k", modifiers: []),
            KeyBinding(action: .toggleMute, key: "n", modifiers: [])
        ]
        let data = try JSONEncoder().encode(custom)
        defaults.set(data, forKey: KeyboardShortcutManager.defaultsKey)

        let mgr = KeyboardShortcutManager(defaults: defaults)
        XCTAssertEqual(mgr.binding(for: .togglePlayPause)?.key, "k")
        XCTAssertEqual(mgr.binding(for: .toggleMute)?.key, "n")
        XCTAssertEqual(mgr.binding(for: .openFile)?.key, "o")
    }

    func testMalformedJSONFallsBackToDefaults() {
        let defaults = UserDefaults(suiteName: "test-malformed-\(UUID())")!
        defaults.set(Data("not-json".utf8), forKey: KeyboardShortcutManager.defaultsKey)
        let mgr = KeyboardShortcutManager(defaults: defaults)
        XCTAssertEqual(mgr.binding(for: .togglePlayPause)?.key, "space")
    }

    func testSetBindingPersistsAndReadsBack() {
        let defaults = UserDefaults(suiteName: "test-set-\(UUID())")!
        let mgr = KeyboardShortcutManager(defaults: defaults)
        try? mgr.setBinding(.init(action: .togglePlayPause, key: "p"), for: .togglePlayPause)
        XCTAssertEqual(mgr.binding(for: .togglePlayPause)?.key, "p")
        let mgr2 = KeyboardShortcutManager(defaults: defaults)
        XCTAssertEqual(mgr2.binding(for: .togglePlayPause)?.key, "p")
    }

    func testSetBindingRejectsConflict() {
        let defaults = UserDefaults(suiteName: "test-conflict-\(UUID())")!
        let mgr = KeyboardShortcutManager(defaults: defaults)
        XCTAssertThrowsError(try mgr.setBinding(
            .init(action: .togglePlayPause, key: "m"), for: .togglePlayPause))
        XCTAssertEqual(mgr.binding(for: .togglePlayPause)?.key, "space")
        XCTAssertEqual(mgr.binding(for: .toggleMute)?.key, "m")
    }
}
