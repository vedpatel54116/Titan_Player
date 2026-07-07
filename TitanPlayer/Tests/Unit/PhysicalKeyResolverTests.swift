import XCTest
import AppKit
@testable import TitanPlayer

private struct FakeKeyboardLayoutProvider: KeyboardLayoutProviding {
    let mapping: [UInt16: String]

    func character(for keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String? {
        mapping[keyCode]
    }
}

@MainActor
final class PhysicalKeyResolverTests: XCTestCase {

    private static let letterKeyCodes: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z",
        7: "x", 8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e",
        15: "r", 16: "y", 17: "t", 31: "o", 32: "u", 34: "i", 35: "p",
        37: "l", 38: "j", 40: "k", 45: "n", 46: "m"
    ]

    private static let digitKeyCodes: [UInt16: String] = [
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5",
        22: "6", 26: "7", 28: "8", 25: "9", 29: "0"
    ]

    private static let symbolKeyCodes: [UInt16: String] = [
        33: "[", 30: "]", 42: "\\", 43: ",", 44: "/", 47: ".", 39: "'", 41: ";"
    ]

    private static func qwertyLayout() -> FakeKeyboardLayoutProvider {
        var m: [UInt16: String] = [:]
        m.merge(letterKeyCodes) { _, new in new }
        m.merge(digitKeyCodes)  { _, new in new }
        m.merge(symbolKeyCodes) { _, new in new }
        return FakeKeyboardLayoutProvider(mapping: m)
    }

    private static func azertyLayout() -> FakeKeyboardLayoutProvider {
        var m: [UInt16: String] = [:]
        m[0] = "q";  m[1] = "s";  m[2] = "d";  m[3] = "f"
        m[4] = "h";  m[5] = "g";  m[6] = "z";  m[7] = "x"
        m[8] = "c";  m[9] = "v";  m[11] = "b"; m[12] = "a"
        m[13] = "z"; m[14] = "e"; m[15] = "r"; m[16] = "y"
        m[17] = "t"; m[31] = "o"; m[32] = "u"; m[34] = "i"
        m[35] = "p"; m[37] = "l"; m[38] = "m"; m[40] = "k"
        m[45] = "n"; m[46] = ","
        m.merge(digitKeyCodes) { _, new in new }
        m[33] = "$"; m[30] = "^"; m[42] = "*"; m[43] = "?"
        m[44] = "!"; m[47] = ";"; m[39] = "²"; m[41] = "ù"
        return FakeKeyboardLayoutProvider(mapping: m)
    }

    private static func qwertzLayout() -> FakeKeyboardLayoutProvider {
        var m: [UInt16: String] = [:]
        m[0] = "q";  m[1] = "w";  m[2] = "e";  m[3] = "r"
        m[4] = "t";  m[5] = "z";  m[6] = "y";  m[7] = "x"
        m[8] = "c";  m[9] = "v";  m[11] = "b"; m[12] = "y"
        m[13] = "x"; m[14] = "e"; m[15] = "r"; m[16] = "z"
        m[17] = "t"; m[31] = "o"; m[32] = "u"; m[34] = "i"
        m[35] = "o"; m[37] = "l"; m[38] = "k"; m[40] = "j"
        m[45] = "n"; m[46] = "m"; m.merge(digitKeyCodes) { _, new in new }
        m[33] = "ü"; m[30] = "¨"; m[42] = "'"; m[43] = ","
        m[44] = "-"; m[47] = "."; m[39] = "²"; m[41] = "ö"
        return FakeKeyboardLayoutProvider(mapping: m)
    }

    private static func dvorakLayout() -> FakeKeyboardLayoutProvider {
        var m: [UInt16: String] = [:]
        m[0] = "a";  m[1] = "o";  m[2] = "e";  m[3] = "u"
        m[4] = "d";  m[5] = "i";  m[6] = ";";  m[7] = "q"
        m[8] = "j";  m[9] = "k";  m[11] = "x"; m[12] = "'"
        m[13] = ","; m[14] = "."; m[15] = "p"; m[16] = "y"
        m[17] = "f"; m[31] = "r"; m[32] = "g"; m[34] = "c"
        m[35] = "l"; m[37] = "n"; m[38] = "m"; m[40] = "h"
        m[45] = "b"; m[46] = "w"; m.merge(digitKeyCodes) { _, new in new }
        m[33] = "["; m[30] = "]"; m[42] = "\\"; m[43] = "w"
        m[44] = "z"; m[47] = "/"; m[39] = "`"; m[41] = "'"
        return FakeKeyboardLayoutProvider(mapping: m)
    }

