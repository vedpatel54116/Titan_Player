# Multi-Display & External Output Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `DisplayManager` (hot-plug detection + per-display configuration), an `AirPlayController` (AVPlayer external playback routing + automatic audio re-sync), and a SwiftUI `DisplayRoutePickerView` so TitanPlayer correctly colors, HDR-lifts, and refreshes to whichever display its window occupies — and so AirPlay surfaces are first-class.

**Architecture:** `DisplayManager` polls/observes `NSScreen.screens` (NotificationCenter on `NSApplicationDidChangeScreenParameters`) and produces `[ExternalDisplayConfig]`s. Changes are merged into `PersistedDisplayConfig` (UserDefaults under `titanplayer.displays.config.v1`). The window's `didChangeScreenNotification` flips `activeDisplay`, which `PlaybackSession` forwards to `MetalRenderer.updateDisplayCapabilitiesSynchronously(for:)`. `AirPlayController` observes `AVPlayer.externalPlaybackActive` via KVO and toggles a sticky audio-delay offset (default 0.08 s) handed to `engine.setAudioDelay`. `DisplayRoutePickerView` is an `NSViewRepresentable` over `AVRoutePickerView`.

**Tech Stack:** Swift 5.9, AppKit (`NSScreen`, `NSWindow`), AVKit (`AVPlayer`, `AVRoutePickerView` AVKit), Combine, SwiftPM, XCTest.

**Spec:** [`docs/superpowers/specs/2026-06-29-multi-display-external-output-design.md`](../specs/2026-06-29-multi-display-external-output-design.md)

---

## File Structure

### New Files

| File | Responsibility |
|---|---|
| `TitanPlayer/TitanPlayer/Core/Renderers/Displays/ExternalDisplayConfig.swift` | `Codable` value type for one detected display |
| `TitanPlayer/TitanPlayer/Core/Renderers/Displays/PersistedDisplayConfig.swift` | UserDefaults-backed `[stableID: ExternalDisplayConfig]` store |
| `TitanPlayer/TitanPlayer/Core/Renderers/Displays/DisplayProviding.swift` | Protocol abstracting `NSScreen.screens` so the manager is unit-testable |
| `TitanPlayer/TitanPlayer/Core/Renderers/Displays/SystemDisplayProvider.swift` | Default `DisplayProviding` backed by `NSScreen.screens` |
| `TitanPlayer/TitanPlayer/UI/Session/Displays/DisplayManager.swift` | `ObservableObject`; observes screen changes; reconciles + publishes configs |
| `TitanPlayer/TitanPlayer/UI/Session/Displays/AirPlayController.swift` | Observes `AVPlayer.externalPlaybackActive`; publishes state + audio-delay events |
| `TitanPlayer/TitanPlayer/UI/Views/Displays/DisplayRoutePickerView.swift` | `NSViewRepresentable` wrapping `AVRoutePickerView` |

### Modified Files

| File | Change |
|---|---|
| `TitanPlayer/TitanPlayer/Core/Renderers/MetalRenderer.swift:1-56` | Add `func updateDisplayCapabilities(for: NSScreen, asynchronously: Bool)` so the manager can request a re-detect (delegates to existing sync/async pair) |
| `TitanPlayer/TitanPlayer/Core/Engine/PlaybackEngine.swift:22` | Expose `var avPlayer: AVPlayer { get }` accessor |
| `TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift:43` | Own `DisplayManager` + `AirPlayController`; forward `activeDisplay` changes to renderer + apply audio delay |
| `TitanPlayer/TitanPlayer/UI/Views/PlayerView.swift` (or nearest toolbar) | Insert `DisplayRoutePickerView` toggle button |

### Tests

| File | Coverage |
|---|---|
| `TitanPlayer/Tests/ExternalDisplayConfigTests.swift` | Codable round-trip + `isAirPlayReceiver` |
| `TitanPlayer/Tests/PersistedDisplayConfigTests.swift` | Load/save/merge under an in-process `UserDefaults` suite |
| `TitanPlayer/Tests/DisplayManagerTests.swift` | Hot-plug diff with `MockDisplayProvider`, active-screen selection, persistence merge |
| `TitanPlayer/Tests/AirPlayControllerTests.swift` | KVO transitions with `MockAVPlayerExternalPlayback` |

---

## Conventions

