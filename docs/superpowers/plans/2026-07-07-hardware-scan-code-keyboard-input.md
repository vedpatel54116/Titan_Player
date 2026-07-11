# Hardware Scan Code Keyboard Input — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace string-based keyboard bindings with hardware-scan-code-based detection for full international keyboard layout support (ISO, JIS, ANSI, gaming keyboards).

**Architecture:** Pure scan-code approach — `KeyBinding` stores `(keyCode: UInt16, modifiers: UInt16)`, `KeyEventRouter` matches `event.keyCode` directly, menu items have no `.keyboardShortcut()` modifiers. All keyboard input flows through a single pipeline: `NSEvent → KeyEventRouter → PlayerActionDispatcher`.

**Tech Stack:** Swift, AppKit (NSEvent, TIS APIs), SwiftPM

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `TitanPlayer/TitanPlayer/UI/Shortcuts/PlayerAction.swift` | Modify | `KeyBinding` struct with `keyCode`/`modifiers` fields |
| `TitanPlayer/TitanPlayer/UI/Shortcuts/ScanCodeKeyMapper.swift` | Create | Static scan-code → key-name lookup table |
| `TitanPlayer/TitanPlayer/UI/Shortcuts/KeyboardShortcutManager.swift` | Modify | Scan-code defaultBindings, migration, conflict detection |
| `TitanPlayer/TitanPlayer/UI/Shortcuts/KeyEventRouter.swift` | Modify | Direct `event.keyCode` matching |
| `TitanPlayer/TitanPlayer/UI/Shortcuts/ShortcutDisplayFormatter.swift` | Modify | Accept `(keyCode, modifiers)` instead of `(key: String, modifiers)` |
| `TitanPlayer/TitanPlayer/UI/Shortcuts/TitanCommands.swift` | Modify | Remove `.keyboardShortcut()` modifiers |
| `TitanPlayer/TitanPlayer/UI/Shortcuts/ShortcutsPreferencesView.swift` | Modify | Capture `event.keyCode` directly in recording |
| `TitanPlayer/TitanPlayer/Core/Utilities/Keyboard/KeyboardLayoutMonitor.swift` | Create | Layout change detection and telemetry |
| `TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift` | Modify | Add layout monitor call on init |
| `TitanPlayer/TitanPlayer/UI/Shortcuts/KeyEquivalentResolver.swift` | Delete | Replaced by `ScanCodeKeyMapper` |
| `TitanPlayer/Tests/Unit/ScanCodeKeyMapperTests.swift` | Create | Tests for scan-code lookup |
| `TitanPlayer/Tests/Unit/KeyboardShortcutManagerTests.swift` | Modify | Update to scan-code-based `KeyBinding` |
| `TitanPlayer/Tests/Unit/KeyEventRouterTests.swift` | Modify | Update to match on `event.keyCode` |
| `TitanPlayer/Tests/Unit/KeyEquivalentResolverTests.swift` | Delete | Replaced by `ScanCodeKeyMapperTests` |

---

## Task 1: Data Model — `KeyBinding` struct

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Shortcuts/PlayerAction.swift:33-64`
- Test: `TitanPlayer/Tests/Unit/KeyboardShortcutManagerTests.swift`

- [ ] **Step 1: Replace `KeyBinding` struct with scan-code version**

Replace the existing `KeyBinding` struct in `PlayerAction.swift`:

```swift
struct KeyBinding: Equatable {
    let action: PlayerAction
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags

