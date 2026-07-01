import XCTest
import AVFoundation
@testable import TitanPlayer

@MainActor
final class DASHPlayerTests: XCTestCase {
    func testFactoryReturnsDASHPlayerImpl() {
        let url = URL(string: "https://example.com/manifest.mpd")!
        let player = DASHPlayerFactory.player(for: url)
        XCTAssertTrue(player is DASHPlayerImpl)
    }

    func testNotImplementedPlayerStillThrowsDashNotSupported() async {
        let player = NotImplementedDASHPlayer()
        let url = URL(string: "https://example.com/manifest.mpd")!
        do {
            _ = try await player.playableAsset(for: url)
            XCTFail("Expected throw")
        } catch let err as StreamingError {
            if case .dashNotSupported = err {
                // ok
            } else {
                XCTFail("Wrong error: \(err)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testCurrentVariantsIsEmptyForNotImplemented() async {
        let player = NotImplementedDASHPlayer()
        let variants = await player.currentVariants
        XCTAssertTrue(variants.isEmpty)
    }
}
