import XCTest
@testable import TitanPlayer

final class PlaybackErrorTests: XCTestCase {
    func testErrorDescriptions() {
        let cases: [(PlaybackError, String)] = [
            (.invalidURL, "Invalid URL"),
            (.assetLoadFailed(NSError(domain: "test", code: 1)), "Asset load failed"),
            (.noPlayableTracks, "No playable tracks found"),
            (.decodingFailed(NSError(domain: "test", code: 2)), "Decoding failed"),
            (.audioOutputFailed(NSError(domain: "test", code: 3)), "Audio output failed"),
            (.rateNotSupported, "Rate not supported"),
            (.seekFailed, "Seek failed")
        ]
        
        for (error, expected) in cases {
            XCTAssertEqual(error.errorDescription, expected, "Failed for \(error)")
        }
    }
    
    func testErrorCodes() {
        XCTAssertEqual(PlaybackError.invalidURL.code, 1)
        XCTAssertEqual(PlaybackError.noPlayableTracks.code, 3)
        XCTAssertEqual(PlaybackError.rateNotSupported.code, 6)
    }
}