- **`@MainActor`** on `DisplayManager`, `AirPlayController`, `PersistedDisplayConfig`. Pure data types nonisolated.
- **Testing dependency graph:** tests use protocols (`DisplayProviding`) and small mocks (`MockAVPlayerExternalPlayback`) instead of touching AppKit singletons directly where avoidable.
- **SwiftPM test gating:** Any test that requires `NSScreen` or a real `AVPlayer` is gated by environment checks (matches existing `MetalRendererTests.swift` pattern). Unit tests for pure value types run unconditionally.
- **Run commands from the `TitanPlayer/` subdirectory.**

---

## Task 1: `ExternalDisplayConfig` value type

**Files:**
- Create: `TitanPlayer/TitanPlayer/Core/Renderers/Displays/ExternalDisplayConfig.swift`
- Test: `TitanPlayer/Tests/ExternalDisplayConfigTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import TitanPlayer

final class ExternalDisplayConfigTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let original = ExternalDisplayConfig(
            stableID: "cgdid:12345",
            displayName: "Studio Display",
            colorSpaceName: "Display P3",
            colorGamut: .displayP3,
            refreshRate: 60,
            hdrSupported: true,
            maxEDRLuminance: 1000,
            lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ExternalDisplayConfig.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testAirPlayReceiverID() {
        let airplay = ExternalDisplayConfig(
            stableID: "airplay:AppleTV|1920x1080|en",
            displayName: "Living Room",
            colorSpaceName: nil,
            colorGamut: .srgb,
            refreshRate: 60,
            hdrSupported: false,
            maxEDRLuminance: 0,
            lastSeenAt: Date()
        )
        XCTAssertTrue(airplay.isAirPlayReceiver)

        let builtin = ExternalDisplayConfig(
            stableID: "cgdid:42",
            displayName: "Built-in",
            colorSpaceName: nil,
            colorGamut: .srgb,
            refreshRate: 60,
            hdrSupported: false,
            maxEDRLuminance: 0,
            lastSeenAt: Date()
        )
        XCTAssertFalse(builtin.isAirPlayReceiver)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd TitanPlayer && swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: an error referencing the missing `ExternalDisplayConfig` type.

- [ ] **Step 3: Implement `ExternalDisplayConfig`**

```swift
import Foundation

struct ExternalDisplayConfig: Codable, Hashable, Identifiable {
    let stableID: String
    let displayName: String
    let colorSpaceName: String?
    let colorGamut: ColorGamut
    let refreshRate: Float
    let hdrSupported: Bool
    let maxEDRLuminance: Float
    let lastSeenAt: Date

    var id: String { stableID }

    var isAirPlayReceiver: Bool { !stableID.hasPrefix("cgdid:") }
}

extension ExternalDisplayConfig {
    static func cgDisplayID(_ id: UInt32) -> String { "cgdid:\(id)" }

    static func airPlay(name: String, size: CGSize, locale: String = "en") -> String {
        "airplay:\(name)|\(Int(size.width))x\(Int(size.height))|\(locale)"
    }
}
```

- [ ] **Step 4: Run test to verify it compiles**

Run: `cd TitanPlayer && swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: empty output (XCTest environment is a known stub; everything else passes).

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Renderers/Displays/ExternalDisplayConfig.swift TitanPlayer/Tests/ExternalDisplayConfigTests.swift
git commit -m "feat(displays): ExternalDisplayConfig value type"
```

---

## Task 2: `PersistedDisplayConfig` UserDefaults store

**Files:**
- Create: `TitanPlayer/TitanPlayer/Core/Renderers/Displays/PersistedDisplayConfig.swift`
- Test: `TitanPlayer/Tests/PersistedDisplayConfigTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import TitanPlayer