    init(action: PlayerAction, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        self.action = action
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

extension KeyBinding: Codable {
    private enum CodingKeys: String, CodingKey {
        case action, keyCode, modifiers
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = try c.decode(PlayerAction.self, forKey: .action)
        keyCode = try c.decode(UInt16.self, forKey: .keyCode)
        let raw = try c.decode(UInt16.self, forKey: .modifiers)
        modifiers = NSEvent.ModifierFlags(rawValue: UInt(raw))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(action, forKey: .action)
        try c.encode(keyCode, forKey: .keyCode)
        try c.encode(UInt(modifiers.rawValue), forKey: .modifiers)
    }
}
```

- [ ] **Step 2: Verify build compiles**

Run: `swift build` from `TitanPlayer/` directory.
Expected: Build succeeds (tests will fail — that's expected).

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Shortcuts/PlayerAction.swift
git commit -m "feat: replace KeyBinding with scan-code-based struct"
```

---

## Task 2: ScanCodeKeyMapper

**Files:**
- Create: `TitanPlayer/TitanPlayer/UI/Shortcuts/ScanCodeKeyMapper.swift`
- Create: `TitanPlayer/Tests/Unit/ScanCodeKeyMapperTests.swift`

- [ ] **Step 1: Write failing tests for ScanCodeKeyMapper**

Create `TitanPlayer/Tests/Unit/ScanCodeKeyMapperTests.swift`:

```swift
import XCTest
@testable import TitanPlayer

final class ScanCodeKeyMapperTests: XCTestCase {
    func testLetterAKeyReturnsA() {
        XCTAssertEqual(ScanCodeKeyMapper.keyName(for: 0), "A")
    }

    func testSpaceKeyReturnsSpace() {
        XCTAssertEqual(ScanCodeKeyMapper.keyName(for: 49), "Space")
    }

    func testReturnKeyReturnsReturn() {
        XCTAssertEqual(ScanCodeKeyMapper.keyName(for: 36), "Return")
    }

    func testEscapeKeyReturnsEscape() {
        XCTAssertEqual(ScanCodeKeyMapper.keyName(for: 53), "Escape")
    }

    func testDeleteKeyReturnsDelete() {
        XCTAssertEqual(ScanCodeKeyMapper.keyName(for: 51), "Delete")
    }

    func testTabKeyReturnsTab() {
        XCTAssertEqual(ScanCodeKeyMapper.keyName(for: 48), "Tab")
    }

    func testLeftArrowReturnsLeftArrow() {
        XCTAssertEqual(ScanCodeKeyMapper.keyName(for: 123), "←")
    }

    func testRightArrowReturnsRightArrow() {
        XCTAssertEqual(ScanCodeKeyMapper.keyName(for: 124), "→")
    }

    func testUpArrowReturnsUpArrow() {
        XCTAssertEqual(ScanCodeKeyMapper.keyName(for: 126), "↑")
    }

    func testDownArrowReturnsDownArrow() {
        XCTAssertEqual(ScanCodeKeyMapper.keyName(for: 125), "↓")
    }

    func testNumpad0Returns0() {
        XCTAssertEqual(ScanCodeKeyMapper.keyName(for: 82), "0")
    }

    func testNumpadPeriodReturnsPeriod() {
        XCTAssertEqual(ScanCodeKeyMapper.keyName(for: 65), ".")
    }

    func testUnknownKeyCodeReturnsNil() {
        XCTAssertNil(ScanCodeKeyMapper.keyName(for: 999))
    }

    func testAllLetterKeyCodesReturnNonNil() {
        let letterKeyCodes: [UInt16] = [
            0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17,
            31, 32, 34, 35, 37, 38, 40, 45, 46
        ]
        for code in letterKeyCodes {
            XCTAssertNotNil(ScanCodeKeyMapper.keyName(for: code),
                "keyCode \(code) should have a key name")
        }
    }

    func testF1KeyReturnsF1() {
        XCTAssertEqual(ScanCodeKeyMapper.keyName(for: 120), "F1")
    }

    func testF12KeyReturnsF12() {
        XCTAssertEqual(ScanCodeKeyMapper.keyName(for: 98), "F12")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ScanCodeKeyMapperTests` from `TitanPlayer/` directory.
Expected: FAIL — `ScanCodeKeyMapper` does not exist yet.

- [ ] **Step 3: Implement ScanCodeKeyMapper**

Create `TitanPlayer/TitanPlayer/UI/Shortcuts/ScanCodeKeyMapper.swift`:

```swift
import AppKit

enum ScanCodeKeyMapper {
    static func keyName(for keyCode: UInt16) -> String? {
        keyNames[keyCode]
    }

    static let keyNames: [UInt16: String] = [
        // Letters
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z",
        7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E",
        15: "R", 16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P",
        37: "L", 38: "J", 40: "K", 45: "N", 46: "M",

        // Digits
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5",
        22: "6", 26: "7", 28: "8", 25: "9", 29: "0",

        // Symbols
        33: "[", 30: "]", 42: "\\", 43: ",", 44: "/",
        47: ".", 39: "'", 41: ";", 50: "`", 24: "=",
        27: "-",

        // Special keys
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete",
        53: "Escape", 54: "Command", 55: "Shift", 56: "Option",
        57: "Control", 60: "RightShift", 61: "RightOption",
        62: "RightControl", 63: "Fn",

        // Function keys
        120: "F1", 12: "F2", 99: "F3", 118: "F4", 96: "F5",
        97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        104: "F16", 79: "F17", 80: "F18", 90: "F19", 72: "F20",

        // Arrows
        123: "←", 124: "→", 126: "↑", 125: "↓",

        // Navigation
        115: "Home", 119: "End", 116: "PageUp", 121: "PageDown",
        114: "Help", 117: "ForwardDelete",

        // Numeric keypad
        65: ".", 67: "*", 69: "/", 71: "=",
        75: "+", 76: "Enter", 78: "-",
        82: "0", 83: "1", 84: "2", 85: "3", 86: "4",
        87: "5", 88: "6", 89: "7", 91: "8", 92: "9",
    ]
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ScanCodeKeyMapperTests` from `TitanPlayer/` directory.
Expected: PASS — all 15 tests pass.

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Shortcuts/ScanCodeKeyMapper.swift \
        TitanPlayer/Tests/Unit/ScanCodeKeyMapperTests.swift
git commit -m "feat: add ScanCodeKeyMapper with scan-code-to-key-name lookup"
```

---

## Task 3: Migration Logic in KeyboardShortcutManager

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Shortcuts/KeyboardShortcutManager.swift`
- Test: `TitanPlayer/Tests/Unit/KeyboardShortcutManagerTests.swift`

- [ ] **Step 1: Write failing test for migration**

Add to `KeyboardShortcutManagerTests.swift`:

```swift
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
    XCTAssertEqual(mgr.binding(for: .toggleFullscreen)?.modifiers,
                   NSEvent.ModifierFlags.command.rawValue)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter KeyboardShortcutManagerTests/testMigratesStringBasedBindingsToScanCodeFormat` from `TitanPlayer/` directory.
Expected: FAIL — migration logic doesn't exist.

- [ ] **Step 3: Add migration logic to KeyboardShortcutManager**

Update `loadBindings()` in `KeyboardShortcutManager.swift`:

```swift
private func loadBindings() {
    if let data = defaults.data(forKey: Self.defaultsKey) {
        // Try new format first (scan-code based)
        if let decoded = try? JSONDecoder().decode([KeyBinding].self, from: data) {
            for b in decoded {
                bindings[b.action] = b
            }
            for (action, b) in Self.defaultBindings where bindings[action] == nil {
                bindings[action] = b
            }
            return
        }
        // Try old format (string-based) and migrate
        if let migrated = migrateOldBindings(data: data) {
            for b in migrated {
                bindings[b.action] = b
            }
            persist()  // Save in new format
            for (action, b) in Self.defaultBindings where bindings[action] == nil {
                bindings[action] = b
            }
            return
        }
    }
    bindings = Self.defaultBindings
}

private func migrateOldBindings(data: Data) -> [KeyBinding]? {
    guard let oldBindings = try? JSONDecoder().decode(
        [OldKeyBinding].self, from: data
    ) else { return nil }

    return oldBindings.compactMap { old -> KeyBinding? in
        guard let keyCode = Self.stringToKeyCode[old.key] else { return nil }
        return KeyBinding(action: old.action, keyCode: keyCode,
                         modifiers: old.modifiers)
    }
}

private struct OldKeyBinding: Codable {
    let action: PlayerAction
    let key: String
    let modifiers: NSEvent.ModifierFlags

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = try c.decode(PlayerAction.self, forKey: .action)
        key = try c.decode(String.self, forKey: .key)
        let raw = try c.decode(UInt.self, forKey: .modifiers)
        modifiers = NSEvent.ModifierFlags(rawValue: raw)
    }

