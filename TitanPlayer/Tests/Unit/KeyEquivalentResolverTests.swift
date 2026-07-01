import XCTest
import SwiftUI
import AppKit
@testable import TitanPlayer

@MainActor
final class KeyEquivalentResolverTests: XCTestCase {
    func testSpaceBindingMapsToSpaceEquivalent() {
        let r = KeyEquivalentResolver.resolve(key: "space", modifiers: [])
        XCTAssertEqual(r?.equivalent, .space)
        XCTAssertEqual(r?.modifiers, [])
    }

    func testLetterBindingMapsToLowercaseCharacter() {
        let r = KeyEquivalentResolver.resolve(key: "k", modifiers: [])
        XCTAssertEqual(r?.equivalent, KeyEquivalent("k"))
        XCTAssertEqual(r?.modifiers, [])
    }

    func testLeftArrowMaps() {
        let r = KeyEquivalentResolver.resolve(key: "leftarrow", modifiers: [])
        XCTAssertEqual(r?.equivalent, .leftArrow)
    }

    func testRightArrowMaps() {
        let r = KeyEquivalentResolver.resolve(key: "rightarrow", modifiers: [])
        XCTAssertEqual(r?.equivalent, .rightArrow)
    }

    func testUpArrowMaps() {
        let r = KeyEquivalentResolver.resolve(key: "uparrow", modifiers: [])
        XCTAssertEqual(r?.equivalent, .upArrow)
    }

    func testDownArrowMaps() {
        let r = KeyEquivalentResolver.resolve(key: "downarrow", modifiers: [])
        XCTAssertEqual(r?.equivalent, .downArrow)
    }

    func testReturnMapsToReturnEquivalent() {
        let r = KeyEquivalentResolver.resolve(key: "return", modifiers: [])
        XCTAssertEqual(r?.equivalent, .return)
    }

    func testEscapeMapsToEscapeEquivalent() {
        let r = KeyEquivalentResolver.resolve(key: "escape", modifiers: [])
        XCTAssertEqual(r?.equivalent, .escape)
    }

    func testTabMapsToTabEquivalent() {
        let r = KeyEquivalentResolver.resolve(key: "tab", modifiers: [])
        XCTAssertEqual(r?.equivalent, .tab)
    }

    func testDeleteMapsToDeleteEquivalent() {
        let r = KeyEquivalentResolver.resolve(key: "delete", modifiers: [])
        XCTAssertEqual(r?.equivalent, .delete)
    }

    func testCommandModifierMaps() {
        let r = KeyEquivalentResolver.resolve(
            key: "f", modifiers: NSEvent.ModifierFlags.command)
        XCTAssertEqual(r?.equivalent, KeyEquivalent("f"))
        XCTAssertTrue(r?.modifiers.contains(.command) == true)
        XCTAssertEqual(r?.modifiers, .command)
    }

    func testShiftModifierMaps() {
        let r = KeyEquivalentResolver.resolve(
            key: "k", modifiers: NSEvent.ModifierFlags.shift)
        XCTAssertEqual(r?.modifiers, .shift)
    }

    func testOptionModifierMaps() {
        let r = KeyEquivalentResolver.resolve(
            key: "1", modifiers: NSEvent.ModifierFlags.option)
        XCTAssertEqual(r?.modifiers, .option)
    }

    func testCombinedCommandOptionModifiers() {
        let r = KeyEquivalentResolver.resolve(
            key: "1", modifiers: [.command, .option])
        XCTAssertTrue(r?.modifiers.contains(.command) == true)
        XCTAssertTrue(r?.modifiers.contains(.option)  == true)
        XCTAssertFalse(r?.modifiers.contains(.shift)   == true)
        XCTAssertFalse(r?.modifiers.contains(.control) == true)
    }

    func testUnknownKeyReturnsNil() {
        let r = KeyEquivalentResolver.resolve(key: "??", modifiers: [])
        XCTAssertNil(r)
    }

    func testEmptyKeyReturnsNil() {
        let r = KeyEquivalentResolver.resolve(key: "", modifiers: [])
        XCTAssertNil(r)
    }

    func testNoModifiersProducesEmptySet() {
        let r = KeyEquivalentResolver.resolve(key: "m", modifiers: [])
        XCTAssertEqual(r?.modifiers, [])
    }
}
