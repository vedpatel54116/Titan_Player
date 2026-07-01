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
