import XCTest
@testable import TitanPlayer

@MainActor
final class CompatibilityModeTests: XCTestCase {
    private func makeEngine() -> PlaybackEngine {
        PlaybackEngine(videoRenderer: MockFrameRenderer())
    }

    func testCompatibilityModeDefaultsToFalse() {
        let engine = makeEngine()
        XCTAssertFalse(engine.compatibilityMode)
    }

    func testCompatibilityModeResetsOnNewLoad() async {
        let engine = makeEngine()

        // Simulate compatibility mode being active
        engine.compatibilityMode = true

        // Loading a nonexistent file will fail at the asset level (before
        // MediaPipeline.openFile is reached), which resets compatibilityMode
        // at the start of load() then throws.
        let testURL = URL(fileURLWithPath: "/tmp/another_nonexistent.mp4")
        do {
            try await engine.load(url: testURL)
        } catch {
            // Expected — file doesn't exist
        }

        // compatibilityMode should be reset to false at the start of load
        XCTAssertFalse(engine.compatibilityMode)
    }

    func testPlaybackSessionBindsCompatibilityMode() {
        let session = PlaybackSession(videoRenderer: MockFrameRenderer())
        XCTAssertFalse(session.isCompatibilityMode)
    }
}
