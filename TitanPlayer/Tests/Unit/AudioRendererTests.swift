import XCTest
@testable import TitanPlayer

final class AudioRendererTests: XCTestCase {
    func testProtocolConformance() {
        func acceptsRenderer(_ r: any AudioRenderer) {}
        let renderer = AVAudioEngineRenderer()
        acceptsRenderer(renderer)
    }
    
    func testInitialVolume() {
        let renderer = AVAudioEngineRenderer()
        XCTAssertEqual(renderer.volume, 1.0, accuracy: 0.001)
    }
    
    func testVolumeClamping() {
        let renderer = AVAudioEngineRenderer()
        renderer.volume = 2.0
        XCTAssertEqual(renderer.volume, 1.0)
        renderer.volume = -0.5
        XCTAssertEqual(renderer.volume, 0.0)
    }
}
