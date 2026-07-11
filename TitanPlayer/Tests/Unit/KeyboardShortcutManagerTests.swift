import XCTest
import AppKit
@testable import TitanPlayer

@MainActor
final class KeyboardShortcutManagerTests: XCTestCase {
    func testDefaultBindingsLoadedWhenUserDefaultsEmpty() {
        let defaults = UserDefaults(suiteName: "test-empty-\(UUID())")!
        let mgr = KeyboardShortcutManager(defaults: defaults)
        XCTAssertNotNil(mgr.binding(for: .togglePlayPause))
        XCTAssertEqual(mgr.binding(for: .togglePlayPause)?.keyCode, 49)  // Space
        XCTAssertEqual(mgr.binding(for: .toggleMute)?.keyCode, 46)       // M
        XCTAssertEqual(mgr.binding(for: .toggleFullscreen)?.modifiers, [.command])
    }

    func testCustomBindingsLoadedFromUserDefaults() throws {
        let defaults = UserDefaults(suiteName: "test-custom-\(UUID())")!
        let custom = [
            KeyBinding(action: .togglePlayPause, keyCode: 40),  // K
            KeyBinding(action: .toggleMute, keyCode: 45)        // N
        ]
        let data = try JSONEncoder().encode(custom)
        defaults.set(data, forKey: KeyboardShortcutManager.defaultsKey)

        let mgr = KeyboardShortcutManager(defaults: defaults)
        XCTAssertEqual(mgr.binding(for: .togglePlayPause)?.keyCode, 40)
        XCTAssertEqual(mgr.binding(for: .toggleMute)?.keyCode, 45)
        XCTAssertEqual(mgr.binding(for: .openFile)?.keyCode, 31)  // O
    }

    func testMalformedJSONFallsBackToDefaults() {
        let defaults = UserDefaults(suiteName: "test-malformed-\(UUID())")!
        defaults.set(Data("not-json".utf8), forKey: KeyboardShortcutManager.defaultsKey)
        let mgr = KeyboardShortcutManager(defaults: defaults)
        XCTAssertEqual(mgr.binding(for: .togglePlayPause)?.keyCode, 49)
    }

    func testSetBindingPersistsAndReadsBack() {
        let defaults = UserDefaults(suiteName: "test-set-\(UUID())")!
        let mgr = KeyboardShortcutManager(defaults: defaults)
        try? mgr.setBinding(.init(action: .togglePlayPause, keyCode: 35), for: .togglePlayPause)
        XCTAssertEqual(mgr.binding(for: .togglePlayPause)?.keyCode, 35)
        let mgr2 = KeyboardShortcutManager(defaults: defaults)
        XCTAssertEqual(mgr2.binding(for: .togglePlayPause)?.keyCode, 35)
    }

    func testSetBindingRejectsConflict() {
        let defaults = UserDefaults(suiteName: "test-conflict-\(UUID())")!
        let mgr = KeyboardShortcutManager(defaults: defaults)
        // Try to bind togglePlayPause to M (keyCode 46) — conflicts with toggleMute
        XCTAssertThrowsError(try mgr.setBinding(
            .init(action: .togglePlayPause, keyCode: 46), for: .togglePlayPause))
        XCTAssertEqual(mgr.binding(for: .togglePlayPause)?.keyCode, 49)  // Space
        XCTAssertEqual(mgr.binding(for: .toggleMute)?.keyCode, 46)       // M
    }

    func testRebindPersistsAcrossInstances() {
        let defaults = UserDefaults(suiteName: "test-rebind-persist-\(UUID())")!
        let mgr = KeyboardShortcutManager(defaults: defaults)
        try? mgr.setBinding(.init(action: .togglePlayPause, keyCode: 7), for: .togglePlayPause)  // X
        let mgr2 = KeyboardShortcutManager(defaults: defaults)
        XCTAssertEqual(mgr2.binding(for: .togglePlayPause)?.keyCode, 7)
    }

