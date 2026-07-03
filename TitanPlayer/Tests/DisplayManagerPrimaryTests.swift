import XCTest
@testable import TitanPlayer
import AppKit

@MainActor
final class DisplayManagerPrimaryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var manager: DisplayManager!
    private var detector: MockScreenDetector!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "titanplayer.tests.dmp")!
        defaults.removePersistentDomain(forName: "titanplayer.tests.dmp")
        detector = MockScreenDetector()
        manager = DisplayManager(
            provider: EmptyDisplayProvider(),
            detector: detector,
            defaults: defaults
        )
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "titanplayer.tests.dmp")
        manager.stop()
        super.tearDown()
    }

    func testSetPrimaryDisplay() {
        detector.next = [
            .builtIn(displayID: 1, name: "Built-in"),
            .builtIn(displayID: 2, name: "External")
        ]
        manager.refreshDisplays()

        manager.setPrimaryDisplay(stableID: ExternalDisplayConfig.cgDisplayID(2))
        XCTAssertEqual(manager.primaryDisplay?.stableID, ExternalDisplayConfig.cgDisplayID(2))
    }

    func testSecondaryDisplayIsNonPrimary() {
        detector.next = [
            .builtIn(displayID: 1, name: "Built-in"),
            .builtIn(displayID: 2, name: "External")
        ]
        manager.refreshDisplays()

        manager.setPrimaryDisplay(stableID: ExternalDisplayConfig.cgDisplayID(1))
        XCTAssertEqual(manager.secondaryDisplay?.stableID, ExternalDisplayConfig.cgDisplayID(2))
    }

    func testPrimaryDisplayPersistsAcrossRestart() {
        detector.next = [
            .builtIn(displayID: 1, name: "Built-in"),
            .builtIn(displayID: 2, name: "External")
        ]
        manager.refreshDisplays()
        manager.setPrimaryDisplay(stableID: ExternalDisplayConfig.cgDisplayID(2))

        let reloaded = DisplayManager(
            provider: EmptyDisplayProvider(),
            detector: MockScreenDetector(next: [
                .builtIn(displayID: 1, name: "Built-in"),
                .builtIn(displayID: 2, name: "External")
            ]),
            defaults: defaults
        )
        defer { reloaded.stop() }
        reloaded.refreshDisplays()
        XCTAssertEqual(reloaded.primaryDisplay?.stableID, ExternalDisplayConfig.cgDisplayID(2))
    }

    func testPrimaryDisplayFallsBackWhenDisconnected() {
        detector.next = [
            .builtIn(displayID: 1, name: "Built-in"),
            .builtIn(displayID: 2, name: "External")
        ]
        manager.refreshDisplays()
        manager.setPrimaryDisplay(stableID: ExternalDisplayConfig.cgDisplayID(2))

        detector.next = [.builtIn(displayID: 1, name: "Built-in")]
        manager.refreshDisplays()

        XCTAssertEqual(manager.primaryDisplay?.stableID, ExternalDisplayConfig.cgDisplayID(1))
    }

    func testPrimaryChangedEventEmitted() {
        detector.next = [
            .builtIn(displayID: 1, name: "Built-in"),
            .builtIn(displayID: 2, name: "External")
        ]
        manager.refreshDisplays()

        var receivedPrimaryChanges: [String] = []
        let cancellable = manager.events
            .sink { event in
                if case .primaryChanged(let config) = event {
                    receivedPrimaryChanges.append(config.stableID)
                }
            }

        manager.setPrimaryDisplay(stableID: ExternalDisplayConfig.cgDisplayID(2))

        cancellable.cancel()
        XCTAssertTrue(receivedPrimaryChanges.contains(ExternalDisplayConfig.cgDisplayID(2)))
    }
}

private final class EmptyDisplayProvider: DisplayProviding {
    func currentScreens() -> [NSScreen] { [] }
}

@MainActor
private final class MockScreenDetector: ScreenDetecting {
    var next: [ExternalDisplayConfig]
    init(next: [ExternalDisplayConfig] = []) { self.next = next }
    func detect(screen: NSScreen) -> ExternalDisplayConfig? {
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