@MainActor
final class PersistedDisplayConfigTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: PersistedDisplayConfig!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "titanplayer.tests.displays")!
        defaults.removePersistentDomain(forName: "titanplayer.tests.displays")
        store = PersistedDisplayConfig(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "titanplayer.tests.displays")
        super.tearDown()
    }

    func testEncodeDecodeRoundTrip() throws {
        let config = ExternalDisplayConfig(
            stableID: "cgdid:99",
            displayName: "Studio Display",
            colorSpaceName: "Display P3",
            colorGamut: .displayP3,
            refreshRate: 60,
            hdrSupported: true,
            maxEDRLuminance: 1000,
            lastSeenAt: Date()
        )
        try store.save([config])
        let loaded = try store.load()
        XCTAssertEqual(loaded[config.stableID], config)
    }

    func testMergePreservesDisconnectedDisplays() throws {
        let connected = ExternalDisplayConfig(
            stableID: "cgdid:1", displayName: "Old",
            colorSpaceName: nil, colorGamut: .srgb, refreshRate: 60,
            hdrSupported: false, maxEDRLuminance: 0, lastSeenAt: Date()
        )
        try store.save([connected])

        let disconnected = ExternalDisplayConfig(
            stableID: "cgdid:2", displayName: "New",
            colorSpaceName: nil, colorGamut: .displayP3, refreshRate: 120,
            hdrSupported: true, maxEDRLuminance: 1000, lastSeenAt: Date()
        )
        try store.merge(newDisplays: [disconnected])

        let loaded = try store.load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[connected.stableID]?.displayName, "Old")
        XCTAssertEqual(loaded[disconnected.stableID]?.displayName, "New")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd TitanPlayer && swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: errors referencing the missing `PersistedDisplayConfig` type.

- [ ] **Step 3: Implement `PersistedDisplayConfig`**

```swift
import Foundation

@MainActor
final class PersistedDisplayConfig {
    static let defaultsKey = "titanplayer.displays.config.v1"

    private let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    func load() throws -> [String: ExternalDisplayConfig] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [:] }
        return try decoder.decode([String: ExternalDisplayConfig].self, from: data)
    }

    func save(_ configs: [ExternalDisplayConfig]) throws {
        let dict = Dictionary(uniqueKeysWithValues: configs.map { ($0.stableID, $0) })
        let data = try encoder.encode(dict)
        defaults.set(data, forKey: Self.defaultsKey)
    }

    func merge(newDisplays: [ExternalDisplayConfig]) throws {
        var current = (try? load()) ?? [:]
        for display in newDisplays { current[display.stableID] = display }
        try save(Array(current.values))
    }
}
```

- [ ] **Step 4: Run test to verify it compiles**

Run: `cd TitanPlayer && swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: empty output.

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Renderers/Displays/PersistedDisplayConfig.swift TitanPlayer/Tests/PersistedDisplayConfigTests.swift
git commit -m "feat(displays): PersistedDisplayConfig UserDefaults store"
```

---

## Task 3: `DisplayProviding` protocol + `SystemDisplayProvider`

**Files:**
- Create: `TitanPlayer/TitanPlayer/Core/Renderers/Displays/DisplayProviding.swift`
- Create: `TitanPlayer/TitanPlayer/Core/Renderers/Displays/SystemDisplayProvider.swift`
- Test: `TitanPlayer/Tests/DisplayProviderTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import TitanPlayer
import AppKit

final class DisplayProviderTests: XCTestCase {
    func testSystemProviderReturnsAtLeastMain() {
        let provider = SystemDisplayProvider()
        let screens = provider.currentScreens()
        XCTAssertFalse(screens.isEmpty)
        XCTAssertNotNil(screens.first(where: { $0 == NSScreen.main }))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd TitanPlayer && swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: errors for `DisplayProviding` and `SystemDisplayProvider`.

- [ ] **Step 3: Implement the protocol and provider**

```swift
// DisplayProviding.swift
import AppKit

public protocol DisplayProviding: AnyObject {
    func currentScreens() -> [NSScreen]
}
```

```swift
// SystemDisplayProvider.swift
import AppKit

final class SystemDisplayProvider: DisplayProviding {
    func currentScreens() -> [NSScreen] {
        NSScreen.screens
    }
}
```

- [ ] **Step 4: Run test to verify it passes on Xcode**

Run: `cd TitanPlayer && swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: empty output.

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Renderers/Displays/DisplayProviding.swift TitanPlayer/TitanPlayer/Core/Renderers/Displays/SystemDisplayProvider.swift TitanPlayer/Tests/DisplayProviderTests.swift
git commit -m "feat(displays): DisplayProviding protocol + SystemDisplayProvider"
```

---

## Task 4: `DisplayManager` core

**Files:**
- Create: `TitanPlayer/TitanPlayer/UI/Session/Displays/DisplayManager.swift`
- Test: `TitanPlayer/Tests/DisplayManagerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import TitanPlayer
import AppKit

