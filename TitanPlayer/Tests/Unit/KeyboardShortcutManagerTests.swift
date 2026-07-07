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

    func testRebindPersistsAcrossInstances() {
        let defaults = UserDefaults(suiteName: "test-rebind-persist-\(UUID())")!
        let mgr = KeyboardShortcutManager(defaults: defaults)
        try? mgr.setBinding(.init(action: .togglePlayPause, key: "x"), for: .togglePlayPause)
        let mgr2 = KeyboardShortcutManager(defaults: defaults)
        XCTAssertEqual(mgr2.binding(for: .togglePlayPause)?.key, "x")
    }

    func testConflictRejectionPreservesOriginal() {
        let defaults = UserDefaults(suiteName: "test-conflict-preserve-\(UUID())")!
        let mgr = KeyboardShortcutManager(defaults: defaults)
        let originalKey = mgr.binding(for: .togglePlayPause)?.key
        XCTAssertThrowsError(try mgr.setBinding(
            .init(action: .togglePlayPause, key: "m"), for: .togglePlayPause)) { error in
            XCTAssertEqual((error as NSError).domain, "KeyboardShortcutManager")
        }
        XCTAssertEqual(mgr.binding(for: .togglePlayPause)?.key, originalKey)
        XCTAssertEqual(mgr.binding(for: .toggleMute)?.key, "m")
    }

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

        let mgr2 = KeyboardShortcutManager(defaults: defaults)
        XCTAssertEqual(mgr2.binding(for: .togglePlayPause)?.key, "space")
        XCTAssertEqual(mgr2.binding(for: .toggleMute)?.key, "m")
    }
}