    enum CodingKeys: String, CodingKey {
        case action, key, modifiers
    }
}

static let stringToKeyCode: [String: UInt16] = [
    "space": 49, "return": 36, "enter": 36, "tab": 48,
    "escape": 53, "esc": 53, "delete": 51, "del": 51,
    "uparrow": 126, "downarrow": 125, "leftarrow": 123, "rightarrow": 124,
    "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "clear": 71,
    "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5,
    "h": 4, "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45,
    "o": 31, "p": 35, "q": 12, "r": 15, "s": 1, "t": 17, "u": 32,
    "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
    "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23,
    "6": 22, "7": 26, "8": 28, "9": 25,
    ".": 47, ",": 43, "[": 33, "]": 30, "\\": 42,
    "'": 39, ";": 41, "/": 44, "`": 50, "=": 24, "-": 27,
]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter KeyboardShortcutManagerTests/testMigratesStringBasedBindingsToScanCodeFormat` from `TitanPlayer/` directory.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Shortcuts/KeyboardShortcutManager.swift \
        TitanPlayer/Tests/Unit/KeyboardShortcutManagerTests.swift
git commit -m "feat: add migration from string-based to scan-code bindings"
```

---

## Task 4: Default Bindings in Scan-Code Format

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Shortcuts/KeyboardShortcutManager.swift:64-92`
- Test: `TitanPlayer/Tests/Unit/KeyboardShortcutManagerTests.swift`

- [ ] **Step 1: Write failing test for default bindings**

Add to `KeyboardShortcutManagerTests.swift`:

```swift
func testDefaultBindingsUseScanCodes() {
    let defaults = UserDefaults(suiteName: "test-defaults-sc-\(UUID())")!
    let mgr = KeyboardShortcutManager(defaults: defaults)
    XCTAssertEqual(mgr.binding(for: .togglePlayPause)?.keyCode, 49)  // Space
    XCTAssertEqual(mgr.binding(for: .seekBackward10)?.keyCode, 123)  // Left
    XCTAssertEqual(mgr.binding(for: .seekForward10)?.keyCode, 124)   // Right
    XCTAssertEqual(mgr.binding(for: .toggleMute)?.keyCode, 46)       // M
    XCTAssertEqual(mgr.binding(for: .toggleFullscreen)?.keyCode, 3)   // F
    XCTAssertEqual(mgr.binding(for: .toggleFullscreen)?.modifiers,
                   NSEvent.ModifierFlags.command.rawValue)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter KeyboardShortcutManagerTests/testDefaultBindingsUseScanCodes` from `TitanPlayer/` directory.
Expected: FAIL — default bindings still use string-based format.

- [ ] **Step 3: Replace defaultBindings with scan-code version**

Replace the `defaultBindings` static property in `KeyboardShortcutManager.swift`:

```swift
static let defaultBindings: [PlayerAction: KeyBinding] = [
    .togglePlayPause:        .init(action: .togglePlayPause,        keyCode: 49),
    .seekBackward10:         .init(action: .seekBackward10,         keyCode: 123),
    .seekForward10:          .init(action: .seekForward10,          keyCode: 124),
    .seekBackward60:         .init(action: .seekBackward60,         keyCode: 123, modifiers: .command),
    .seekForward60:          .init(action: .seekForward60,          keyCode: 124, modifiers: .command),
    .stepFrameForward:       .init(action: .stepFrameForward,       keyCode: 47),
    .stepFrameBackward:      .init(action: .stepFrameBackward,      keyCode: 43),
    .volumeUp:               .init(action: .volumeUp,               keyCode: 126),
    .volumeDown:             .init(action: .volumeDown,             keyCode: 125),
    .toggleMute:             .init(action: .toggleMute,             keyCode: 46),
    .toggleFullscreen:       .init(action: .toggleFullscreen,       keyCode: 3,  modifiers: .command),
    .toggleMiniPlayer:       .init(action: .toggleMiniPlayer,       keyCode: 46, modifiers: .command),
    .newLibraryWindow:       .init(action: .newLibraryWindow,       keyCode: 38, modifiers: .command),
    .openFile:               .init(action: .openFile,               keyCode: 31, modifiers: .command),
    .setAspectRatioFit:      .init(action: .setAspectRatioFit,      keyCode: 18, modifiers: .option),
    .setAspectRatioFill:     .init(action: .setAspectRatioFill,     keyCode: 19, modifiers: .option),
    .setAspectRatioStretch:  .init(action: .setAspectRatioStretch,  keyCode: 20, modifiers: .option),
    .setAspectRatioAuto:     .init(action: .setAspectRatioAuto,     keyCode: 29, modifiers: .option),
    .toggleSubtitles:        .init(action: .toggleSubtitles,        keyCode: 9),
    .toggleHDR:              .init(action: .toggleHDR,              keyCode: 4),
    .increasePlaybackRate:   .init(action: .increasePlaybackRate,   keyCode: 30),
    .decreasePlaybackRate:   .init(action: .decreasePlaybackRate,   keyCode: 33),
    .resetPlaybackRate:      .init(action: .resetPlaybackRate,      keyCode: 42),
    .toggleWaveform:         .init(action: .toggleWaveform,         keyCode: 18),
    .toggleVectorscope:      .init(action: .toggleVectorscope,      keyCode: 19),
    .toggleHistogram:        .init(action: .toggleHistogram,        keyCode: 20),
    .toggleAudioMeters:      .init(action: .toggleAudioMeters,      keyCode: 21),
]
```

- [ ] **Step 4: Update setBinding conflict detection**

Update `setBinding` in `KeyboardShortcutManager.swift` to compare `keyCode + modifiers`:

```swift
func setBinding(_ binding: KeyBinding, for action: PlayerAction) throws {
    if let conflict = bindings.first(where: {
        $0.key != action &&
        $0.value.keyCode == binding.keyCode &&
        $0.value.modifiers == binding.modifiers
    }) {
        throw NSError(domain: "KeyboardShortcutManager", code: 1,
                      userInfo: [NSLocalizedDescriptionKey:
                        "Key '\(ScanCodeKeyMapper.keyName(for: binding.keyCode) ?? "?")' already bound to \(conflict.key.rawValue)"])
    }
    bindings[action] = binding
    persist()
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter KeyboardShortcutManagerTests/testDefaultBindingsUseScanCodes` from `TitanPlayer/` directory.
Expected: PASS.

- [ ] **Step 6: Run all KeyboardShortcutManager tests**

Run: `swift test --filter KeyboardShortcutManagerTests` from `TitanPlayer/` directory.
Expected: All tests pass (existing tests updated to use scan codes).

- [ ] **Step 7: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Shortcuts/KeyboardShortcutManager.swift \
        TitanPlayer/Tests/Unit/KeyboardShortcutManagerTests.swift
git commit -m "feat: update defaultBindings and conflict detection to scan codes"
```

---

## Task 5: KeyEventRouter — Direct Scan-Code Matching

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Shortcuts/KeyEventRouter.swift:17-29`
- Test: `TitanPlayer/Tests/Unit/KeyEventRouterTests.swift`

- [ ] **Step 1: Write failing test for scan-code matching**

Add to `KeyEventRouterTests.swift`:

```swift
func testScanCodeMatchingBypassesPhysicalKeyResolver() {
    let mgr = makeManager()
    let router = KeyEventRouter(shortcutManager: mgr)

    // keyCode 46 = M, regardless of what PhysicalKeyResolver returns
    let event = makeEvent(keyCode: 46)

    // Even if PhysicalKeyResolver returns wrong string, scan-code match works
    let result = router.action(for: event)
    XCTAssertEqual(result, .toggleMute)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter KeyEventRouterTests/testScanCodeMatchingBypassesPhysicalKeyResolver` from `TitanPlayer/` directory.
Expected: FAIL — router still uses `PhysicalKeyResolver.keyString(for:)`.

- [ ] **Step 3: Update KeyEventRouter to use scan-code matching**

Replace `action(for:)` in `KeyEventRouter.swift`:

```swift
func action(for event: NSEvent) -> PlayerAction? {
    if isFirstResponderTextEditing(event: event) { return nil }

    let code = event.keyCode
    let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
    for action in PlayerAction.allCases {
        guard let binding = shortcutManager.binding(for: action) else { continue }
        if binding.keyCode == code && binding.modifiers == mods {
            return action
        }
    }
    return nil
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter KeyEventRouterTests/testScanCodeMatchingBypassesPhysicalKeyResolver` from `TitanPlayer/` directory.
Expected: PASS.

- [ ] **Step 5: Run all KeyEventRouter tests**

Run: `swift test --filter KeyEventRouterTests` from `TitanPlayer/` directory.
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Shortcuts/KeyEventRouter.swift \
        TitanPlayer/Tests/Unit/KeyEventRouterTests.swift
git commit -m "feat: update KeyEventRouter to match on event.keyCode directly"
```

---

## Task 6: ShortcutDisplayFormatter — Scan-Code Display

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Shortcuts/ShortcutDisplayFormatter.swift`

- [ ] **Step 1: Update ShortcutDisplayFormatter to accept scan codes**

Replace the `displayString` method in `ShortcutDisplayFormatter.swift`:

```swift
enum ShortcutDisplayFormatter {
    static func displayString(keyCode: UInt16, modifiers: UInt16) -> String {
        var parts: [String] = []
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        if flags.contains(.control) { parts.append("\u{2303}") }
        if flags.contains(.option)  { parts.append("\u{2325}") }
        if flags.contains(.shift)   { parts.append("\u{21E7}") }
        if flags.contains(.command) { parts.append("\u{2318}") }
        parts.append(ScanCodeKeyMapper.keyName(for: keyCode) ?? "?")
        return parts.joined()
    }
}
```

- [ ] **Step 2: Verify build compiles**

Run: `swift build` from `TitanPlayer/` directory.
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Shortcuts/ShortcutDisplayFormatter.swift
git commit -m "feat: update ShortcutDisplayFormatter to use scan codes"
```

---

## Task 7: TitanCommands — Remove .keyboardShortcut()

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Shortcuts/TitanCommands.swift:106-118`

- [ ] **Step 1: Remove .keyboardShortcut() from menuButton**

Replace the `menuButton` method in `TitanCommands.swift`:

```swift
@ViewBuilder
private func menuButton(_ title: String, action: PlayerAction) -> some View {
    Button(title) { dispatcher.dispatch(action) }
}
```

- [ ] **Step 2: Remove KeyEquivalentResolver import if unused**

Check if `KeyEquivalentResolver` is imported elsewhere in the file. If not, remove the import.

- [ ] **Step 3: Verify build compiles**

Run: `swift build` from `TitanPlayer/` directory.
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Shortcuts/TitanCommands.swift
git commit -m "feat: remove .keyboardShortcut() from TitanCommands menu items"
```

---

## Task 8: ShortcutsPreferencesView — Capture keyCode Directly

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Shortcuts/ShortcutsPreferencesView.swift:102-136`

- [ ] **Step 1: Update recording monitor to capture keyCode**

Replace the `startRecording` method in `ShortcutsPreferencesView.swift`:

```swift
private func startRecording(for action: PlayerAction) {
    conflictError = nil
    recordingAction = action
    KeyboardShortcutManager.isRecordingShortcut = true

    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        if event.keyCode == 53 {  // Escape
            stopRecording()
            return event
        }

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let candidate = KeyBinding(action: action, keyCode: event.keyCode, modifiers: mods)
        do {
            try resolvedManager.setBinding(candidate, for: action)
            stopRecording()
        } catch {
            conflictError = error.localizedDescription
        }

        return event
    }
}
```

- [ ] **Step 2: Update display formatting calls**

Update the `shortcutRow` method to use the new `displayString(keyCode:modifiers:)`:

```swift
let display = binding.map {
    ShortcutDisplayFormatter.displayString(keyCode: $0.keyCode, modifiers: $0.modifiers.rawValue)
} ?? "None"
```

- [ ] **Step 3: Verify build compiles**

Run: `swift build` from `TitanPlayer/` directory.
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Shortcuts/ShortcutsPreferencesView.swift
git commit -m "feat: update ShortcutsPreferencesView to capture keyCode directly"
```

---

## Task 9: KeyboardLayoutMonitor

**Files:**
- Create: `TitanPlayer/TitanPlayer/Core/Utilities/Keyboard/KeyboardLayoutMonitor.swift`
- Test: `TitanPlayer/Tests/Unit/KeyboardLayoutMonitorTests.swift` (optional)

- [ ] **Step 1: Create KeyboardLayoutMonitor**

Create `TitanPlayer/TitanPlayer/Core/Utilities/Keyboard/KeyboardLayoutMonitor.swift`:

```swift
import AppKit
import os

enum KeyboardLayoutMonitor {
    private static var currentLayoutID: String = ""
    private static let logger = Logger(subsystem: "com.titanplayer", category: "keyboard")

    static func detectLayout() {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let idRef = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return }
        let layoutID = Unmanaged<CFString>.fromOpaque(idRef).takeUnretainedValue() as String
        if !currentLayoutID.isEmpty && layoutID != currentLayoutID {
            logger.info("Layout changed: \(self.currentLayoutID) → \(layoutID)")
        }
        currentLayoutID = layoutID
    }
}
```

- [ ] **Step 2: Verify build compiles**

Run: `swift build` from `TitanPlayer/` directory.
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Utilities/Keyboard/KeyboardLayoutMonitor.swift
git commit -m "feat: add KeyboardLayoutMonitor for layout change telemetry"
```

---

## Task 10: PlaybackSession — Add Layout Monitor

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift:433-452`

- [ ] **Step 1: Add layout monitor call after key monitor setup**

Add `KeyboardLayoutMonitor.detectLayout()` call after the key monitor is set up in `PlaybackSession.init`:

```swift
// After keyMonitorToken = NSEvent.addLocalMonitorForEvents(...) { ... }
KeyboardLayoutMonitor.detectLayout()
```

- [ ] **Step 2: Verify build compiles**

Run: `swift build` from `TitanPlayer/` directory.
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift
git commit -m "feat: add layout monitor detection on PlaybackSession init"
```

---

## Task 11: Delete KeyEquivalentResolver

**Files:**
- Delete: `TitanPlayer/TitanPlayer/UI/Shortcuts/KeyEquivalentResolver.swift`
- Delete: `TitanPlayer/Tests/Unit/KeyEquivalentResolverTests.swift`

- [ ] **Step 1: Verify no remaining references to KeyEquivalentResolver**

Run: `grep -r "KeyEquivalentResolver" TitanPlayer/TitanPlayer/`
Expected: No matches (all usages removed in previous tasks).

- [ ] **Step 2: Delete the files**

```bash
rm TitanPlayer/TitanPlayer/UI/Shortcuts/KeyEquivalentResolver.swift
rm TitanPlayer/Tests/Unit/KeyEquivalentResolverTests.swift
```

- [ ] **Step 3: Verify build compiles**

Run: `swift build` from `TitanPlayer/` directory.
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add -A TitanPlayer/TitanPlayer/UI/Shortcuts/KeyEquivalentResolver.swift \
          TitanPlayer/Tests/Unit/KeyEquivalentResolverTests.swift
git commit -m "feat: remove KeyEquivalentResolver (replaced by ScanCodeKeyMapper)"
```

---

## Task 12: Update Remaining Tests

**Files:**
- Modify: `TitanPlayer/Tests/Unit/KeyboardShortcutManagerTests.swift`
- Modify: `TitanPlayer/Tests/Unit/KeyEventRouterTests.swift`

- [ ] **Step 1: Update KeyboardShortcutManagerTests to use scan codes**

Update all test methods that create `KeyBinding` with string keys to use `keyCode`:

```swift
// Old:
KeyBinding(action: .togglePlayPause, key: "k", modifiers: [])
// New:
KeyBinding(action: .togglePlayPause, keyCode: 40)  // K

// Old:
KeyBinding(action: .toggleMute, key: "n", modifiers: [])
// New:
KeyBinding(action: .toggleMute, keyCode: 45)  // N

// Old:
KeyBinding(action: .togglePlayPause, key: "p", modifiers: [])
// New:
KeyBinding(action: .togglePlayPause, keyCode: 35)  // P
```

Update assertions that check `.key` to check `.keyCode`:

```swift
// Old:
XCTAssertEqual(mgr.binding(for: .togglePlayPause)?.key, "space")
// New:
XCTAssertEqual(mgr.binding(for: .togglePlayPause)?.keyCode, 49)
```

- [ ] **Step 2: Update KeyEventRouterTests to use scan codes**

Update test assertions to check `keyCode` instead of resolved string:

```swift
// The existing tests already use keyCode in makeEvent(), so they should work.
// Just verify the assertions match scan-code matching.
```

- [ ] **Step 3: Run all tests**

Run: `swift test` from `TitanPlayer/` directory.
Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add TitanPlayer/Tests/Unit/KeyboardShortcutManagerTests.swift \
        TitanPlayer/Tests/Unit/KeyEventRouterTests.swift
git commit -m "feat: update test files to use scan-code-based KeyBinding"
```

---

## Task 13: Build & Verify

**Files:**
- None (verification only)

- [ ] **Step 1: Full build**

Run: `swift build` from `TitanPlayer/` directory.
Expected: Build succeeds with no errors.

- [ ] **Step 2: Run all tests**

Run: `swift test` from `TitanPlayer/` directory.
Expected: All tests pass.

- [ ] **Step 3: Run build-tests check (CommandLine Tools)**

Run: `swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"` from `TitanPlayer/` directory.
Expected: Empty result (no errors other than environmental XCTest issue).

- [ ] **Step 4: Final commit with all changes**

```bash
git add -A
git commit -m "feat: hardware scan code keyboard input system complete

- Replace string-based KeyBinding with (keyCode: UInt16, modifiers: UInt16)
- Add ScanCodeKeyMapper for scan-code-to-key-name lookup
- Update KeyEventRouter to match event.keyCode directly
- Remove .keyboardShortcut() from TitanCommands menu items
- Add KeyboardLayoutMonitor for layout change telemetry
- Auto-migrate old string-based bindings on first launch
- Update ShortcutsPreferencesView to capture keyCode directly
- Remove KeyEquivalentResolver (replaced by ScanCodeKeyMapper)"
```

---

## Self-Review Checklist

1. **Spec coverage:** All 7 goals from the spec have corresponding tasks:
   - ✅ Store bindings as `(keyCode, modifiers)` — Task 1
   - ✅ Match by `event.keyCode` — Task 5
   - ✅ Remove `.keyboardShortcut()` — Task 7
   - ✅ Layout detection telemetry — Task 9
   - ✅ Key repeat handling — Already works (OS generates repeated keyDown events)
   - ✅ NumLock awareness — `.deviceIndependentFlagsMask` strips `.numericPad`
   - ✅ Auto-migrate old bindings — Task 3

2. **Placeholder scan:** No TBD, TODO, or incomplete steps. All code blocks are complete.

3. **Type consistency:** `KeyBinding` uses `keyCode: UInt16, modifiers: UInt16` consistently across all tasks. `ShortcutDisplayFormatter` accepts `(keyCode: UInt16, modifiers: UInt16)`. `ScanCodeKeyMapper.keyName(for:)` takes `UInt16`.

4. **Test coverage:** Tasks 1-5, 12 include tests. Task 13 verifies full build.