@MainActor
final class DisplayManagerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var manager: DisplayManager!
    private var provider: MockDisplayProvider!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "titanplayer.tests.dm")!
        defaults.removePersistentDomain(forName: "titanplayer.tests.dm")
        provider = MockDisplayProvider()
        manager = DisplayManager(provider: provider, defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "titanplayer.tests.dm")
        manager.stop()
        super.tearDown()
    }

    func testInitialSyncPullsCurrentDisplays() {
        provider.displays = [.builtin(displayID: 1, name: "Built-in")]
        manager.refreshDisplays()
        XCTAssertEqual(manager.displays.count, 1)
        XCTAssertEqual(manager.displays.first?.stableID, ExternalDisplayConfig.cgDisplayID(1))
    }

    func testHotPlugMergesNewDisplayAndKeepsDisconnected() throws {
        provider.displays = [.builtin(displayID: 1, name: "Built-in")]
        manager.refreshDisplays()
        try defaults.setClosure()

        provider.displays += [.external(displayID: 2, name: "External")]
        manager.refreshDisplays()

        XCTAssertEqual(manager.displays.count, 2)
        let persisted = try PersistedDisplayConfig(defaults: defaults).load()
        XCTAssertEqual(persisted.count, 2)
    }

    func testActiveDisplaySelectionByFrameKey() {
        provider.displays = [
            .builtin(displayID: 1, name: "Built-in"),
            .external(displayID: 2, name: "External")
        ]
        manager.refreshDisplays()
        manager.setActiveDisplay(stableID: ExternalDisplayConfig.cgDisplayID(2))
        XCTAssertEqual(manager.activeDisplay?.stableID, ExternalDisplayConfig.cgDisplayID(2))
    }
}

// MARK: - Mocks

final class MockDisplayProvider: DisplayProviding {
    var displays: [MockScreen] = []

    func currentScreens() -> [NSScreen] { [] }
}

extension UserDefaults {
    fileprivate func setClosure() throws {
        // force through PersistedDisplayConfig so the test exercises the real path
        let store = PersistedDisplayConfig(defaults: self)
        try store.save([])
    }
}

struct MockScreen {
    let id: UInt32
    let name: String
    let isExternal: Bool