    private static func russianLayout() -> FakeKeyboardLayoutProvider {
        var m: [UInt16: String] = [:]
        m[0] = "ф";  m[1] = "ы";  m[2] = "в";  m[3] = "а"
        m[4] = "р";  m[5] = "о";  m[6] = "я";  m[7] = "ч"
        m[8] = "с";  m[9] = "м";  m[11] = "и"; m[12] = "й"
        m[13] = "ц"; m[14] = "у"; m[15] = "к"; m[16] = "е"
        m[17] = "н"; m[31] = "ш"; m[32] = "г"; m[34] = "д"
        m[35] = "п"; m[37] = "б"; m[38] = "л"; m[40] = "ж"
        m[45] = "т"; m[46] = "ь"; m.merge(digitKeyCodes) { _, new in new }
        return FakeKeyboardLayoutProvider(mapping: m)
    }

    private func makeEvent(keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "x",
            charactersIgnoringModifiers: "x",
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    private func resolve(event: NSEvent, provider: KeyboardLayoutProviding) -> String {
        let saved = PhysicalKeyResolver.layoutProvider
        PhysicalKeyResolver.layoutProvider = provider
        defer { PhysicalKeyResolver.layoutProvider = saved }
        return PhysicalKeyResolver.keyString(for: event)
    }

    // MARK: - Physical key "m" (keyCode 46) always resolves the same across layouts

    func testPhysicalMKeyResolvesSameAcrossLayouts() {
        let keyCode: UInt16 = 46
        let event = makeEvent(keyCode: keyCode)

        let qwerty  = Self.qwertyLayout()
        let azerty  = Self.azertyLayout()
        let qwertz  = Self.qwertzLayout()
        let dvorak  = Self.dvorakLayout()
        let russian = Self.russianLayout()

        let rQwerty  = resolve(event: event, provider: qwerty)
        let rAzerty  = resolve(event: event, provider: azerty)
        let rQwertz  = resolve(event: event, provider: qwertz)
        let rDvorak  = resolve(event: event, provider: dvorak)
        let rRussian = resolve(event: event, provider: russian)

        XCTAssertEqual(rQwerty,  "m")
        XCTAssertEqual(rAzerty,  ",")
        XCTAssertEqual(rQwertz,  "m")
        XCTAssertEqual(rDvorak,  "w")
        XCTAssertEqual(rRussian, "ь")
    }

    func testPhysicalMKeyCode46OnQWERTYIsAlwaysM() {
        let keyCode: UInt16 = 46
        let event = makeEvent(keyCode: keyCode)
        let providers: [String: KeyboardLayoutProviding] = [
            "QWERTY": Self.qwertyLayout(),
            "AZERTY": Self.azertyLayout(),
            "QWERTZ": Self.qwertzLayout(),
            "Dvorak": Self.dvorakLayout(),
            "Russian": Self.russianLayout(),
        ]

        let qwertyResult = resolve(event: event, provider: Self.qwertyLayout())
        XCTAssertEqual(qwertyResult, "m")

        for (name, provider) in providers {
            let result = resolve(event: event, provider: provider)
            XCTAssertEqual(result, "m",
                "keyCode 46 should resolve to 'm' on QWERTY layout, got '\(result)' on \(name)")
        }
    }

    func testPhysicalKeyCode46ResolvesToSameAsQWERTYOnAllLayouts() {
        let keyCode: UInt16 = 46
        let event = makeEvent(keyCode: keyCode)
        let qwerty = Self.qwertyLayout()
        let providers: [String: KeyboardLayoutProviding] = [
            "AZERTY": Self.azertyLayout(),
            "QWERTZ": Self.qwertzLayout(),
            "Dvorak": Self.dvorakLayout(),
            "Russian": Self.russianLayout(),
        ]

        let expected = resolve(event: event, provider: qwerty)
        XCTAssertEqual(expected, "m")

        for (name, provider) in providers {
            let result = resolve(event: event, provider: provider)
            XCTAssertEqual(result, expected,
                "keyCode 46 should resolve to '\(expected)' regardless of active layout, got '\(result)' on \(name)")
        }
    }

    // MARK: - Letter keys resolve to stable strings

    func testAllLetterKeyCodesResolveStablyAcrossLayouts() {
        let qwerty = Self.qwertyLayout()
        let layouts: [String: KeyboardLayoutProviding] = [
            "AZERTY": Self.azertyLayout(),
            "QWERTZ": Self.qwertzLayout(),
            "Dvorak": Self.dvorakLayout(),
            "Russian": Self.russianLayout(),
        ]

        for (keyCode, qwertyChar) in Self.letterKeyCodes {
            let event = makeEvent(keyCode: keyCode)
            let qwertyResult = resolve(event: event, provider: qwerty)
            XCTAssertEqual(qwertyResult, qwertyChar,
                "QWERTY keyCode \(keyCode) should resolve to '\(qwertyChar)'")

            for (name, layout) in layouts {
                let result = resolve(event: event, provider: layout)
                XCTAssertEqual(result, qwertyChar,
                    "keyCode \(keyCode) should resolve to '\(qwertyChar)' on \(name), got '\(result)'")
            }
        }
    }

    // MARK: - Digit keys resolve to stable strings

    func testAllDigitKeyCodesResolveStablyAcrossLayouts() {
        let qwerty = Self.qwertyLayout()
        let layouts: [String: KeyboardLayoutProviding] = [
            "AZERTY": Self.azertyLayout(),
            "QWERTZ": Self.qwertzLayout(),
            "Dvorak": Self.dvorakLayout(),
        ]

        for (keyCode, qwertyChar) in Self.digitKeyCodes {
            let event = makeEvent(keyCode: keyCode)
            let qwertyResult = resolve(event: event, provider: qwerty)
            XCTAssertEqual(qwertyResult, qwertyChar,
                "QWERTY keyCode \(keyCode) should resolve to '\(qwertyChar)'")

            for (name, layout) in layouts {
                let result = resolve(event: event, provider: layout)
                XCTAssertEqual(result, qwertyChar,
                    "keyCode \(keyCode) should resolve to '\(qwertyChar)' on \(name), got '\(result)'")
            }
        }
    }

    // MARK: - Special keys handled via specialKey path (unchanged)

    func testArrowKeysReturnExpectedStrings() {
        let arrowCases: [(UInt16, String)] = [
            (123, "leftarrow"),
            (124, "rightarrow"),
            (126, "uparrow"),
            (125, "downarrow"),
        ]
        for (keyCode, expected) in arrowCases {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil,
                characters: "x", charactersIgnoringModifiers: "x",
                isARepeat: false, keyCode: keyCode
            )!
            let saved = PhysicalKeyResolver.layoutProvider
            PhysicalKeyResolver.layoutProvider = Self.qwertyLayout()
            defer { PhysicalKeyResolver.layoutProvider = saved }

            XCTAssertEqual(PhysicalKeyResolver.keyString(for: event), expected,
                "keyCode \(keyCode) should resolve to '\(expected)'")
        }
    }

