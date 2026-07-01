import XCTest
@testable import TitanPlayer

final class SpatialAudioRendererTests: XCTestCase {
    func testSpatialAudioRendererProtocol() {
        let renderer = MockSpatialAudioRenderer()

        XCTAssertTrue(renderer.spatialAudioEnabled)
        XCTAssertTrue(renderer.headTrackingEnabled)
    }
}

final class MockSpatialAudioRenderer: SpatialAudioRenderer {
    var volume: Float = 1.0
    var currentTime: TimeInterval = 0
    var spatialAudioEnabled: Bool = true
    var headTrackingEnabled: Bool = true
    var audioQuality: AudioQuality = .high

    func start() throws {}
    func stop() {}
    func scheduleBuffer(_ buffer: AVAudioPCMBuffer, at time: TimeInterval?) {}
    func pause() {}
    func resume() {}
    func setListenerPosition(_ position: SIMD3<Float>) {}
    func setListenerOrientation(_ orientation: simd_quatf) {}
    func addAudioObject(_ object: AudioObject) {}
    func removeAudioObject(_ object: AudioObject) {}
    func updateAudioObject(_ object: AudioObject, position: SIMD3<Float>) {}
}