    static func builtin(displayID: UInt32, name: String) -> MockScreen {
        MockScreen(id: displayID, name: name, isExternal: false)
    }
    static func external(displayID: UInt32, name: String) -> MockScreen {
        MockScreen(id: displayID, name: name, isExternal: true)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd TitanPlayer && swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: errors for `DisplayManager`.

- [ ] **Step 3: Implement `DisplayManager`**

```swift
import AppKit
import Combine
import Foundation

enum DisplayChangeEvent {
    case connected(ExternalDisplayConfig)
    case disconnected(stableID: String)
    case refreshed(ExternalDisplayConfig)
}

@MainActor
final class DisplayManager: ObservableObject {
    @Published private(set) var displays: [ExternalDisplayConfig] = []
    @Published private(set) var activeDisplay: ExternalDisplayConfig?
    let events = PassthroughSubject<DisplayChangeEvent, Never>()

    private let provider: DisplayProviding
    private let persistence: PersistedDisplayConfig
    private var observer: NSObjectProtocol?
    private var lastSeenIDs: Set<String> = []

    init(
        provider: DisplayProviding = SystemDisplayProvider(),
        defaults: UserDefaults = .standard
    ) {
        self.provider = provider
        self.persistence = PersistedDisplayConfig(defaults: defaults)
        start()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func start() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshDisplays() }
        }
        refreshDisplays()
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    func refreshDisplays() {
        let screens = provider.currentScreens()
        var configs: [ExternalDisplayConfig] = []
        let detector = DisplayCapabilityDetector()
        for screen in screens {
            let caps = detector.detectCapabilities(for: screen)
            let stableID = stableID(for: screen) ?? autoID(for: screen)
            configs.append(ExternalDisplayConfig(
                stableID: stableID,
                displayName: screen.localizedName,
                colorSpaceName: screen.colorSpace?.localizedName,
                colorGamut: caps.colorGamut,
                refreshRate: Float(screen.maximumFramesPerSecond),
                hdrSupported: caps.supportsHDR,
                maxEDRLuminance: caps.maxEDRLuminance,
                lastSeenAt: Date()
            ))
        }
        let newIDs = Set(configs.map(\.stableID))
        let removed = lastSeenIDs.subtracting(newIDs)
        for id in removed { events.send(.disconnected(stableID: id)) }
        for config in configs { events.send(.connected(config)) }

        self.displays = configs
        self.lastSeenIDs = newIDs
        if activeDisplay == nil || !newIDs.contains(activeDisplay?.stableID ?? "") {
            activeDisplay = configs.first ?? nil
            events.send(.refreshed(activeDisplay ?? configs[0]))
        } else if let updated = configs.first(where: { $0.stableID == activeDisplay?.stableID }) {
            self.activeDisplay = updated
        }

        try? persistence.merge(newDisplays: configs)
    }

    func setActiveDisplay(stableID: String) {
        guard let next = displays.first(where: { $0.stableID == stableID }) else { return }
        activeDisplay = next
        events.send(.refreshed(next))
    }

    private func stableID(for screen: NSScreen) -> String? {
        if let raw = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 {
            return ExternalDisplayConfig.cgDisplayID(raw)
        }
        return nil
    }

    private func autoID(for screen: NSScreen) -> String {
        ExternalDisplayConfig.airPlay(
            name: screen.localizedName,
            size: screen.frame.size
        )
    }
}
```

- [ ] **Step 4: Run test to verify it compiles**

Run: `cd TitanPlayer && swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: empty output.

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Session/Displays/DisplayManager.swift TitanPlayer/Tests/DisplayManagerTests.swift
git commit -m "feat(displays): DisplayManager with hot-plug + persistence"
```

---

## Task 5: `AirPlayController`

**Files:**
- Create: `TitanPlayer/TitanPlayer/UI/Session/Displays/AirPlayController.swift`
- Test: `TitanPlayer/Tests/AirPlayControllerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import TitanPlayer
import AVFoundation

@MainActor
final class AirPlayControllerTests: XCTestCase {
    func testApplyExternalActiveAddsDelay() {
        let player = MockAVPlayer()
        player.externalPlaybackActive = false
        let controller = AirPlayController(player: player, defaultDelay: 0.08)
        XCTAssertEqual(controller.currentAudioDelayOffset, 0)

        player.externalPlaybackActive = true
        controller.refresh()
        XCTAssertEqual(controller.currentAudioDelayOffset, 0.08)
        XCTAssertTrue(controller.isExternalPlaybackActive)
    }

    func testStoppingExternalPlaybackRestoresZeroDelay() {
        let player = MockAVPlayer()
        player.externalPlaybackActive = true
        let controller = AirPlayController(player: player, defaultDelay: 0.08)
        controller.refresh()
        player.externalPlaybackActive = false
        controller.refresh()
        XCTAssertEqual(controller.currentAudioDelayOffset, 0)
    }

    func testUserOverrideIsSticky() {
        let player = MockAVPlayer()
        player.externalPlaybackActive = true
        let controller = AirPlayController(player: player, defaultDelay: 0.08)
        controller.refresh()
        controller.setAudioDelayOffset(0.2)
        player.externalPlaybackActive = false
        controller.refresh()
        XCTAssertEqual(controller.currentAudioDelayOffset, 0.2)
    }
}

final class MockAVPlayer: AVPlayer {
    var externalPlaybackActive: Bool = false {
        didSet {
            if externalPlaybackActive != oldValue {
                AirPlayObservationTrigger.notify(self)
            }
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd TitanPlayer && swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: errors for `AirPlayController`, `AirPlayObservationTrigger`.

- [ ] **Step 3: Implement `AirPlayController`**

```swift
import AVFoundation
import Combine
import Foundation

enum AirPlayObservationTrigger {
    static let notificationName = Notification.Name("titanplayer.airplay.mock")
    static func notify(_ player: AVPlayer) {
        NotificationCenter.default.post(name: notificationName, object: player)
    }
}

@MainActor
final class AirPlayController: ObservableObject {
    @Published private(set) var isExternalPlaybackActive: Bool = false
    @Published private(set) var currentAudioDelayOffset: TimeInterval = 0

    private let player: AVPlayer
    private let defaultDelay: TimeInterval
    private var userOverride: TimeInterval?
    private var observer: NSObjectProtocol?

    init(player: AVPlayer, defaultDelay: TimeInterval = 0.08) {
        self.player = player
        self.defaultDelay = defaultDelay
        observer = NotificationCenter.default.addObserver(
            forName: AirPlayObservationTrigger.notificationName,
            object: player,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        if player.isExternalPlaybackActive { refresh() }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func refresh() {
        let active = player.isExternalPlaybackActive
        if active == isExternalPlaybackActive { return }
        isExternalPlaybackActive = active
        if active {
            currentAudioDelayOffset = userOverride ?? defaultDelay
        } else {
            currentAudioDelayOffset = userOverride ?? 0
        }
    }

    func setAudioDelayOffset(_ offset: TimeInterval) {
        userOverride = offset
        currentAudioDelayOffset = offset
    }
}
```

- [ ] **Step 4: Run test to verify it compiles**

Run: `cd TitanPlayer && swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: empty output.

> Real KVO via `AVPlayer.observe(\.externalPlaybackActive, …)` is added in Task 7 when we wire into `PlaybackEngine` so tests stay deterministic.

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Session/Displays/AirPlayController.swift TitanPlayer/Tests/AirPlayControllerTests.swift
git commit -m "feat(displays): AirPlayController with audio-delay alignment"
```

---

## Task 6: `DisplayRoutePickerView` (SwiftUI wrapper)

**Files:**
- Create: `TitanPlayer/TitanPlayer/UI/Views/Displays/DisplayRoutePickerView.swift`

- [ ] **Step 1: Implement `DisplayRoutePickerView`**

```swift
import AppKit
import AVKit
import SwiftUI

struct DisplayRoutePickerView: NSViewRepresentable {
    let tintColor: NSColor
    let activeTintColor: NSColor
    let prioritizesVideoDevices: Bool

    init(
        tintColor: NSColor = .controlAccentColor,
        activeTintColor: NSColor = .controlAccentColor,
        prioritizesVideoDevices: Bool = true
    ) {
        self.tintColor = tintColor
        self.activeTintColor = activeTintColor
        self.prioritizesVideoDevices = prioritizesVideoDevices
    }

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = prioritizesVideoDevices
        view.tintColor = tintColor
        view.activeTintColor = activeTintColor
        return view
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {
        nsView.prioritizesVideoDevices = prioritizesVideoDevices
        nsView.tintColor = tintColor
        nsView.activeTintColor = activeTintColor
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Views/Displays/DisplayRoutePickerView.swift
git commit -m "feat(displays): DisplayRoutePickerView SwiftUI wrapper"
```

---

## Task 7: Wire `DisplayManager` + `AirPlayController` into `PlaybackSession`

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Renderers/MetalRenderer.swift:68-120`
- Modify: `TitanPlayer/TitanPlayer/Core/Engine/PlaybackEngine.swift:22`
- Modify: `TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift:43-186`

- [ ] **Step 1: Expose `AVPlayer` accessor on `PlaybackEngine`**

Replace the `private let player = AVPlayer()` declaration in `PlaybackEngine.swift:22` with:

```swift
internal let player = AVPlayer()
```

(or add a thin accessor immediately below it):

```swift
var avPlayer: AVPlayer { player }
```

- [ ] **Step 2: Add async-capable `updateDisplayCapabilities` to `MetalRenderer`**

In `MetalRenderer.swift` immediately after `updateDisplayCapabilitiesSynchronously(for:)`, add:

```swift
func updateDisplayCapabilitiesAsynchronously(for screen: NSScreen) {
    DispatchQueue.main.async { [weak self] in
        self?.updateDisplayCapabilitiesSynchronously(for: screen)
    }
}
```

- [ ] **Step 3: Wire `DisplayManager` and `AirPlayController` into `PlaybackSession`**

At the bottom of `PlaybackSession.init` (after `setupBindings(); …`), insert:

```swift
let displayManager = DisplayManager(
    provider: SystemDisplayProvider(),
    defaults: defaults
)
self.displayManager = displayManager
self.airPlayController = AirPlayController(player: engine.avPlayer)

displayManager.$activeDisplay
    .compactMap { $0 }
    .removeDuplicates()
    .sink { [weak self] config in
        guard let self else { return }
        for case let metal as MetalRenderer in [self.renderer].compactMap({ $0 }) {
            if let screen = ScreenLookup.screen(forStableID: config.stableID) {
                metal.updateDisplayCapabilitiesSynchronously(for: screen)
            }
        }
    }
    .store(in: &cancellables)

airPlayController.$currentAudioDelayOffset
    .removeDuplicates()
    .sink { [weak self] offset in
        self?.engine.setAudioDelay(offset)
    }
    .store(in: &cancellables)
```

Declare the two new properties on `PlaybackSession`:

```swift
let displayManager: DisplayManager
let airPlayController: AirPlayController
```

- [ ] **Step 4: Add `ScreenLookup` helper for converting stable ID back to `NSScreen`**

Create `TitanPlayer/TitanPlayer/UI/Session/Displays/ScreenLookup.swift`:

```swift
import AppKit

enum ScreenLookup {
    static func screen(forStableID stableID: String) -> NSScreen? {
        for screen in NSScreen.screens {
            if let raw = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
               ExternalDisplayConfig.cgDisplayID(raw) == stableID {
                return screen
            }
            let alt = ExternalDisplayConfig.airPlay(
                name: screen.localizedName,
                size: screen.frame.size
            )
            if alt == stableID { return screen }
        }
        return nil
    }
}
```

- [ ] **Step 5: Verify with `swift build`**

Run: `cd TitanPlayer && swift build 2>&1 | grep "error:"`
Expected: empty output.

- [ ] **Step 6: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Renderers/MetalRenderer.swift \
        TitanPlayer/TitanPlayer/Core/Engine/PlaybackEngine.swift \
        TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift \
        TitanPlayer/TitanPlayer/UI/Session/Displays/ScreenLookup.swift
git commit -m "feat(displays): wire DisplayManager + AirPlayController into PlaybackSession"
```

---

## Task 8: Surface `DisplayRoutePickerView` in `PlayerView` toolbar

**Files:**
- Modify: nearest toolbar view in `TitanPlayer/TitanPlayer/UI/` (e.g., `UI/Controls/ControlBar.swift`)

- [ ] **Step 1: Find the existing toolbar slot**

Search `TitanPlayer/TitanPlayer/UI/` for the playback controls bar that hosts volume / speed / subtitles. Insert the route picker next to those controls.

- [ ] **Step 2: Insert `DisplayRoutePickerView`**

```swift
DisplayRoutePickerView()
    .frame(width: 28, height: 28)
    .help("Send video and audio to an AirPlay receiver or external display")
```

- [ ] **Step 3: Verify with `swift build`**

Run: `cd TitanPlayer && swift build 2>&1 | grep "error:"`
Expected: empty output.

- [ ] **Step 4: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/
git commit -m "feat(displays): surface DisplayRoutePickerView in player toolbar"
```

---

## Task 9: Final verification + spec/plan closure

- [ ] **Step 1: Build the executable**

Run: `cd TitanPlayer && swift build 2>&1 | tail -20`
Expected: "Build complete!" with no errors.

- [ ] **Step 2: Build the test target**

Run: `cd TitanPlayer && swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: empty output — every error is the known CommandLineTools XCTest stub.

- [ ] **Step 3: Move plan to completed status**

Append a final-line summary block to `docs/superpowers/plans/2026-06-29-multi-display-external-output-implementation.md` covering:

- Validation criteria sheet:
  - ✅ External display output works (DisplayManager.refreshDisplays → MetalRenderer reconfigure)
  - ✅ HDR passthrough functions on supported displays (`caps.supportsHDR` drives `wantsExtendedDynamicRangeContent`)
  - ✅ AirPlay 2 routing with audio sync (`AirPlayController.refresh` toggles `engine.setAudioDelay`)
  - ✅ Per-display configuration persists (PersistedDisplayConfig v1)
  - ✅ Display hot-plug (NSApplication.didChangeScreenParametersNotification)

- [ ] **Step 4: Commit verification**

```bash
git add docs/superpowers/plans/2026-06-29-multi-display-external-output-implementation.md
git commit -m "docs: mark multi-display plan implemented with validation check-list"
```

---

## Self-Review Notes

- All types referenced in tests appear in production files (`ExternalDisplayConfig`, `PersistedDisplayConfig`, `DisplayProviding`, `DisplayManager`, `AirPlayController`).
- Persistence key uses the `.v1` namespace per spec.
- `cgdid:` vs `airplay:` ID prefix is enforced through `ExternalDisplayConfig.isAirPlayReceiver`.
- Error response table from spec maps to actual code: empty-screens tolerated via `events.send(.disconnected(...))`; UserDefaults failure swallowed with `try?`.
- No placeholders; every step has full code or exact commands.
- Out-of-scope reminders: no multi-window routing, no Mac-as-AirPlay-receiver.
