import XCTest
@testable import TitanPlayer

@MainActor
final class DASHIntegrationTests: XCTestCase {
    func testMPDParserParsesRealBBBStream() async throws {
        guard let url = URL(string: "https://dash.akamaized.net/akamai/test/bbb_30fps/bbb_30fps.mpd") else {
            XCTFail("Invalid URL")
            return
        }

        let manifest = try await MPDParser.parse(url: url)

        XCTAssertFalse(manifest.videoAdaptations.isEmpty, "Should have video adaptations")
        XCTAssertFalse(manifest.allVideoQualities.isEmpty, "Should have video qualities")

        let lowest = manifest.lowestVideoQuality
        XCTAssertNotNil(lowest, "Should have a lowest quality")
        XCTAssertGreaterThan(lowest!.bandwidth, 0, "Bandwidth should be positive")
    }

    func testDASHPlayerImplCreatesSession() async throws {
        guard let url = URL(string: "https://dash.akamaized.net/akamai/test/bbb_30fps/bbb_30fps.mpd") else {
            XCTFail("Invalid URL")
            return
        }

        let player = DASHPlayerImpl()
        let session = try await player.streamSession(for: url)

        XCTAssertNotNil(session.mediaInfo, "Session should have media info")
        XCTAssertGreaterThan(session.mediaInfo?.videoTracks.count ?? 0, 0, "Should have video tracks")

        let variants = await player.currentVariants
        XCTAssertFalse(variants.isEmpty, "Should have available variants")

        session.close()
    }
}