    func testSpaceReturnsSpaceString() {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: " ", charactersIgnoringModifiers: " ",
            isARepeat: false, keyCode: 49
        )!
        let saved = PhysicalKeyResolver.layoutProvider
        PhysicalKeyResolver.layoutProvider = Self.qwertyLayout()
        defer { PhysicalKeyResolver.layoutProvider = saved }

        XCTAssertEqual(PhysicalKeyResolver.keyString(for: event), "space")
    }

    func testReturnReturnsReturnString() {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36
        )!
        let saved = PhysicalKeyResolver.layoutProvider
        PhysicalKeyResolver.layoutProvider = Self.qwertyLayout()
        defer { PhysicalKeyResolver.layoutProvider = saved }

        XCTAssertEqual(PhysicalKeyResolver.keyString(for: event), "return")
    }

    func testEscapeReturnsEscapeString() {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false, keyCode: 53
        )!
        let saved = PhysicalKeyResolver.layoutProvider
        PhysicalKeyResolver.layoutProvider = Self.qwertyLayout()
        defer { PhysicalKeyResolver.layoutProvider = saved }

        XCTAssertEqual(PhysicalKeyResolver.keyString(for: event), "escape")
    }

    func testDeleteReturnsDeleteString() {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}",
            isARepeat: false, keyCode: 51
        )!
        let saved = PhysicalKeyResolver.layoutProvider
        PhysicalKeyResolver.layoutProvider = Self.qwertyLayout()
        defer { PhysicalKeyResolver.layoutProvider = saved }

        XCTAssertEqual(PhysicalKeyResolver.keyString(for: event), "delete")
    }

    func testTabReturnsTabString() {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "\t", charactersIgnoringModifiers: "\t",
            isARepeat: false, keyCode: 48
        )!
        let saved = PhysicalKeyResolver.layoutProvider
        PhysicalKeyResolver.layoutProvider = Self.qwertyLayout()
        defer { PhysicalKeyResolver.layoutProvider = saved }

        XCTAssertEqual(PhysicalKeyResolver.keyString(for: event), "tab")
    }

    // MARK: - Toggle-mute binding ("m") matches physical keyCode 46 on all layouts

    func testToggleMuteBindingMatchesPhysicalKeyOnAllLayouts() {
        let keyCode: UInt16 = 46
        let event = makeEvent(keyCode: keyCode)
        let providers: [String: KeyboardLayoutProviding] = [
            "QWERTY": Self.qwertyLayout(),
            "AZERTY": Self.azertyLayout(),
            "QWERTZ": Self.qwertzLayout(),
            "Dvorak": Self.dvorakLayout(),
            "Russian": Self.russianLayout(),
        ]

        for (name, provider) in providers {
            let keyString = resolve(event: event, provider: provider)
            XCTAssertEqual(keyString, "m",
                "toggleMute binding ('m') should match physical keyCode 46 on \(name)")
        }
    }
}
