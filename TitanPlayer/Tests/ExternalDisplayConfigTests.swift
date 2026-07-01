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
