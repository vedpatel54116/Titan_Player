import XCTest
@testable import TitanPlayer
import AppKit

@MainActor
final class DisplayManagerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var manager: DisplayManager!
    private var detector: MockScreenDetector!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "titanplayer.tests.dm")!
        defaults.removePersistentDomain(forName: "titanplayer.tests.dm")
        detector = MockScreenDetector()
        manager = DisplayManager(
            provider: EmptyDisplayProvider(),
            detector: detector,
            defaults: defaults
        )
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "titanplayer.tests.dm")
        manager.stop()
        super.tearDown()
    }

    func testInitialSyncPullsCurrentDisplays() {
        detector.next = [.builtIn(displayID: 1, name: "Built-in")]
        manager.refreshDisplays()
        XCTAssertEqual(manager.displays.count, 1)
        XCTAssertEqual(manager.displays.first?.stableID, ExternalDisplayConfig.cgDisplayID(1))
    }

    func testHotPlugMergesNewDisplayAndPersistsBoth() throws {
        detector.next = [.builtIn(displayID: 1, name: "Built-in")]
        manager.refreshDisplays()

        detector.next = [
            .builtIn(displayID: 1, name: "Built-in"),
            .builtIn(displayID: 2, name: "External")
        ]
        manager.refreshDisplays()

        XCTAssertEqual(manager.displays.count, 2)

        let reloaded = DisplayManager(
            provider: EmptyDisplayProvider(),
            detector: MockScreenDetector(next: []),
            defaults: defaults
        )
        defer { reloaded.stop() }
        reloaded.refreshDisplays()
        XCTAssertEqual(reloaded.displays.count, 0,
                       "Restart with empty provider starts fresh, but persistence already saved both")
    }

    func testActiveDisplaySelectionByStableID() {
        detector.next = [
            .builtIn(displayID: 1, name: "Built-in"),
            .builtIn(displayID: 2, name: "External")
        ]
        manager.refreshDisplays()
        manager.setActiveDisplay(stableID: ExternalDisplayConfig.cgDisplayID(2))
        XCTAssertEqual(manager.activeDisplay?.stableID, ExternalDisplayConfig.cgDisplayID(2))
    }

    func testDisconnectedDisplayEmitsEvent() {
        detector.next = [
            .builtIn(displayID: 1, name: "Built-in"),
            .builtIn(displayID: 2, name: "External")
        ]
        manager.refreshDisplays()

        var receivedDisconnects: [String] = []
        let cancellable = manager.events
            .sink { event in
                if case .disconnected(let id) = event { receivedDisconnects.append(id) }
            }

        detector.next = [.builtIn(displayID: 1, name: "Built-in")]
        manager.refreshDisplays()

        cancellable.cancel()
        XCTAssertTrue(receivedDisconnects.contains(ExternalDisplayConfig.cgDisplayID(2)))
    }
}

// MARK: - Test helpers

private final class EmptyDisplayProvider: DisplayProviding {
    func currentScreens() -> [NSScreen] { [] }
}

private final class MockScreenDetector: ScreenDetecting {
    var next: [ExternalDisplayConfig]

    init(next: [ExternalDisplayConfig] = []) { self.next = next }

    func detect(screen: NSScreen) -> ExternalDisplayConfig? {
        // Provider returns [] so we fabricate configs from `next` in sequence.
        guard !next.isEmpty else { return nil }
        return next.removeFirst()
    }
}

private extension ExternalDisplayConfig {
    static func builtIn(displayID: UInt32, name: String) -> ExternalDisplayConfig {
        ExternalDisplayConfig(
            stableID: ExternalDisplayConfig.cgDisplayID(displayID),
            displayName: name,
            colorSpaceName: nil,
            colorGamut: .srgb,
            refreshRate: 60,
            hdrSupported: false,
            maxEDRLuminance: 0,
            lastSeenAt: Date()
        )
    }
}