    func testConflictRejectionPreservesOriginal() {
        let defaults = UserDefaults(suiteName: "test-conflict-preserve-\(UUID())")!
        let mgr = KeyboardShortcutManager(defaults: defaults)
        let originalCode = mgr.binding(for: .togglePlayPause)?.keyCode
        // Try to bind togglePlayPause to M (keyCode 46) — conflicts with toggleMute
        XCTAssertThrowsError(try mgr.setBinding(
            .init(action: .togglePlayPause, keyCode: 46), for: .togglePlayPause)) { error in
            XCTAssertEqual((error as NSError).domain, "KeyboardShortcutManager")
        }
        XCTAssertEqual(mgr.binding(for: .togglePlayPause)?.keyCode, originalCode)
        XCTAssertEqual(mgr.binding(for: .toggleMute)?.keyCode, 46)  // M
    }

    func testResetToDefaults() {
        let defaults = UserDefaults(suiteName: "test-reset-\(UUID())")!
        let mgr = KeyboardShortcutManager(defaults: defaults)
        try? mgr.setBinding(.init(action: .togglePlayPause, keyCode: 7), for: .togglePlayPause)   // X
        try? mgr.setBinding(.init(action: .toggleMute, keyCode: 6), for: .toggleMute)             // Z
        XCTAssertEqual(mgr.binding(for: .togglePlayPause)?.keyCode, 7)
        XCTAssertEqual(mgr.binding(for: .toggleMute)?.keyCode, 6)

        mgr.resetToDefaults()

        XCTAssertEqual(mgr.binding(for: .togglePlayPause)?.keyCode, 49)  // Space
        XCTAssertEqual(mgr.binding(for: .toggleMute)?.keyCode, 46)       // M

        let mgr2 = KeyboardShortcutManager(defaults: defaults)
        XCTAssertEqual(mgr2.binding(for: .togglePlayPause)?.keyCode, 49)
        XCTAssertEqual(mgr2.binding(for: .toggleMute)?.keyCode, 46)
    }

    func testDefaultBindingsUseScanCodes() {
        let defaults = UserDefaults(suiteName: "test-defaults-sc-\(UUID())")!
        let mgr = KeyboardShortcutManager(defaults: defaults)
        XCTAssertEqual(mgr.binding(for: .togglePlayPause)?.keyCode, 49)  // Space
        XCTAssertEqual(mgr.binding(for: .seekBackward10)?.keyCode, 123)  // Left
        XCTAssertEqual(mgr.binding(for: .seekForward10)?.keyCode, 124)   // Right
        XCTAssertEqual(mgr.binding(for: .toggleMute)?.keyCode, 46)       // M
        XCTAssertEqual(mgr.binding(for: .toggleFullscreen)?.keyCode, 3)   // F
        XCTAssertEqual(mgr.binding(for: .toggleFullscreen)?.modifiers, .command)
    }

    func testMigratesStringBasedBindingsToScanCodeFormat() throws {
        let defaults = UserDefaults(suiteName: "test-migration-\(UUID())")!
        // Simulate old format bindings
        let oldBindings: [[String: Any]] = [
            ["action": "togglePlayPause", "key": "space", "modifiers": 0],
            ["action": "toggleMute", "key": "m", "modifiers": 0],
            ["action": "toggleFullscreen", "key": "f", "modifiers": 1048576],
        ]
        let data = try JSONSerialization.data(withJSONObject: oldBindings)
        defaults.set(data, forKey: KeyboardShortcutManager.defaultsKey)

        let mgr = KeyboardShortcutManager(defaults: defaults)

        // Should have migrated to scan-code format
        XCTAssertEqual(mgr.binding(for: .togglePlayPause)?.keyCode, 49)  // Space
        XCTAssertEqual(mgr.binding(for: .toggleMute)?.keyCode, 46)       // M
        XCTAssertEqual(mgr.binding(for: .toggleFullscreen)?.keyCode, 3)   // F
        XCTAssertEqual(mgr.binding(for: .toggleFullscreen)?.modifiers, .command)
    }
}
