import XCTest
@testable import TitanPlayer

final class AudioObjectTests: XCTestCase {
    func testAudioObjectCreation() {
        let object = AudioObject(
            id: UUID(),
            position: SIMD3<Float>(1.0, 0.0, 0.0),
            gain: 1.0,
            spread: 0.5,
            source: .object(1)
        )

        XCTAssertEqual(object.position.x, 1.0)
        XCTAssertEqual(object.gain, 1.0)
        XCTAssertEqual(object.spread, 0.5)
    }
}
